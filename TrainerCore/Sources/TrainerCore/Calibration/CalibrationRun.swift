import Foundation

/// One step of the calibration routine: hold `targetCadence` while the trainer
/// is commanded `grade` (with Crr = Cw = wind = 0).
public struct CalibrationStep: Equatable, Sendable {
    public var grade: Double
    public var targetCadence: Double
    /// Trainer speed at the target cadence in the real gear, m/s.
    public var targetSpeed: Double
    /// Floor steps use a steep descent to measure the trainer's minimum force.
    public var isFloor: Bool

    public init(grade: Double, targetCadence: Double, targetSpeed: Double, isFloor: Bool = false) {
        self.grade = grade
        self.targetCadence = targetCadence
        self.targetSpeed = targetSpeed
        self.isFloor = isFloor
    }

    public var command: ControlPointRequest {
        .setIndoorBikeSimulation(SimulationParameters(windSpeed: 0, grade: grade, crr: 0, cw: 0))
    }
}

/// Builds the list of steps. At each grade (easiest first) the rider holds a
/// high and a low cadence, skipping any cadence whose predicted power is over
/// `powerCap`, and stopping once no cadence fits. Two floor steps finish the run.
public struct CalibrationPlan: Equatable, Sendable {
    public var grades: [Double] = [0, 0.02, 0.04, 0.06, 0.08, 0.10]
    /// Candidate cadences, highest first.
    public var cadences: [Double] = [90, 75, 60, 50]
    /// Highest power the rider is asked to hold for a step, W.
    public var powerCap: Double = 350
    public var floorGrade: Double = -0.15
    public var floorCadences: [Double] = [90, 60]
    public var wheelCircumference: Double = 2.1

    public init() {}

    public func steps(for rider: RiderSetup) -> [CalibrationStep] {
        let guess = TrainerCalibration.nominal()
        func speed(_ cadence: Double) -> Double { cadence / 60 * rider.realRatio * wheelCircumference }
        // Nominal model plus a few newtons of drag: only used to keep steps rideable.
        func predictedPower(_ grade: Double, _ cadence: Double) -> Double {
            let v = speed(cadence)
            return (guess.force(grade: grade, speed: v) + 5) * v
        }

        var steps: [CalibrationStep] = []
        for grade in grades.sorted() {
            let fitting = cadences.filter { predictedPower(grade, $0) <= powerCap }
            guard let high = fitting.first, let low = fitting.last else { break }
            for cadence in high == low ? [high] : [high, low] {
                steps.append(CalibrationStep(grade: grade, targetCadence: cadence, targetSpeed: speed(cadence)))
            }
        }
        for cadence in floorCadences {
            steps.append(CalibrationStep(
                grade: floorGrade, targetCadence: cadence, targetSpeed: speed(cadence), isFloor: true))
        }
        return steps
    }
}

/// What a finished run measured and the calibration fitted from it.
public struct CalibrationResult: Equatable, Sendable {
    public var calibration: TrainerCalibration
    public var fit: CalibrationFit
    /// One averaged sample per completed step.
    public var measurements: [CalibrationMeasurement]
    /// True if force was seen to stop rising; false means `maxGrade` is the assumed value.
    public var maxGradeMeasured: Bool
}

public struct CalibrationMeasurement: Equatable, Sendable {
    public var step: CalibrationStep
    public var sample: CalibrationSample
}

/// The calibration routine as a state machine. Feed it trainer data; it returns
/// the command to send the trainer whenever the step changes.
///
/// Each step settles for `settleTime`, then averages speed and power over
/// `sampleTime`. If speed wasn't steady (or the rider stopped), the sample
/// window restarts. Time is a monotonic clock in seconds.
public struct CalibrationRun: Sendable {
    public enum Phase: Equatable, Sendable {
        case notStarted
        case settling(since: TimeInterval)
        case sampling(since: TimeInterval)
        case finished(CalibrationResult)
        case failed(CalibrationError)
        case cancelled

        public var isActive: Bool {
            switch self {
            case .settling, .sampling: true
            default: false
            }
        }
    }

    public let steps: [CalibrationStep]
    public let realCog: Int
    public var settleTime: TimeInterval = 10
    public var sampleTime: TimeInterval = 10
    /// Largest speed standard deviation, as a fraction of the mean, for a steady sample.
    public var maxSpeedVariation = 0.05
    /// Used when force never stops rising within the measured grades.
    public var assumedMaxGrade = 0.10

    public private(set) var phase: Phase = .notStarted
    public private(set) var stepIndex = 0
    public private(set) var measurements: [CalibrationMeasurement] = []
    /// Times the current step's sample window restarted for being unsteady.
    public private(set) var restarts = 0

    private var window: [(speed: Double, power: Double)] = []

    public init(steps: [CalibrationStep], realCog: Int) {
        self.steps = steps
        self.realCog = realCog
    }

    public init(plan: CalibrationPlan = .init(), rider: RiderSetup) {
        self.init(steps: plan.steps(for: rider), realCog: rider.realCog)
    }

    public var currentStep: CalibrationStep? {
        phase.isActive ? steps[stepIndex] : nil
    }

