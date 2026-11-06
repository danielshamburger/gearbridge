import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The ride's Live Activity.
/// - Lock screen: − / + with the gear and cassette between them.
/// - Dynamic Island: the gear number; long-press for − / +; tap to open the app.
struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ShiftButton(harder: false, enabled: state.gear != nil, size: 52)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ShiftButton(harder: true, enabled: state.gear != nil, size: 52)
                }
                DynamicIslandExpandedRegion(.center) {
                    GearReadout(state: state, numberSize: 34)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let gear = state.gear {
                        CassetteStrip(cogSizes: state.cogSizes, selected: gear - 1, height: 16)
                            .padding(.top, 2)
                    }
                }
            } compactLeading: {
                Image(systemName: "figure.indoor.cycle")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Text(state.gear.map(String.init) ?? "–")
                    .font(.body.monospacedDigit().bold())
                    .contentTransition(.numericText())
            } minimal: {
                Text(state.gear.map(String.init) ?? "–")
                    .font(.body.monospacedDigit().bold())
            }
            .keylineTint(.blue)
        }
    }
}

private struct LockScreenView: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            ShiftButton(harder: false, enabled: state.gear != nil, size: 64)
            VStack(spacing: 6) {
                GearReadout(state: state, numberSize: 40)
                if let gear = state.gear {
                    CassetteStrip(cogSizes: state.cogSizes, selected: gear - 1, height: 18)
                }
            }
            .frame(maxWidth: .infinity)
            ShiftButton(harder: true, enabled: state.gear != nil, size: 64)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

private struct GearReadout: View {
    let state: RideActivityAttributes.ContentState
    let numberSize: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if let gear = state.gear {
                Text("\(gear)")
                    .font(.system(size: numberSize, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(["of \(state.gearCount)", state.label].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Virtual shifting off")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// − (easier) or + (harder). Runs `ShiftIntent` in the app without opening it.
private struct ShiftButton: View {
    let harder: Bool
    let enabled: Bool
    let size: CGFloat

    var body: some View {
        Button(intent: ShiftIntent(harder: harder)) {
            Image(systemName: harder ? "plus" : "minus")
                .font(.system(size: size * 0.4, weight: .bold))
                .frame(width: size, height: size)
                .background(.white.opacity(0.18), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(harder ? "Harder gear" : "Easier gear")
    }
}

/// The cassette at a glance: one bar per cog, the current one highlighted.
/// (A copy of the app's CassetteView; the extension doesn't link the app.)
private struct CassetteStrip: View {
    let cogSizes: [Double]
    let selected: Int
    let height: CGFloat

    var body: some View {
        let biggest = cogSizes.max() ?? 1
        HStack(spacing: 2) {
            ForEach(Array(cogSizes.enumerated()), id: \.offset) { index, size in
                Capsule()
                    .fill(index == selected ? Color.blue : Color.white.opacity(0.35))
                    .frame(width: 4, height: max(height * size / biggest, 4))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
