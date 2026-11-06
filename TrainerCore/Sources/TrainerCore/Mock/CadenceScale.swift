import Foundation

/// Maps a slider position (0…1) to cadence non-linearly. By default 0–60 rpm
/// takes only the first 8 % of the track, the cadences people ride at
/// (60–100 rpm) get 77 %, and 100–120 the last 15 %.
///
/// The curve passes through `points` and is a monotone cubic (Fritsch–Butland
/// tangents), so the slider's sensitivity changes smoothly between the ranges
/// instead of jumping at each breakpoint, and cadence never runs backwards.
public struct CadenceScale: Equatable, Sendable {
    /// (position, cadence) points, both strictly increasing, from (0, 0) to (1, max).
    public var points: [(position: Double, cadence: Double)]

    public static func == (a: Self, b: Self) -> Bool {
        a.points.elementsEqual(b.points) { $0 == $1 }
    }

    public init(points: [(position: Double, cadence: Double)] = [(0, 0), (0.08, 60), (0.85, 100), (1, 120)]) {
        self.points = points
    }

    public var maxCadence: Double { points.last?.cadence ?? 0 }

    /// Cadence for a slider position, rounded to whole rpm.
    public func cadence(at position: Double) -> Double {
        exactCadence(at: position).rounded()
    }

    /// Unrounded cadence, rpm.
    public func exactCadence(at position: Double) -> Double {
        let x = min(max(position, 0), 1)
        let m = tangents
        for i in 0..<(points.count - 1) where x <= points[i + 1].position {
            let (x0, y0) = points[i], (x1, y1) = points[i + 1]
            let h = x1 - x0
            let t = (x - x0) / h
            let t2 = t * t, t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * h * m[i]
                + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * h * m[i + 1]
        }
        return maxCadence
    }

    /// Slider position for a cadence (inverse of `exactCadence`, by bisection).
    public func position(for cadence: Double) -> Double {
        if cadence <= 0 { return 0 }
        if cadence >= maxCadence { return 1 }
        let target = cadence
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if exactCadence(at: mid) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Slopes at each point: the weighted harmonic mean of the neighbouring
    /// segment slopes inside, the segment slope at the ends. Keeps the curve monotone.
    private var tangents: [Double] {
        let n = points.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }
        let h = (0..<(n - 1)).map { points[$0 + 1].position - points[$0].position }
        let d = (0..<(n - 1)).map { (points[$0 + 1].cadence - points[$0].cadence) / h[$0] }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) where d[i - 1] > 0 && d[i] > 0 {
            m[i] = 3 * (h[i - 1] + h[i]) / ((2 * h[i] + h[i - 1]) / d[i - 1] + (h[i] + 2 * h[i - 1]) / d[i])
        }
        return m
    }
}
