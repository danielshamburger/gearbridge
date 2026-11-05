import Foundation

/// Time-based exponential moving average for noisy trainer speed.
/// Restarts from the raw sample after a gap (e.g. a reconnect).
public struct ExponentialSmoother: Sendable {
    /// Seconds for the output to cover ~63 % of a step change.
    public var timeConstant: TimeInterval
    public var resetAfterGap: TimeInterval

    public private(set) var value: Double?
    private var lastTime: TimeInterval?

    public init(timeConstant: TimeInterval = 1.0, resetAfterGap: TimeInterval = 3.0) {
        self.timeConstant = timeConstant
        self.resetAfterGap = resetAfterGap
    }

    @discardableResult
    public mutating func update(_ sample: Double, at time: TimeInterval) -> Double {
        guard let current = value, let last = lastTime, time - last <= resetAfterGap else {
            value = sample
            lastTime = time
            return sample
        }
        let dt = max(time - last, 0)
        let alpha = timeConstant > 0 ? 1 - exp(-dt / timeConstant) : 1
        let next = current + alpha * (sample - current)
        value = next
        lastTime = max(time, last)
        return next
    }

    public mutating func reset() {
        value = nil
        lastTime = nil
    }
}

/// Decides when a trainer command is worth sending: at most once per
/// `minimumInterval`, and only when it differs from the last one sent.
/// A forced send (after a shift) waits for the interval but is never dropped.
public struct CommandThrottle: Sendable {
    public var minimumInterval: TimeInterval
    /// Smallest grade change worth sending, as a fraction (0.001 = 0.1 %).
    public var gradeThreshold: Double

    public private(set) var lastSent: SimulationParameters?
    private var lastSendTime: TimeInterval?
    private var pending = false

    public init(minimumInterval: TimeInterval = 0.25, gradeThreshold: Double = 0.001) {
        self.minimumInterval = minimumInterval
        self.gradeThreshold = gradeThreshold
    }

    /// Returns true if `parameters` should be sent now, and records it as sent.
    public mutating func shouldSend(
        _ parameters: SimulationParameters,
        at time: TimeInterval,
        force: Bool = false
    ) -> Bool {
        if force { pending = true }
        let q = parameters.quantized
        guard let last = lastSent, let lastTime = lastSendTime else {
            record(q, time)
            return true
        }
        guard time - lastTime >= minimumInterval else { return false }

        let changed = abs(q.grade - last.grade) > gradeThreshold
            || q.crr != last.crr
            || q.cw != last.cw
            || q.windSpeed != last.windSpeed
        guard changed || pending else { return false }
        record(q, time)
        return true
    }

    public mutating func reset() {
        lastSent = nil
        lastSendTime = nil
        pending = false
    }

    private mutating func record(_ parameters: SimulationParameters, _ time: TimeInterval) {
        lastSent = parameters
        lastSendTime = time
        pending = false
    }
}
