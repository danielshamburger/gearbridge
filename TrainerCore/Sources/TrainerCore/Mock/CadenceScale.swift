import Foundation

/// Maps a slider position (0…1) to cadence non-linearly, as straight segments
/// between breakpoints. By default the cadences people ride at (60–100 rpm)
/// get 70 % of the track; 0–60 and 100–120 are passed through quickly.
public struct CadenceScale: Equatable, Sendable {
    /// (position, cadence) points, both strictly increasing, from (0, 0) to (1, max).
    public var points: [(position: Double, cadence: Double)]

    public static func == (a: Self, b: Self) -> Bool {
        a.points.elementsEqual(b.points) { $0 == $1 }
    }

    public init(points: [(position: Double, cadence: Double)] = [(0, 0), (0.15, 60), (0.85, 100), (1, 120)]) {
        self.points = points
    }

    public var maxCadence: Double { points.last?.cadence ?? 0 }

    /// Cadence for a slider position, rounded to whole rpm.
    public func cadence(at position: Double) -> Double {
        interpolate(min(max(position, 0), 1), from: \.position, to: \.cadence).rounded()
    }

    /// Slider position for a cadence.
    public func position(for cadence: Double) -> Double {
        interpolate(min(max(cadence, 0), maxCadence), from: \.cadence, to: \.position)
    }

    private func interpolate(
        _ x: Double,
        from key: KeyPath<(position: Double, cadence: Double), Double>,
        to value: KeyPath<(position: Double, cadence: Double), Double>
    ) -> Double {
        for (a, b) in zip(points, points.dropFirst()) where x <= b[keyPath: key] {
            let t = (x - a[keyPath: key]) / (b[keyPath: key] - a[keyPath: key])
            return a[keyPath: value] + t * (b[keyPath: value] - a[keyPath: value])
        }
        return points.last?[keyPath: value] ?? 0
    }
}
