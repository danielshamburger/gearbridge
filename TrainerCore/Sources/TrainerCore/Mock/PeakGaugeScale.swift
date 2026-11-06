import Foundation

/// Top of a live gauge (power, speed): starts at `floor` and grows to the
/// highest value seen this ride, rounded up to `step`. Reset at the start of
/// each ride.
///
/// Every reading counts at once unless it's physically implausible, so a
/// corrupt packet can't squash the gauge for the rest of the ride:
/// - above `maximum` (beyond any human, or the trainer);
/// - risen faster than `maxRisePerSecond` (plus `tolerance` for sensor noise)
///   since the last plausible reading.
public struct PeakGaugeScale: Equatable, Sendable {
    public var floor: Double
    public var step: Double
    public var maximum: Double
    /// Fastest believable rise, units per second; nil for no limit.
    public var maxRisePerSecond: Double?
    public var tolerance: Double

    /// Highest plausible value this ride.
    public private(set) var peak: Double = 0
    private var last: (value: Double, time: TimeInterval)?

    public static func == (a: Self, b: Self) -> Bool {
        a.floor == b.floor && a.step == b.step && a.maximum == b.maximum
            && a.maxRisePerSecond == b.maxRisePerSecond && a.tolerance == b.tolerance && a.peak == b.peak
    }

    public init(floor: Double, step: Double, maximum: Double, maxRisePerSecond: Double? = nil, tolerance: Double = 0) {
        self.floor = floor
        self.step = step
        self.maximum = maximum
        self.maxRisePerSecond = maxRisePerSecond
        self.tolerance = tolerance
    }

    public var upperBound: Double {
        max(floor, (peak / step).rounded(.up) * step)
    }

    /// Whether `value` at `time` is believable, given the last plausible reading.
    public func isPlausible(_ value: Double, at time: TimeInterval) -> Bool {
        guard value.isFinite, value >= 0, value <= maximum else { return false }
        guard let rate = maxRisePerSecond, let last else { return true }
        let dt = max(time - last.time, 0)
        return value - last.value <= rate * dt + tolerance
    }

    /// Feed every reading. Implausible ones are ignored. Returns true when the peak rose.
    @discardableResult
    public mutating func observe(_ value: Double, at time: TimeInterval) -> Bool {
        guard isPlausible(value, at: time) else { return false }
        last = (value, time)
        guard value > peak else { return false }
        peak = value
        return true
    }

    public mutating func reset() {
        peak = 0
        last = nil
    }

    /// Power, W: starts at 300, steps of 50. Over 3000 W is rejected (the
    /// highest recorded human sprint is about 2,500 W). No rise limit: a
    /// sprint really can jump hundreds of watts between readings.
    public static var power: Self { Self(floor: 300, step: 50, maximum: 3000) }

    /// Speed, km/h: starts at 40, steps of 5. Over 100 km/h is rejected (more
    /// than 53×10 at 130 rpm), and so is a rise faster than 15 km/h per second
    /// (about 4 m/s², twice an all-out sprint start) plus 3 km/h of noise.
    public static var speed: Self { Self(floor: 40, step: 5, maximum: 100, maxRisePerSecond: 15, tolerance: 3) }
}
