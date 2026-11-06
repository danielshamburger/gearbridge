import Foundation

/// Every packet and bridge event, exported as CSV for tuning and calibration.
///
/// A ring buffer: when full, the oldest entry is overwritten, so a long ride
/// costs the same per packet as a short one. Summaries of trainer data are
/// kept as the decoded values and only turned into text on export.
public struct PacketLog: Sendable {
    public enum Direction: String, Sendable {
        case fromTrainer = "trainer>app"
        case toTrainer = "app>trainer"
        case fromZwift = "zwift>app"
        case toZwift = "app>zwift"
        case event
    }

    /// An entry's description, formatted when it's read.
    public enum Detail: Equatable, Sendable {
        case text(String)
        case bikeData(IndoorBikeData)

        public var summary: String {
            switch self {
            case .text(let text): text
            case .bikeData(let data): data.logSummary
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        /// Seconds since the log started.
        public var time: TimeInterval
        public var direction: Direction
        /// Characteristic or event name, e.g. "2AD2" or "shift".
        public var channel: String
        public var bytes: [UInt8]
        public var detail: Detail

        public var summary: String { detail.summary }

        /// "11 00 2A": a lookup table, not `String(format:)` per byte (export speed).
        public var hex: String {
            var out = [UInt8]()
            out.reserveCapacity(bytes.count * 3)
            for (i, byte) in bytes.enumerated() {
                if i > 0 { out.append(0x20) }
                out.append(Self.hexDigits[Int(byte >> 4)])
                out.append(Self.hexDigits[Int(byte & 0x0F)])
            }
            return String(decoding: out, as: UTF8.self)
        }

        private static let hexDigits = Array("0123456789ABCDEF".utf8)
    }

    public let capacity: Int
    /// Entries dropped because the log was full (oldest go first).
    public private(set) var droppedCount = 0

    private var storage: [Entry] = []
    /// Where the oldest entry is, once the buffer has wrapped.
    private var head = 0

    public init(capacity: Int = 200_000) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int { storage.count }

    /// Oldest first.
    public var entries: [Entry] {
        Array(storage[head...] + storage[..<head])
    }

    public mutating func append(
        at time: TimeInterval,
        _ direction: Direction,
        _ channel: String,
        bytes: [UInt8] = [],
        summary: String = ""
    ) {
        append(Entry(time: time, direction: direction, channel: channel, bytes: bytes, detail: .text(summary)))
    }

    /// Trainer data: the summary is formatted on export, not per packet.
    public mutating func append(
        at time: TimeInterval,
        _ direction: Direction,
        _ channel: String,
        bytes: [UInt8],
        data: IndoorBikeData
    ) {
        append(Entry(time: time, direction: direction, channel: channel, bytes: bytes, detail: .bikeData(data)))
    }

    private mutating func append(_ entry: Entry) {
        if storage.count < capacity {
            storage.append(entry)
        } else {
            storage[head] = entry
            head = (head + 1) % capacity
            droppedCount += 1
        }
    }

    public mutating func clear() {
        storage.removeAll()
        head = 0
        droppedCount = 0
    }

    public func csv() -> String {
        var out = "time_s,direction,channel,hex,summary\n"
        out.reserveCapacity(storage.count * 64)
        for e in entries {
            out += String(format: "%.3f", e.time)
            out += ","
            out += e.direction.rawValue
            out += ","
            out += csvField(e.channel)
            out += ","
            out += e.hex
            out += ","
            out += csvField(e.summary)
            out += "\n"
        }
        return out
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
