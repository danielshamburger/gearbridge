/// One steady-state measurement during calibration.
public struct CalibrationSample: Equatable, Sendable {
    /// Commanded grade (fraction), sent with Crr = Cw = wind = 0.
    public var grade: Double
    /// Trainer speed, m/s.
    public var speed: Double
    /// Measured power, W.
    public var power: Double

    public init(grade: Double, speed: Double, power: Double) {
        self.grade = grade
        self.speed = speed
        self.power = power
    }

    /// F = P ÷ v
    public var force: Double { power / speed }
}

public enum CalibrationError: Error, Equatable, Sendable {
    /// Need at least three usable samples (speed above the minimum).
    case insufficientSamples(Int)
    /// Samples don't vary enough in both grade and speed to separate a, b and c.
    case degenerate
}

/// Result of fitting F = a + b · grade + c · v.
public struct CalibrationFit: Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    /// Measured minus predicted force, N, one per usable sample.
    public var residuals: [Double]
    public var residualRMS: Double
    public var rSquared: Double

    /// Combines the fit with the measured limits into a stored calibration.
    public func calibration(maxGrade: Double, floorForce: LinearModel, realCog: Int?) -> TrainerCalibration {
        TrainerCalibration(
            a: a, b: b, c: c,
            maxGrade: maxGrade,
            floorForce: floorForce,
            realCog: realCog,
            residualRMS: residualRMS
        )
    }
}

public enum CalibrationFitter {
    /// Least-squares fit of F = a + b · grade + c · v. Samples slower than
    /// `minimumSpeed` are dropped, since P ÷ v is unreliable near standstill.
    /// Exclude samples above the trainer's max grade first, or saturation biases b.
    public static func fitForceModel(
        _ samples: [CalibrationSample],
        minimumSpeed: Double = 1.0
    ) throws -> CalibrationFit {
        let usable = samples.filter { $0.speed >= minimumSpeed && $0.power.isFinite }
        guard usable.count >= 3 else { throw CalibrationError.insufficientSamples(usable.count) }

        // Normal equations: (XᵀX) β = Xᵀy with rows x = [1, grade, speed].
        var ata = [[Double]](repeating: [0, 0, 0], count: 3)
        var aty = [0.0, 0, 0]
        for s in usable {
            let x = [1, s.grade, s.speed]
            for i in 0..<3 {
                aty[i] += x[i] * s.force
                for j in 0..<3 { ata[i][j] += x[i] * x[j] }
            }
        }
        guard let beta = solve(ata, aty) else { throw CalibrationError.degenerate }
        let (a, b, c) = (beta[0], beta[1], beta[2])

        let residuals = usable.map { $0.force - (a + b * $0.grade + c * $0.speed) }
        let ssRes = residuals.map { $0 * $0 }.reduce(0, +)
        let meanF = usable.map(\.force).reduce(0, +) / Double(usable.count)
        let ssTot = usable.map { ($0.force - meanF) * ($0.force - meanF) }.reduce(0, +)

        return CalibrationFit(
            a: a, b: b, c: c,
            residuals: residuals,
            residualRMS: (ssRes / Double(usable.count)).squareRoot(),
            rSquared: ssTot > 0 ? 1 - ssRes / ssTot : 1
        )
    }

    /// The grade where force stops rising.
    ///
    /// `points` are mean force per commanded grade, measured at a similar speed.
    /// Walks up the grades and stops at the first step whose force slope falls
    /// below `saturationFraction` of the first step's slope. Returns the last
    /// grade if force never flattens, nil with fewer than two points or no rise.
    public static func detectMaxGrade(
        _ points: [(grade: Double, force: Double)],
        saturationFraction: Double = 0.5
    ) -> Double? {
        let sorted = points.sorted { $0.grade < $1.grade }
        guard sorted.count >= 2 else { return nil }
        func slope(_ i: Int) -> Double {
            (sorted[i].force - sorted[i - 1].force) / (sorted[i].grade - sorted[i - 1].grade)
        }
        let baseline = slope(1)
        guard baseline > 0 else { return nil }
        for i in 2..<sorted.count where slope(i) < saturationFraction * baseline {
            return sorted[i - 1].grade
        }
        return sorted.last!.grade
    }

    /// Linear fit of the trainer's minimum force against speed.
    public static func fitFloor(_ points: [(speed: Double, force: Double)]) -> LinearModel? {
        LinearModel.fit(points.map { (x: $0.speed, y: $0.force) })
    }

    /// Gaussian elimination with partial pivoting. Nil if (near) singular.
    static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var m = matrix
        var y = rhs
        let scale = m.flatMap { $0 }.map(abs).max() ?? 0
        guard scale > 0 else { return nil }

        for col in 0..<n {
            let pivot = (col..<n).max { abs(m[$0][col]) < abs(m[$1][col]) }!
            guard abs(m[pivot][col]) > 1e-12 * scale else { return nil }
            m.swapAt(col, pivot)
            y.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let factor = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= factor * m[col][k] }
                y[row] -= factor * y[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            let tail = ((row + 1)..<n).map { m[row][$0] * x[$0] }.reduce(0, +)
            x[row] = (y[row] - tail) / m[row][row]
        }
        return x
    }
}
