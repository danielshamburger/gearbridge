import Foundation

/// A fake Flux S for developing without the bike: answers Control Point
/// requests like an FTMS trainer and produces Indoor Bike Data from a simple
/// model of the trainer and a rider holding a steady cadence.
///
/// Its hidden characteristics are deliberately not the nominal calibration,
/// so the calibration routine has something real to discover.
public struct MockTrainer: Sendable {
    public struct Characteristics: Equatable, Sendable {
        /// Rider mass the trainer's internal sim mode assumes, kg.
        public var simulationMass: Double = 75
        /// Brake and flywheel drag on top of the sim force, N vs speed.
        public var parasiticForce = LinearModel(intercept: 3, slope: 0.4)
        /// Grade above which force stops rising.
        public var maxGrade: Double = 0.10
        /// Minimum force at any command, N vs speed.
        public var floorForce = LinearModel(intercept: 2, slope: 0.3)
        public var maxPower: Double = 1500
        /// Standard deviation of reported power, W.
        public var powerNoise: Double = 3

        public init() {}
    }

    public struct Rider: Equatable, Sendable {
        public var cadence: Double = 85
        /// Standard deviation of cadence, rpm.
        public var cadenceNoise: Double = 1.5
        public var chainring: Int = 50
        public var cog: Int = 17
        public var wheelCircumference: Double = 2.1

        public init() {}

        public var ratio: Double { Double(chainring) / Double(cog) }
    }

    public enum Mode: Equatable, Sendable {
        case simulation(SimulationParameters)
        case targetPower(watts: Double)
    }

    public var characteristics: Characteristics
    public var rider: Rider
    public private(set) var mode: Mode = .simulation(.flat)
    public private(set) var hasControl = false
    public private(set) var isStarted = false
    public private(set) var elapsedTime: TimeInterval = 0
    public private(set) var distance: Double = 0

    private var rng: SplitMix64

    public init(characteristics: Characteristics = .init(), rider: Rider = .init(), seed: UInt64 = 1) {
        self.characteristics = characteristics
        self.rider = rider
        self.rng = SplitMix64(seed: seed)
    }

    public static let feature = FitnessMachineFeature(
        machine: [.cadence, .totalDistance, .powerMeasurement, .elapsedTime],
        targetSetting: [.resistance, .power, .indoorBikeSimulation, .wheelCircumference, .spinDownControl]
    )
    public static let powerRange = SupportedPowerRange(minimum: 0, maximum: 1500, increment: 1)
    public static let resistanceRange = SupportedResistanceLevelRange(minimum: 0, maximum: 100, increment: 1)

    /// Handles a Control Point write the way an FTMS server would.
    public mutating func handle(_ request: ControlPointRequest) -> ControlPointResponse {
        if request == .requestControl {
            hasControl = true
            return ControlPointResponse(to: request, result: .success)
        }
        guard hasControl else {
            return ControlPointResponse(to: request, result: .controlNotPermitted)
        }
        switch request {
        case .reset:
            mode = .simulation(.flat)
            hasControl = false
            isStarted = false
        case .setIndoorBikeSimulation(let p):
            mode = .simulation(p)
        case .setTargetPower(let watts):
            mode = .targetPower(watts: Double(watts))
        case .startOrResume:
            isStarted = true
        case .stopOrPause:
            isStarted = false
        case .setWheelCircumference, .spinDownControl:
            break
        case .requestControl, .setTargetSpeed, .setTargetInclination, .setTargetResistanceLevel,
             .setTargetHeartRate, .setTargetedCadence, .unsupported:
            return ControlPointResponse(to: request, result: .opCodeNotSupported)
        }
        return ControlPointResponse(to: request, result: .success)
    }

    /// Noise-free force the trainer applies at `speed` (m/s) in its current mode.
    public func trainerForce(speed: Double) -> Double {
        let ch = characteristics
        let floor = ch.floorForce.value(at: speed)
        var ceilingParams = SimulationParameters(grade: ch.maxGrade)
        if case .simulation(let p) = mode { ceilingParams = SimulationParameters(windSpeed: p.windSpeed, grade: ch.maxGrade, crr: p.crr, cw: p.cw) }
        let ceiling = BikePhysics.resistiveForce(mass: ch.simulationMass, speed: speed, parameters: ceilingParams)
            + ch.parasiticForce.value(at: speed)

        var force: Double
        switch mode {
        case .simulation(var p):
            p.grade = min(p.grade, ch.maxGrade)
            force = BikePhysics.resistiveForce(mass: ch.simulationMass, speed: speed, parameters: p)
                + ch.parasiticForce.value(at: speed)
        case .targetPower(let watts):
            force = speed > 0 ? watts / speed : 0
            force = min(force, ceiling)
        }
        force = max(force, floor)
        if speed > 0 { force = min(force, ch.maxPower / speed) }
        return force
    }

    /// Advances the model by `dt` seconds and returns the next notification.
    public mutating func step(dt: TimeInterval) -> IndoorBikeData {
        let cadence = max(rider.cadence + rider.cadenceNoise * rng.gaussian(), 0)
        let speed = BikePhysics.speed(cadence: cadence, ratio: rider.ratio, wheelCircumference: rider.wheelCircumference)
        let power = max(trainerForce(speed: speed) * speed + characteristics.powerNoise * rng.gaussian(), 0)
        elapsedTime += dt
        distance += speed * dt

        return IndoorBikeData(
            instantaneousSpeed: speed * 3.6,
            instantaneousCadence: cadence,
            totalDistance: UInt32(min(distance, Double(0xFF_FFFF))),
            instantaneousPower: quantize(power, scale: 1),
            elapsedTime: UInt16(min(elapsedTime, Double(UInt16.max)))
        )
    }
}

/// Small deterministic PRNG so mock rides and tests are reproducible.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal sample (Box–Muller).
    mutating func gaussian() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &self)
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
