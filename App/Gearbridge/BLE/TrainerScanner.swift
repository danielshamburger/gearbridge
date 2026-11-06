import CoreBluetooth
import Foundation
import Observation
import TrainerCore

/// Lists the smart trainers (anything advertising FTMS) in range, for the
/// "Choose trainer" screen. Scans only while that screen is open.
@MainActor
@Observable
final class TrainerScanner: NSObject {
    struct Found: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        var lastSeen: Date
    }

    /// Strongest signal first.
    private(set) var trainers: [Found] = []
    private(set) var problem: String?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var scanning = false

    func start() {
        scanning = true
        if let central {
            scan(central)
        } else {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        // Drop trainers that have gone quiet (switched off, or connected to
        // something else, which stops them advertising).
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-8)
                self.trainers.removeAll { $0.lastSeen < cutoff }
            }
        }
    }

    func stop() {
        scanning = false
        pruneTask?.cancel()
        pruneTask = nil
        central?.stopScan()
    }

    private func scan(_ central: CBCentralManager) {
        guard scanning, central.state == .poweredOn else { return }
        // Duplicates on, so signal strength stays current and the list knows
        // which trainers are still there.
        central.scanForPeripherals(withServices: [CBUUID(string: FTMSUUID.service)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
}

extension TrainerScanner: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: problem = nil; scan(central)
        case .poweredOff: problem = "Bluetooth is off."
        case .unauthorized: problem = "Gearbridge doesn't have Bluetooth permission. Allow it in the Settings app."
        case .unsupported: problem = "This device doesn't support Bluetooth LE."
        default: break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        guard scanning, rssi < 0 else { return } // 127 means "unavailable"
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "Unnamed trainer"
        if let index = trainers.firstIndex(where: { $0.id == peripheral.identifier }) {
            trainers[index].name = name
            // Smoothed, so the order doesn't jitter between two similar signals
            trainers[index].rssi = (trainers[index].rssi * 3 + rssi) / 4
            trainers[index].lastSeen = Date()
        } else {
            trainers.append(Found(id: peripheral.identifier, name: name, rssi: rssi, lastSeen: Date()))
        }
        trainers.sort { $0.rssi > $1.rssi }
    }
}
