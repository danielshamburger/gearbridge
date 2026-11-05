import Foundation

/// Gearbox, strategy and speed smoothing combined: turns Zwift's simulation
/// command, trainer speed and the selected gear into the trainer's command.
///
/// Time is a caller-supplied monotonic clock in seconds.
public struct ShiftingEngine: Sendable {
    public enum Strategy: Sendable {
        /// A: a fixed grade per gear. Needs no calibration.
        case gradeOffset(GradeOffsetStrategy)
        /// C: force scaling. Needs a trainer calibration.
        case forceScaling(ForceScalingStrategy)

        var implementation: any ShiftingStrategy {
            switch self {
            case .gradeOffset(let s): s
            case .forceScaling(let s): s
            }
        }
    }

    public private(set) var gearbox: Gearbox
    public var strategy: Strategy
    public var context: EngineContext

    private var smoother: ExponentialSmoother
    /// Smoothed trainer speed, m/s; 0 until the first data packet.
    public var realSpeed: Double { smoother.value ?? 0 }

    public init(
        gearbox: Gearbox,
        strategy: Strategy,
        context: EngineContext,
        smoother: ExponentialSmoother = ExponentialSmoother()
    ) {
        self.gearbox = gearbox
        self.strategy = strategy
        self.context = context
        self.smoother = smoother
    }

    /// Strategy A with its neutral gear set to the gear closest to the real ratio,
    /// so that gear feels like riding without the bridge.
    public static func gradeOffset(
        profile: GearProfile,
        rider: RiderSetup,
        gradePerGear: Double = 0.01,
        gradeScale: Double = 1
    ) -> ShiftingEngine {
        let neutral = profile.closestGearIndex(toRatio: rider.realRatio)
        return ShiftingEngine(
            gearbox: Gearbox(profile: profile),
            strategy: .gradeOffset(GradeOffsetStrategy(neutralGearIndex: neutral, gradePerGear: gradePerGear)),
            context: EngineContext(rider: rider, gradeScale: gradeScale)
        )
    }

    /// Strategy C with a fitted calibration.
    public static func forceScaling(
        profile: GearProfile,
        rider: RiderSetup,
        calibration: TrainerCalibration,
        gradeScale: Double = 1
    ) -> ShiftingEngine {
        ShiftingEngine(
            gearbox: Gearbox(profile: profile),
            strategy: .forceScaling(ForceScalingStrategy(calibration: calibration)),
            context: EngineContext(rider: rider, gradeScale: gradeScale)
        )
    }

    public mutating func updateSpeed(_ metersPerSecond: Double, at time: TimeInterval) {
        smoother.update(max(metersPerSecond, 0), at: time)
    }

    @discardableResult
    public mutating func shift(_ direction: Gearbox.Direction, at time: TimeInterval) -> Gearbox.ShiftResult {
        gearbox.shift(direction, at: time)
    }

    public func command(for simulation: SimulationParameters, at time: TimeInterval) -> TrainerCommand {
        let input = EngineInput(
            simulation: simulation,
            realSpeed: realSpeed,
            virtualRatio: gearbox.ratio(at: time),
            gearIndex: gearbox.gearIndex
        )
        return strategy.implementation.command(for: input, context: context)
    }
}