    /// 0…1 through the current step's settle + sample time.
    public func stepProgress(at time: TimeInterval) -> Double {
        switch phase {
        case .settling(let since):
            min((time - since) / (settleTime + sampleTime), 1)
        case .sampling(let since):
            min((settleTime + time - since) / (settleTime + sampleTime), 1)
        default:
            0
        }
    }

    public mutating func start(at time: TimeInterval) -> ControlPointRequest? {
        guard phase == .notStarted, !steps.isEmpty else { return nil }
        return begin(step: 0, at: time)
    }

    /// Feed every trainer data packet. Returns a command when the step changes.
    public mutating func handle(_ data: IndoorBikeData, at time: TimeInterval) -> ControlPointRequest? {
        switch phase {
        case .settling(let since):
            if time - since >= settleTime {
                phase = .sampling(since: time)
                window = []
            }
            return nil
        case .sampling(let since):
            if let speed = data.speedMetersPerSecond, let power = data.instantaneousPower {
                window.append((speed, Double(power)))
            }
            guard time - since >= sampleTime else { return nil }
            if let sample = steadySample() {
                measurements.append(CalibrationMeasurement(step: steps[stepIndex], sample: sample))
                return advance(at: time)
            }
            restarts += 1
            phase = .sampling(since: time)
            window = []
            return nil
        default:
            return nil
        }
    }

    /// Gives up on the current step (e.g. it's too hard) and moves on.
    public mutating func skipStep(at time: TimeInterval) -> ControlPointRequest? {
        guard phase.isActive else { return nil }
        return advance(at: time)
    }

    public mutating func cancel() {
        if phase.isActive { phase = .cancelled }
    }

    // MARK: Internals

    private mutating func begin(step index: Int, at time: TimeInterval) -> ControlPointRequest {
        stepIndex = index
        restarts = 0
        window = []
        phase = .settling(since: time)
        return steps[index].command
    }

    private mutating func advance(at time: TimeInterval) -> ControlPointRequest? {
        if stepIndex + 1 < steps.count { return begin(step: stepIndex + 1, at: time) }
        do {
            phase = .finished(try Self.result(from: measurements, realCog: realCog, assumedMaxGrade: assumedMaxGrade))
        } catch let error as CalibrationError {
            phase = .failed(error)
        } catch {
            phase = .failed(.degenerate)
        }
        return nil
    }

    private func steadySample() -> CalibrationSample? {
        guard window.count >= 3 else { return nil }
        let n = Double(window.count)
        let meanSpeed = window.map(\.speed).reduce(0, +) / n
        guard meanSpeed >= 1 else { return nil }
        let variance = window.map { ($0.speed - meanSpeed) * ($0.speed - meanSpeed) }.reduce(0, +) / n
        guard variance.squareRoot() / meanSpeed <= maxSpeedVariation else { return nil }
        let meanPower = window.map(\.power).reduce(0, +) / n
        return CalibrationSample(grade: steps[stepIndex].grade, speed: meanSpeed, power: meanPower)
    }

    // MARK: Fitting

    /// Detects saturation, fits the force model below it, and fits the floor.
    ///
    /// Saturation: walking up the grades from the fourth, fit the grades below
    /// and predict this one; if measured force falls short by more than a
    /// quarter of the expected rise from the previous grade, force has stopped
    /// rising and the previous grade is the maximum.
    public static func result(
        from measurements: [CalibrationMeasurement],
        realCog: Int?,
        assumedMaxGrade: Double = 0.10
    ) throws -> CalibrationResult {
        let climb = measurements.filter { !$0.step.isFloor }.map(\.sample)
        let grades = Array(Set(climb.map(\.grade))).sorted()

        var maxGrade: Double?
        if grades.count >= 4 {
            for k in 3..<grades.count {
                let below = try CalibrationFitter.fitForceModel(climb.filter { $0.grade < grades[k] })
                let here = climb.filter { $0.grade == grades[k] }
                let shortfall = here.map { below.a + below.b * $0.grade + below.c * $0.speed - $0.force }
                    .reduce(0, +) / Double(here.count)
                if shortfall > 0.25 * below.b * (grades[k] - grades[k - 1]) {
                    maxGrade = grades[k - 1]
                    break
                }
            }
        }

        let usable = climb.filter { $0.grade <= (maxGrade ?? .infinity) }
        let fit = try CalibrationFitter.fitForceModel(usable)

        let floorPoints = measurements.filter(\.step.isFloor).map { (speed: $0.sample.speed, force: $0.sample.force) }
        let floor = CalibrationFitter.fitFloor(floorPoints)
            ?? LinearModel(intercept: floorPoints.map(\.force).min() ?? 0, slope: 0)

        let calibration = fit.calibration(
            maxGrade: maxGrade ?? max(grades.last ?? 0, assumedMaxGrade),
            floorForce: floor,
            realCog: realCog
        )
        return CalibrationResult(
            calibration: calibration,
            fit: fit,
            measurements: measurements,
            maxGradeMeasured: maxGrade != nil
        )
    }
}
