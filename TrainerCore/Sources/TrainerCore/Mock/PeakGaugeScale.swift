import Foundation

/// Top of a live gauge (power, speed): starts at `floor` and grows to the
/// highest value seen this ride, rounded up to `step`. A new peak only counts
/// once two readings in a row reach it, so one corrupt packet can't squash
/// the gauge for the rest of the ride. Reset at the start of each ride.
public struct PeakGaugeScale: Equatable, Sendable {
    public var floor: Double
    public var step: Double
    /// Highest value held for two consecutive readings.
    public private(set) var peak: Double = 0

    private var previous: Double?

    public init(floor: Double, step: Double) {
        self.floor = floor
        self.step = step
    }

    public var upperBound: Double {
        max(floor, (peak / step).rounded(.up) * step)
    }

    /// Feed every reading. Returns true when the peak rose.
    @discardableResult
    public mutating func observe(_ value: Double) -> Bool {
        defer { previous = value }
        guard let previous else { return false }
        let held = min(value, previous)
        guard held > peak else { return false }
        peak = held
        return true
    }

    public mutating func reset() {
        peak = 0
        previous = nil
    }

    /// Power, W: starts at 300, steps of 50.
    public static var power: Self { Self(floor: 300, step: 50) }
    /// Speed, km/h: starts at 40, steps of 5.
    public static var speed: Self { Self(floor: 40, step: 5) }
}
