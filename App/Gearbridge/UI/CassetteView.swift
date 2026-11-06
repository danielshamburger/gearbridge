import SwiftUI

/// A cassette at a glance: one bar per cog, sized to its teeth, easiest
/// (biggest) on the left, the current gear highlighted. The highlight slides
/// as you shift.
struct CassetteView: View {
    /// Easiest first (see `GearProfile.cogSizes`).
    let cogSizes: [Double]
    let selected: Int?
    var tint: Color = .accentColor
    var height: CGFloat = 26

    var body: some View {
        let biggest = cogSizes.max() ?? 1
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(cogSizes.enumerated()), id: \.offset) { index, size in
                Capsule()
                    .fill(index == selected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary.opacity(0.35)))
                    .frame(width: barWidth, height: max(height * size / biggest, barWidth))
            }
        }
        .frame(height: height)
        .animation(.snappy(duration: 0.15), value: selected)
        .accessibilityHidden(true)   // the gear number carries this
    }

    private var barWidth: CGFloat { cogSizes.count > 14 ? 4 : 6 }
    private var spacing: CGFloat { cogSizes.count > 14 ? 2 : 3 }
}
