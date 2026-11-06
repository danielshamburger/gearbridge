import SwiftUI
import TrainerCore
import UIKit

/// The riding screen: live numbers and status at the top, the gear and shift
/// buttons pinned near the bottom where a thumb reaches them. Setup lives in
/// `SettingsView`.
struct RideView: View {
    @Bindable var bridge: BridgeController
    @State private var volumeShifter = VolumeButtonShifter()
    @State private var limitFlash = false
    @State private var showingSettings = false
    @State private var confirmingEnd = false

    var body: some View {
        NavigationStack {
            // Fixed layout, no scrolling: full-size gauges if they fit, smaller ones if not
            // (small phones, debug mode).
            ViewThatFits(in: .vertical) {
                mainContent(scale: 1)
                mainContent(scale: 0.78)
                mainContent(scale: 0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { shiftPanel }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        StatusPill(symbol: "dot.radiowaves.left.and.right", title: "Trainer",
                                   detail: bridge.trainerState.label, health: trainerHealth)
                        StatusPill(symbol: "display", title: "Zwift",
                                   detail: bridge.zwiftLabel, health: zwiftHealth)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("End ride", role: .destructive) { confirmingEnd = true }
                        .confirmationDialog("End this ride?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                            Button("End ride", role: .destructive) { bridge.endRide() }
                        } message: {
                            Text("The trainer disconnects and Zwift stops getting data, but stays paired for your next ride. The packet log is kept for export.")
                        }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .background {
            // Only on screen while volume shifting is on: it also hides the
            // system volume HUD, which should appear normally otherwise.
            if volumeShiftingActive {
                VolumeButtonHost(shifter: volumeShifter).frame(width: 1, height: 1)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            volumeShifter.onShift = { [bridge] direction in bridge.shift(direction) }
            updateVolumeShifter()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            volumeShifter.onShift = nil
            volumeShifter.stop()
        }
        .onChange(of: volumeShiftingActive) { updateVolumeShifter() }
        .onChange(of: bridge.lastShift) { _, event in
            guard let event else { return }
            if case .shifted = event.outcome { return }
            limitFlash = true
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                limitFlash = false
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(bridge: bridge) }
    }

    private var volumeShiftingActive: Bool {
        bridge.volumeButtonsShift && bridge.virtualShifting
    }

    private func updateVolumeShifter() {
        if volumeShiftingActive { volumeShifter.start() } else { volumeShifter.stop() }
    }

    // MARK: Gear

    /// Pinned above the bottom edge, raised well clear of the home indicator so a
    /// thumb hits the buttons without triggering the swipe-home gesture.
    private var shiftPanel: some View {
        VStack(spacing: 10) {
            if let note = shiftingNote {
                Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                shiftButton(.down, symbol: "minus", label: "Easier gear")
                gearReadout.frame(maxWidth: .infinity)
                shiftButton(.up, symbol: "plus", label: "Harder gear")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var gearReadout: some View {
        VStack(spacing: 2) {
            Text(bridge.gearNumber.map(String.init) ?? "–")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: bridge.gearNumber)
                .foregroundStyle(limitFlash ? .red : .primary)
            if let number = bridge.gearNumber {
                CassetteView(cogSizes: bridge.profile.cogSizes, selected: number - 1,
                             tint: limitFlash ? .red : .accentColor)
                    .padding(.vertical, 4)
            }
            Text(gearCaption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if bridge.limit != .none {
                Text(bridge.limit == .maximum ? "MAX RESISTANCE" : "MIN RESISTANCE")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(bridge.limit == .maximum ? Color.red : Color.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var gearCaption: String {
        guard let n = bridge.gearNumber, let ratio = bridge.gearRatio else { return "Virtual shifting off" }
        let gear = bridge.gearLabel ?? String(format: "ratio %.2f", ratio)
        return "of \(bridge.gearCount) · \(gear)" + (n == bridge.gearCount ? " · top" : "")
    }

    private var shiftingNote: String? {
        if bridge.gearNumber == nil { return nil }
        if case .targetPower = bridge.zwiftMode { return "ERG mode: Zwift sets the power, so shifting is paused." }
        return nil
    }

    private func shiftButton(_ direction: Gearbox.Direction, symbol: String, label: String) -> some View {
        Button {
            bridge.shift(direction)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .bold))
                .frame(width: 96, height: 104)
        }
        .buttonStyle(.borderedProminent)
        .buttonRepeatBehavior(.enabled)
        .disabled(bridge.gearNumber == nil)
        .accessibilityLabel(label)
    }

    // MARK: Live data

    /// The screen's body at a given gauge scale; `ViewThatFits` picks the largest that fits.
    private func mainContent(scale: CGFloat) -> some View {
        VStack(spacing: 10) {
            if let alert = bridge.alertLabel {
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            gaugesCard(scale: scale)
            if bridge.source == .mock { mockCard }
            if bridge.debugMode { debugCard }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func gaugesCard(scale: CGFloat) -> some View {
        let data = bridge.latestData
        return VStack(spacing: 12 * scale) {
            GaugeReadout(title: "Power", symbol: "bolt.fill",
                         value: data?.instantaneousPower.map { "\($0)" }, unit: "W",
                         gauge: data?.instantaneousPower.map(Double.init), range: 0...bridge.powerGauge.upperBound,
                         tint: .orange, size: 200 * scale, lineWidth: 14 * scale, valueSize: 60 * scale, unitBeside: true)
            HStack(spacing: 24) {
                GaugeReadout(title: "Cadence", symbol: "arrow.triangle.2.circlepath",
                             value: data?.instantaneousCadence.map { String(format: "%.0f", $0) }, unit: "rpm",
                             gauge: data?.instantaneousCadence, range: 0...120,
                             tint: .teal, size: 120 * scale, lineWidth: 9 * scale, valueSize: 32 * scale)
                // The gauge's fill is a fraction, so it works in km/h whatever the display unit.
                GaugeReadout(title: "Speed", symbol: "speedometer",
                             value: data?.instantaneousSpeed.map { String(format: "%.1f", bridge.speedUnit.fromKilometersPerHour($0)) },
                             unit: bridge.speedUnit.label,
                             gauge: data?.instantaneousSpeed, range: 0...bridge.speedGauge.upperBound,
                             tint: .indigo, size: 120 * scale, lineWidth: 9 * scale, valueSize: 32 * scale)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// The mock rider's control, in its own card: it's an input, not a readout.
    private var mockCard: some View {
        HStack(spacing: 12) {
            Text("Cadence").font(.subheadline).foregroundStyle(.secondary)
            CadenceSlider(cadence: $bridge.mockCadence)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Debug mode only: the bridge's internals, compact so the screen still doesn't scroll.
    private var debugCard: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            debugRow("Trainer", bridge.trainerState.label)
            debugRow("Zwift", bridge.zwiftLabel)
            debugRow("Real gear", "\(bridge.rider.realChainring)×\(bridge.rider.realCog)")
            debugRow("Zwift command", bridge.commandLabel)
            if let grade = bridge.trainerGrade {
                debugRow("Trainer grade", String(format: "%.1f%%", grade * 100))
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // MARK: Status pills

    private var trainerHealth: StatusPill.Health {
        switch bridge.trainerState {
        case .connected: .good
        case .scanning, .connecting, .disconnected: .working
        case .bluetoothUnavailable: .bad
        case .idle: .off
        }
    }

    private var zwiftHealth: StatusPill.Health {
        switch bridge.zwiftState {
        case .advertising: bridge.zwiftSubscribers > 0 ? .good : .working
        case .starting: .working
        case .unavailable, .failed: .bad
        case .stopped: .off
        }
    }
}

/// A compact status indicator for the navigation bar: icon, name and a
/// coloured dot. Tap for the full status text.
private struct StatusPill: View {
    enum Health { case good, working, bad, off }

    let symbol: String
    let title: String
    let detail: String
    let health: Health
    @State private var showingDetail = false

    var body: some View {
        Button { showingDetail = true } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Image(systemName: symbol).imageScale(.small)
                Text(title)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetail) {
            Text(detail).font(.footnote).padding().presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("\(title): \(detail)")
    }

    private var color: Color {
        switch health {
        case .good: .green
        case .working: .orange
        case .bad: .red
        case .off: .gray
        }
    }
}

/// A ring gauge with its number inside and its label in the gap at the bottom.
private struct GaugeReadout: View {
    let title: String
    /// SF Symbol shown with the label, in the gauge's colour.
    let symbol: String
    let value: String?
    let unit: String
    let gauge: Double?
    let range: ClosedRange<Double>
    let tint: Color
    let size: CGFloat
    let lineWidth: CGFloat
    let valueSize: CGFloat
    /// Unit beside the number ("247 W") instead of below it.
    var unitBeside = false

    var body: some View {
        ZStack {
            ArcGauge(value: gauge, range: range, tint: tint, lineWidth: lineWidth)
            Group {
                if unitBeside {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        number
                        Text(unit).font(.system(size: valueSize * 0.4, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 0) {
                        number
                        Text(unit).font(.system(size: valueSize * 0.3)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, lineWidth + 8)
            // The ring's open gap is at the bottom: the label sits there.
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.system(size: max(valueSize * 0.28, 11), weight: .medium))
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0) \(unit)" } ?? "no reading")
    }

    private var number: some View {
        Text(value ?? "–")
            .font(.system(size: valueSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
    }
}
