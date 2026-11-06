import SwiftUI
import TrainerCore
import UIKit

/// The riding screen: gear, shifting and live numbers. Setup lives in `SettingsView`.
struct RideView: View {
    @Bindable var bridge: BridgeController
    @State private var volumeShifter = VolumeButtonShifter()
    @State private var limitFlash = false
    @State private var showingSettings = false
    @State private var confirmingEnd = false

    var body: some View {
        NavigationStack {
            List {
                gearSection
                liveSection
                statusSection
            }
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

    private var gearSection: some View {
        Section {
            HStack(spacing: 12) {
                shiftButton(.down, symbol: "minus", label: "Easier gear")
                gearReadout.frame(maxWidth: .infinity)
                shiftButton(.up, symbol: "plus", label: "Harder gear")
            }
            .padding(.vertical, 8)
            if let note = shiftingNote {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
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
                .frame(width: 84, height: 96)
        }
        .buttonStyle(.borderedProminent)
        .buttonRepeatBehavior(.enabled)
        .disabled(bridge.gearNumber == nil)
        .accessibilityLabel(label)
    }

    // MARK: Live data

    private var liveSection: some View {
        Section {
            HStack {
                Readout(title: "Power", value: bridge.latestData?.instantaneousPower.map { "\($0)" }, unit: "W")
                Readout(title: "Cadence", value: bridge.latestData?.instantaneousCadence.map { String(format: "%.0f", $0) }, unit: "rpm")
                Readout(title: "Speed", value: bridge.latestData?.instantaneousSpeed.map { String(format: "%.1f", $0) }, unit: "km/h")
            }
            .padding(.vertical, 4)
            LabeledContent("Zwift command", value: bridge.commandLabel)
            if let grade = bridge.trainerGrade {
                LabeledContent("Trainer grade", value: String(format: "%.1f%%", grade * 100))
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

private struct Readout: View {
    let title: String
    let value: String?
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
