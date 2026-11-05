/// Settings shared by every strategy.
public struct EngineContext: Equatable, Sendable {
    public var realRatio: Double
    /// Rider plus bike, kg.
    public var systemMass: Double
    /// Multiplies Zwift's grade before use. Keep Zwift's Trainer Difficulty at
    /// 100 % and soften here instead.
    public var gradeScale: Double

    public init(realRatio: Double, systemMass: Double, gradeScale: Double = 1) {
        self.realRatio = realRatio
        self.systemMass = systemMass
        self.gradeScale = gradeScale
    }

    public init(rider: RiderSetup, gradeScale: Double = 1) {
        self.init(realRatio: rider.realRatio, systemMass: rider.systemMass, gradeScale: gradeScale)
    }
}

/// What the engine knows at one trainer data packet.
public struct EngineInput: Equatable, Sendable {
    /// Latest simulation command from Zwift.
    public var simulation: SimulationParameters
    /// Smoothed trainer speed, m/s.
    public var realSpeed: Double
    /// Current virtual ratio, possibly mid-ramp.
    public var virtualRatio: Double
    /// Selected gear (no ramp), used by the grade-offset strategy.
    public var gearIndex: Int

    public init(simulation: SimulationParameters, realSpeed: Double, virtualRatio: Double, gearIndex: Int) {
        self.simulation = simulation
        self.realSpeed = realSpeed
        self.virtualRatio = virtualRatio
        self.gearIndex = gearIndex
    }
}

/// The simulation command to send the trainer, plus values for the UI and packet log.
public struct TrainerCommand: Equatable, Sendable {
    public enum Limit: Equatable, Sendable {
        case none
        /// Clamped at the trainer's maximum grade: the "maxed" indicator.
        case maximum
        /// Clamped at the trainer's minimum resistance.
        case minimum
    }

    public var parameters: SimulationParameters
    public var limit: Limit
    /// Virtual bike speed, m/s.
    public var virtualSpeed: Double
    /// Force the virtual bike needs, N (strategy C only).
    public var virtualForce: Double?
    /// Force wanted from the trainer, N (strategy C only).
    public var realForce: Double?

    public init(
        parameters: SimulationParameters,
        limit: Limit = .none,
        virtualSpeed: Double,
        virtualForce: Double? = nil,
        realForce: Double? = nil
    ) {
        self.parameters = parameters
        self.limit = limit
        self.virtualSpeed = virtualSpeed
        self.virtualForce = virtualForce
        self.realForce = realForce
    }

    public var isMaxed: Bool { limit == .maximum }
}

/// Turns Zwift's simulation command and the current gear into a trainer command.
public protocol ShiftingStrategy: Sendable {
    func command(for input: EngineInput, context: EngineContext) -> TrainerCommand
}

func virtualSpeed(_ input: EngineInput, _ context: EngineContext) -> Double {
    guard context.realRatio > 0 else { return 0 }
    return max(input.realSpeed, 0) * input.virtualRatio / context.realRatio
}

func clamp(_ grade: Double, min lower: Double, max upper: Double) -> (Double, TrainerCommand.Limit) {
    if grade > upper { return (upper, .maximum) }
    if grade < lower { return (lower, .minimum) }
    return (grade, .none)
}
