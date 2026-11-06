import CoreBluetooth
import Foundation
import TrainerCore

/// The FTMS trainer Zwift sees: a BLE peripheral advertising the Fitness Machine
/// Service under a fixed name so Zwift recognizes it between sessions.
///
/// iOS only advertises reliably while the app is in the foreground.
@MainActor
final class VirtualTrainerPeripheral: NSObject {
    enum State: Equatable {
        case stopped
        case starting
        case unavailable(String)
        case advertising
        case failed(String)
    }

    let name: String
    var onControlPointWrite: (@MainActor ([UInt8]) -> Void)?
    var onChange: (@MainActor () -> Void)?
    /// Bluetooth-level activity (service added, advertising, reads, subscriptions), for the packet log.
    var onLog: (@MainActor (String) -> Void)?

    var feature = BridgeCore.virtualFeature(copying: nil)
    var powerRange = BridgeCore.defaultPowerRange
    var resistanceRange = BridgeCore.defaultResistanceRange

    private(set) var state: State = .stopped { didSet { onChange?() } }
    /// Centrals subscribed to Indoor Bike Data, i.e. Zwift actually listening.
    private(set) var subscriberCount = 0 { didSet { onChange?() } }

    private var manager: CBPeripheralManager?
    private var serviceAdded = false
    private var pending: [(Data, CBMutableCharacteristic)] = []
    private let maxPending = 50

    private let indoorBikeData = CBMutableCharacteristic(
        type: CBUUID(string: FTMSUUID.indoorBikeData), properties: [.notify], value: nil, permissions: [.readable])
    private let controlPoint = CBMutableCharacteristic(
        type: CBUUID(string: FTMSUUID.controlPoint), properties: [.write, .indicate], value: nil, permissions: [.writeable])
    private let status = CBMutableCharacteristic(
        type: CBUUID(string: FTMSUUID.status), properties: [.notify], value: nil, permissions: [.readable])
    private let featureCharacteristic = CBMutableCharacteristic(
        type: CBUUID(string: FTMSUUID.feature), properties: [.read], value: nil, permissions: [.readable])
    private let powerRangeCharacteristic = CBMutableCharacteristic(
        type: CBUUID(string: FTMSUUID.supportedPowerRange), properties: [.read], value: nil, permissions: [.readable])
    private let resistanceRangeCharacteristic = CBMutableCharacteristic(
        type: CBUUID(string: FTMSUUID.supportedResistanceLevelRange), properties: [.read], value: nil, permissions: [.readable])
    private let trainingStatus = CBMutableCharacteristic(
        type: CBUUID(string: FTMSUUID.trainingStatus), properties: [.read, .notify], value: nil, permissions: [.readable])

    init(name: String) {
        self.name = name
        super.init()
    }

    /// Publishes the service (first time only) and starts advertising.
    ///
    /// The service stays published until the app quits, even between rides:
    /// removing and re-adding it changes its GATT handles, and Zwift (and the
    /// Mac's Bluetooth cache) keep using the old ones, so Zwift ends up linked
    /// but never subscribes or writes.
    func start() {
        state = .starting
        if let manager {
            if manager.state == .poweredOn { addService(manager) } // re-advertises if already added
        } else {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        }
    }

    /// Stops advertising. The service and any Zwift subscriptions stay, so
    /// the next ride carries on without re-pairing.
    func stop() {
        manager?.stopAdvertising()
        pending = []
        state = .stopped
    }

    func notify(_ data: IndoorBikeData) {
        send(data.encoded(), on: indoorBikeData)
    }

    func notify(_ machineStatus: FitnessMachineStatus) {
        send(machineStatus.encoded(), on: status)
    }

    func indicate(_ response: ControlPointResponse) {
        send(response.encoded(), on: controlPoint)
    }

    private func send(_ bytes: [UInt8], on characteristic: CBMutableCharacteristic) {
        guard let manager, !(characteristic.subscribedCentrals ?? []).isEmpty else { return }
        let data = Data(bytes)
        if pending.isEmpty, manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil) {
            return
        }
        // Transmit queue full: retry in peripheralManagerIsReady(toUpdateSubscribers:).
        // Only the newest bike data matters; a backlog would reach Zwift late.
        // Control Point responses and status stay queued in order.
        if characteristic === indoorBikeData {
            pending.removeAll { $0.1 === indoorBikeData }
        }
        if pending.count >= maxPending { pending.removeFirst() }
        pending.append((data, characteristic))
    }

    private func flushPending() {
        guard let manager else { return }
        while let (data, characteristic) = pending.first {
            guard manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil) else { return }
            pending.removeFirst()
        }
    }

    private func addService(_ manager: CBPeripheralManager) {
        guard !serviceAdded else {
            startAdvertising(manager)
            return
        }
        let service = CBMutableService(type: CBUUID(string: FTMSUUID.service), primary: true)
        service.characteristics = [
            featureCharacteristic, indoorBikeData, trainingStatus, resistanceRangeCharacteristic,
            powerRangeCharacteristic, controlPoint, status,
        ]
        manager.add(service)
    }

    private func startAdvertising(_ manager: CBPeripheralManager) {
        guard !manager.isAdvertising else {
            state = .advertising
            return
        }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: name,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: FTMSUUID.service)],
        ])
    }

    private func readValue(for uuid: CBUUID) -> [UInt8]? {
        switch uuid {
        case featureCharacteristic.uuid: feature.encoded()
        case powerRangeCharacteristic.uuid: powerRange.encoded()
        case resistanceRangeCharacteristic.uuid: resistanceRange.encoded()
        case trainingStatus.uuid: [0x00, 0x01] // no string, status "Idle"
        default: nil
        }
    }

    private func updateSubscriberCount() {
        subscriberCount = indoorBikeData.subscribedCentrals?.count ?? 0
    }
}

extension VirtualTrainerPeripheral: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            addService(peripheral)
        case .poweredOff:
            state = .unavailable("Bluetooth is off")
        case .unauthorized:
            state = .unavailable("Bluetooth permission denied")
        case .unsupported:
            state = .unavailable("Bluetooth LE unsupported")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            onLog?("add service failed: \(error.localizedDescription)")
            state = .failed("Adding service failed: \(error.localizedDescription)")
            return
        }
        onLog?("service added")
        serviceAdded = true
        startAdvertising(peripheral)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onLog?("advertising failed: \(error.localizedDescription)")
            state = .failed("Advertising failed: \(error.localizedDescription)")
        } else {
            onLog?("advertising as \(name)")
            state = .advertising
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        onLog?("subscribe \(characteristic.uuid.uuidString) by \(central.identifier.uuidString.prefix(8)) (max update \(central.maximumUpdateValueLength) B)")
        updateSubscriberCount()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        onLog?("unsubscribe \(characteristic.uuid.uuidString) by \(central.identifier.uuidString.prefix(8))")
        updateSubscriberCount()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let value = readValue(for: request.characteristic.uuid)
        onLog?("read \(request.characteristic.uuid.uuidString) by \(request.central.identifier.uuidString.prefix(8))"
               + (value.map { " → " + $0.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? " → not permitted"))
        guard let value else {
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = Data(value[request.offset...])
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.allSatisfy({ $0.characteristic.uuid == controlPoint.uuid }) else {
            onLog?("write refused on \(first.characteristic.uuid.uuidString)")
            peripheral.respond(to: first, withResult: .writeNotPermitted)
            return
        }
        // Acknowledge the ATT write first; the FTMS response follows as an indication.
        peripheral.respond(to: first, withResult: .success)
        for request in requests {
            onControlPointWrite?([UInt8](request.value ?? Data()))
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushPending()
    }
}
