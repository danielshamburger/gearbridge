import SwiftUI

/// A 270° arc gauge: a faint track with a coloured arc filling to `value`
/// within `range`, eased so readings glide instead of jumping.
struct ArcGauge: View {
    let value: Double?
    let range: ClosedRange<Double>
    let tint: Color
    var lineWidth: CGFloat = 8

    private static let sweep = 0.75   // fraction of a full circle

    private var fraction: Double {
        guard let value, range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        ZStack {
            arc(to: 1).stroke(tint.opacity(0.15), style: stroke)
            arc(to: fraction).stroke(tint, style: stroke)
        }
        // Gap at the bottom: start at 135° (lower left), sweep clockwise.
        .rotationEffect(.degrees(135))
        .animation(.easeOut(duration: 0.4), value: fraction)
        .padding(lineWidth / 2)
        .accessibilityHidden(true)   // the number below carries the value
    }

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: .round) }

    private func arc(to fraction: Double) -> some Shape {
        Circle().trim(from: 0, to: Self.sweep * fraction)
    }
}
