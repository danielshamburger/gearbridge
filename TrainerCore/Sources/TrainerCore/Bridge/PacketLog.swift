import Foundation

/// Every packet and bridge event, exported as CSV for tuning and calibration.
public struct PacketLog: Sendable {
    public enum Direction: String, Sendable {
        case fromTrainer = "trainer>app"
        case toTrainer = "app>trainer"
        case fromZwift = "zwift>app"
        case toZwift = "app>zwift"
        case event
    }

    public struct Entry: Equatable, Sendable {
        /// Seconds since the log started.
        public var time: TimeInterval
        public var direction: Direction
        /// Characteristic or event name, e.g. "2AD2" or "shift".
        public var channel: String
        public var bytes: [UInt8]
        public var summary: String

        public var hex: String {
            bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    public let capacity: Int
    public private(set) var entries: [Entry] = []
    /// Entries dropped because the log was full (oldest go first).
    public private(set) var droppedCount = 0

    public init(capacity: Int = 200_000) {
        self.capacity = max(capacity, 1)
    }

    public mutating func append(
        at time: TimeInterval,
        _ direction: Direction,
        _ channel: String,
        bytes: [UInt8] = [],
        summary: String = ""
    ) {
        if entries.count >= capacity {
            let overflow = entries.count - capacity + 1
            entries.removeFirst(overflow)
            droppedCount += overflow
        }
        entries.append(Entry(time: time, direction: direction, channel: channel, bytes: bytes, summary: summary))
    }

    public mutating func clear() {
        entries.removeAll()
        droppedCount = 0
    }

    public func csv() -> String {
        var lines = ["time_s,direction,channel,hex,summary"]
        lines.reserveCapacity(entries.count + 1)
        for e in entries {
            lines.append([
                String(format: "%.3f", e.time),
                e.direction.rawValue,
                csvField(e.channel),
                e.hex,
                csvField(e.summary),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: Human-readable summaries for the log and UI

extension SimulationParameters {
    public var logSummary: String {
        String(format: "grade=%.2f%% crr=%.4f cw=%.2f wind=%.3f", grade * 100, crr, cw, windSpeed)
    }
}

extension IndoorBikeData {
    public var logSummary: String {
        var parts: [String] = []
        if let v = instantaneousSpeed { parts.append(String(format: "speed=%.2fkmh", v)) }
        if let v = instantaneousCadence { parts.append(String(format: "cadence=%.1f", v)) }
        if let v = instantaneousPower { parts.append("power=\(v)") }
        if let v = resistanceLevel { parts.append("resistance=\(v)") }
        if let v = totalDistance { parts.append("distance=\(v)") }
        if let v = heartRate { parts.append("hr=\(v)") }
        return parts.joined(separator: " ")
    }
}

extension ControlPointRequest {
    public var logSummary: String {
        switch self {
        case .requestControl: "requestControl"
        case .reset: "reset"
        case .setTargetSpeed(let v): "targetSpeed=\(v)kmh"
        case .setTargetInclination(let v): "targetInclination=\(v)%"
        case .setTargetResistanceLevel(let v): "targetResistance=\(v)"
        case .setTargetPower(let w): "targetPower=\(w)W"
        case .setTargetHeartRate(let v): "targetHR=\(v)"
        case .startOrResume: "startOrResume"
        case .stopOrPause(let c): "stopOrPause=\(c)"
        case .setIndoorBikeSimulation(let p): "sim \(p.logSummary)"
        case .setWheelCircumference(let mm): "wheelCircumference=\(mm)mm"
        case .spinDownControl(let c): "spinDown=\(c)"
        case .setTargetedCadence(let v): "targetCadence=\(v)"
        case .unsupported(let op, _): String(format: "unsupported op=0x%02X", op)
        }
    }
}

extension ControlPointResponse {
    public var logSummary: String {
        String(format: "response op=0x%02X ", requestOpcode) + "\(result)"
    }
}

extension FitnessMachineStatus {
    public var logSummary: String {
        switch self {
        case .indoorBikeSimulationParametersChanged(let p): "status sim \(p.logSummary)"
        default: "status \(self)"
        }
    }
}
