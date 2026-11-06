import SwiftUI
import TrainerCore

/// The opening screen. Nothing connects or records until a ride starts.
struct HomeView: View {
    @Bindable var bridge: BridgeController
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 8) {
                    bridgeMark
                    Text("TrainerCtrl").font(.largeTitle.bold())
                }
                summary
                Spacer()
                VStack(spacing: 12) {
                    Button {
                        bridge.startRide()
                    } label: {
                        Label("Start ride", systemImage: "play.fill")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .background(alignment: .bottom) {
                // The Mackinac Bridge, faint, spanning the gap above the buttons.
                // Wider than the screen so the towers sit near the edges and
                // the approaches run off both sides.
                GeometryReader { geo in
                    SuspensionBridgeArt()
                        .frame(width: geo.size.width * 1.65, height: 190)
                        .position(x: geo.size.width / 2, y: geo.size.height - 166 - 95)
                }
                .opacity(0.16)
                .allowsHitTesting(false)
            }
            .sheet(isPresented: $showingSettings) { SettingsView(bridge: bridge) }
        }
    }

    /// Trainer → phone → Zwift: what the app does, at a glance.
    private var bridgeMark: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.indoor.cycle").font(.system(size: 44, weight: .semibold))
            Image(systemName: "wave.3.right").font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
            Image(systemName: "iphone").font(.system(size: 44))
            Image(systemName: "wave.3.right").font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
            Image(systemName: "laptopcomputer").font(.system(size: 40))
        }
        .foregroundStyle(.tint)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }

    /// The current setup; tap to change it in Settings.
    private var summary: some View {
        Button {
            showingSettings = true
        } label: {
            HStack(spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Trainer", bridge.source.rawValue)
                    row("Gears", bridge.virtualShifting ? bridge.profile.name : "Virtual shifting off")
                    if bridge.virtualShifting {
                        row("Shifting", bridge.activeModel.rawValue)
                    }
                    row("Real gear", "\(bridge.rider.realChainring)×\(bridge.rider.realCog)")
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
