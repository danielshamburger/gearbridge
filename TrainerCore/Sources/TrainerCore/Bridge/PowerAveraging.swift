import Foundation

/// How the power readout is smoothed. Display only: Zwift always gets the
/// trainer's instant power.
public enum PowerAveraging: String, CaseIterable, Identifiable, Sendable {
    case instant
    case threeSeconds
    case tenSeconds

    public var id: Self { self }

    /// Seconds averaged over; 0 means the latest reading.
    public var window: TimeInterval {
        switch self {
        case .instant: 0
        case .threeSeconds: 3
        case .tenSeconds: 10
        }
    }

    /// Name for the settings picker.
    public var name: String {
        switch self {
        case .instant: "Instant"
        case .threeSeconds: "3 s average"
        case .tenSeconds: "10 s average"
        }
    }

    /// Short form for the settings list.
    public var shortName: String {
        switch self {
        case .instant: "Instant"
        case .threeSeconds: "3 s"
        case .tenSeconds: "10 s"
        }
    }
}

/// Recent readings, averaged over a window picked at read time, so changing
/// the window takes effect at once.
public struct RollingAverage: Equatable, Sendable {
    private var samples: [(time: TimeInterval, value: Double)] = []
    /// The longest window anyone asks for.
    private let keep: TimeInterval = 10

    public init() {}

    public mutating func observe(_ value: Double, at time: TimeInterval) {
        samples.append((time, value))
        samples.removeAll { time - $0.time > keep }
    }

    public mutating func reset() { samples = [] }

    /// The mean of the readings in the last `window` seconds, or the latest
    /// reading when `window` is 0. Nil with no readings.
    public func average(over window: TimeInterval, at time: TimeInterval) -> Double? {
        guard let last = samples.last else { return nil }
        guard window > 0 else { return last.value }
        let recent = samples.filter { time - $0.time <= window }
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0) { $0 + $1.value } / Double(recent.count)
    }

    public static func == (lhs: RollingAverage, rhs: RollingAverage) -> Bool {
        lhs.samples.count == rhs.samples.count
            && zip(lhs.samples, rhs.samples).allSatisfy { $0.time == $1.time && $0.value == $1.value }
    }
}
