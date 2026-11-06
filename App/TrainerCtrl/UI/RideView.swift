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
            List {
                liveSection
                statusSection
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { shiftPanel }
            .navigationTitle("TrainerCtrl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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

    /// Pinned above the bottom edge, raised clear of the home indicator so a
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
        .padding(.bottom, 28)
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

    private var liveSection: some View {
        Section {
            let data = bridge.latestData
            VStack(spacing: 12) {
                GaugeReadout(title: "Power", value: data?.instantaneousPower.map { "\($0)" }, unit: "W",
                             gauge: data?.instantaneousPower.map(Double.init), range: 0...bridge.powerGauge.upperBound,
                             tint: .orange, size: 200, lineWidth: 14, valueSize: 60)
                HStack(spacing: 24) {
                    GaugeReadout(title: "Cadence", value: data?.instantaneousCadence.map { String(format: "%.0f", $0) }, unit: "rpm",
                                 gauge: data?.instantaneousCadence, range: 0...120,
                                 tint: .teal, size: 120, lineWidth: 9, valueSize: 32)
                    GaugeReadout(title: "Speed", value: data?.instantaneousSpeed.map { String(format: "%.1f", $0) }, unit: "km/h",
                                 gauge: data?.instantaneousSpeed, range: 0...bridge.speedGauge.upperBound,
                                 tint: .indigo, size: 120, lineWidth: 9, valueSize: 32)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            if bridge.debugMode {
                LabeledContent("Zwift command", value: bridge.commandLabel)
                if let grade = bridge.trainerGrade {
                    LabeledContent("Trainer grade", value: String(format: "%.1f%%", grade * 100))
                }
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            if let alert = bridge.alertLabel {
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Trainer", value: bridge.trainerState.label)
            LabeledContent("Real gear", value: "\(bridge.rider.realChainring)×\(bridge.rider.realCog)")
            LabeledContent("Zwift", value: bridge.zwiftLabel)
            if bridge.source == .mock {
                VStack(alignment: .leading) {
                    Text("Mock cadence: \(Int(bridge.mockCadence)) rpm")
                    CadenceSlider(cadence: $bridge.mockCadence)
                }
            }
        }
    }
}

/// A ring gauge with its number inside and its label in the gap at the bottom.
private struct GaugeReadout: View {
    let title: String
    let value: String?
    let unit: String
    let gauge: Double?
    let range: ClosedRange<Double>
    let tint: Color
    let size: CGFloat
    let lineWidth: CGFloat
    let valueSize: CGFloat

    var body: some View {
        ZStack {
            ArcGauge(value: gauge, range: range, tint: tint, lineWidth: lineWidth)
            VStack(spacing: 0) {
                Text(value ?? "–")
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                Text(unit).font(.system(size: valueSize * 0.3)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, lineWidth + 8)
            // The ring's open gap is at the bottom: the label sits there.
            Text(title)
                .font(.system(size: max(valueSize * 0.28, 11), weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0) \(unit)" } ?? "no reading")
    }
}
