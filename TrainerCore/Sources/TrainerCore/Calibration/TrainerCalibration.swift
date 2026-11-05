/// y = intercept + slope · x
public struct LinearModel: Equatable, Sendable, Codable {
    public var intercept: Double
    public var slope: Double

    public init(intercept: Double, slope: Double) {
        self.intercept = intercept
        self.slope = slope
    }

    public func value(at x: Double) -> Double {
        intercept + slope * x
    }

    /// Ordinary least squares. Nil with fewer than two distinct x values.
    public static func fit(_ points: [(x: Double, y: Double)]) -> LinearModel? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        let meanX = points.map(\.x).reduce(0, +) / n
        let meanY = points.map(\.y).reduce(0, +) / n
        let sxx = points.map { ($0.x - meanX) * ($0.x - meanX) }.reduce(0, +)
        guard sxx > 1e-12 else { return nil }
        let sxy = points.map { ($0.x - meanX) * ($0.y - meanY) }.reduce(0, +)
        let slope = sxy / sxx
        return LinearModel(intercept: meanY - slope * meanX, slope: slope)
    }
}

/// The trainer's measured force response when commanded a grade with
/// Crr = Cw = wind = 0:  F = a + b · grade + c · v_real.
///
/// Stored per real cog. Grades are fractions (0.05 = 5 %), speeds m/s, forces N.
public struct TrainerCalibration: Equatable, Sendable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    /// Highest grade at which force still rises.
    public var maxGrade: Double
    /// Lowest force the trainer can produce, as a function of speed.
    public var floorForce: LinearModel
    /// Real cog this was measured in; nil for the uncalibrated nominal model.
    public var realCog: Int?
    /// RMS of the fit residuals in N, shown in settings so a bad fit is visible.
    public var residualRMS: Double?

    public init(
        a: Double,
        b: Double,
        c: Double,
        maxGrade: Double,
        floorForce: LinearModel,
        realCog: Int? = nil,
        residualRMS: Double? = nil
    ) {
        self.a = a
        self.b = b
        self.c = c
        self.maxGrade = maxGrade
        self.floorForce = floorForce
        self.realCog = realCog
        self.residualRMS = residualRMS
    }

    /// Placeholder before calibration: assumes the trainer simulates a rider of
    /// `trainerMass` with no parasitic drag, and can't go below its grade-0 force.
    public static func nominal(trainerMass: Double = 75, maxGrade: Double = 0.10) -> TrainerCalibration {
        TrainerCalibration(
            a: 0,
            b: trainerMass * BikePhysics.gravity,
            c: 0,
            maxGrade: maxGrade,
            floorForce: LinearModel(intercept: 0, slope: 0)
        )
    }

    public func force(grade: Double, speed: Double) -> Double {
        a + b * grade + c * speed
    }

    /// The grade to command for the trainer to produce `force` at `speed`, unclamped.
    public func grade(forForce force: Double, speed: Double) -> Double {
        guard b > 0 else { return 0 }
        return (force - a - c * speed) / b
    }

    /// The lowest grade worth commanding at `speed`: below it the trainer sits at its floor.
    public func minGrade(speed: Double) -> Double {
        min(grade(forForce: floorForce.value(at: speed), speed: speed), maxGrade)
    }
}
