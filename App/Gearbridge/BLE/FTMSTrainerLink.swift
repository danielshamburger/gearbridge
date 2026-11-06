import CoreBluetooth
import Foundation
import TrainerCore

/// BLE central connection to a real FTMS trainer (the Flux S).
///
/// Connects to the trainer chosen in Settings, or with none chosen, the first
/// one advertising FTMS (which it then remembers). Reconnects automatically. Control Point writes go through
/// `ControlPointQueue` so only one is in flight at a time.
@MainActor
final class FTMSTrainerLink: NSObject, TrainerLink {
    var onEvent: (@MainActor (TrainerLinkEvent) -> Void)?

    @MainActor
    private enum UUIDs {
        static let service = CBUUID(string: FTMSUUID.service)
        static let indoorBikeData = CBUUID(string: FTMSUUID.indoorBikeData)
        static let controlPoint = CBUUID(string: FTMSUUID.controlPoint)
        static let status = CBUUID(string: FTMSUUID.status)
        static let feature = CBUUID(string: FTMSUUID.feature)
        static let powerRange = CBUUID(string: FTMSUUID.supportedPowerRange)
        static let all = [indoorBikeData, controlPoint, status, feature, powerRange]
    }

    /// The remembered trainer's Bluetooth identifier. Set by connecting, or by
    /// "Choose trainer" in Settings.
    static let savedTrainerKey = "trainerPeripheralID"

    static var savedID: UUID? {
        UserDefaults.standard.string(forKey: savedTrainerKey).flatMap(UUID.init)
    }

    private var savedTrainerID: UUID? { Self.savedID }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var controlPoint: CBCharacteristic?
    private var queue = ControlPointQueue()
    private var timeoutTask: Task<Void, Never>?
    private var running = false
    private let clockStart = ContinuousClock.now

    private var now: TimeInterval {
        let d = ContinuousClock.now - clockStart
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private var peripheralName: String { peripheral?.name ?? "trainer" }

    func start() {
        running = true
        if let central {
            beginConnecting(central)
        } else {
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func stop() {
        running = false
        timeoutTask?.cancel()
        timeoutTask = nil
        if let central {
            central.stopScan()
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
        peripheral = nil
        controlPoint = nil
        queue.reset()
        onEvent?(.state(.idle))
    }

    func send(_ request: ControlPointRequest) {
        guard controlPoint != nil else { return } // the bridge replays state on reconnect
        if let next = queue.enqueue(request, at: now) { write(next) }
    }

    private func write(_ request: ControlPointRequest) {
        guard let peripheral, let controlPoint else { return }
        let raw = request.encoded()
        peripheral.writeValue(Data(raw), for: controlPoint, type: .withResponse)
        onEvent?(.sent(request, raw: raw))
        armTimeout()
    }

    private func beginConnecting(_ central: CBCentralManager) {
        guard running, central.state == .poweredOn, peripheral == nil else { return }
        if let id = savedTrainerID,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known, using: central)
            return
        }
        central.scanForPeripherals(withServices: [UUIDs.service])
        onEvent?(.state(.scanning))
    }

    private func connect(_ target: CBPeripheral, using central: CBCentralManager) {
        peripheral = target
        target.delegate = self
        onEvent?(.state(.connecting(target.name ?? "trainer")))
        // No timeout: CoreBluetooth keeps trying until the trainer is in range.
        central.connect(target)
    }

    /// One timer per request in flight, rather than a 10 Hz loop: if the
    /// trainer hasn't answered by the queue's timeout, give up on it and send
    /// the next. Cancelled when the answer arrives.
    private func armTimeout() {
        timeoutTask?.cancel()
        let delay = queue.timeout + 0.01 // a hair over, so checkTimeout agrees it's late
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.timeoutTask = nil
            if let next = self.queue.checkTimeout(at: self.now) { self.write(next) }
        }
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}

extension FTMSTrainerLink: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: beginConnecting(central)
        case .poweredOff: onEvent?(.state(.bluetoothUnavailable("Bluetooth is off")))
        case .unauthorized: onEvent?(.state(.bluetoothUnavailable("Bluetooth permission denied")))
        case .unsupported: onEvent?(.state(.bluetoothUnavailable("Bluetooth LE unsupported")))
        default: break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard running, self.peripheral == nil else { return }
        // With a trainer chosen, wait for that one rather than take another.
        if let saved = savedTrainerID, peripheral.identifier != saved { return }
        central.stopScan()
        connect(peripheral, using: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedTrainerKey)
        peripheral.discoverServices([UUIDs.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        onEvent?(.state(.disconnected(peripheral.name ?? "trainer")))
        beginConnecting(central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        controlPoint = nil
        queue.reset()
        timeoutTask?.cancel()
        guard running else { return }
        onEvent?(.state(.disconnected(peripheral.name ?? "trainer")))
        central.connect(peripheral)
    }
}

extension FTMSTrainerLink: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == UUIDs.service {
            peripheral.discoverCharacteristics(UUIDs.all, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case UUIDs.indoorBikeData, UUIDs.status:
                peripheral.setNotifyValue(true, for: c)
            case UUIDs.controlPoint:
                controlPoint = c
                peripheral.setNotifyValue(true, for: c)
            case UUIDs.feature, UUIDs.powerRange:
                peripheral.readValue(for: c)
            default:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == UUIDs.controlPoint, characteristic.isNotifying else { return }
        onEvent?(.state(.connected(peripheralName)))
        onEvent?(.ready)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let raw = [UInt8](value)
        let channel = characteristic.uuid.uuidString
        do {
            switch characteristic.uuid {
            case UUIDs.indoorBikeData:
                onEvent?(.data(try IndoorBikeData(bytes: raw), raw: raw))
            case UUIDs.controlPoint:
                let response = try ControlPointResponse(bytes: raw)
                onEvent?(.response(response, raw: raw))
                let wasInFlight = queue.inFlight?.request.opcode == response.requestOpcode
                if let next = queue.didReceive(response, at: now) {
                    write(next) // re-arms the timeout
                } else if wasInFlight {
                    cancelTimeout()
                }
            case UUIDs.status:
                onEvent?(.status(try FitnessMachineStatus(bytes: raw), raw: raw))
            case UUIDs.feature:
                onEvent?(.feature(try FitnessMachineFeature(bytes: raw), raw: raw))
            case UUIDs.powerRange:
                onEvent?(.powerRange(try SupportedPowerRange(bytes: raw), raw: raw))
            default:
                break
            }
        } catch {
            onEvent?(.decodeError(channel: channel, raw: raw, message: "\(error)"))
        }
    }
}
