import SwiftUI
import TrainerCore
import UIKit

struct ContentView: View {
    @State private var bridge = BridgeController()
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    @State private var volumeShifter = VolumeButtonShifter()
    @State private var limitFlash = false

    var body: some View {
        NavigationStack {
            List {
                gearSection
                liveSection
                shiftingSection
                trainerSection
                zwiftSection
                logSection
            }
            .navigationTitle("TrainerCtrl")
            .navigationBarTitleDisplayMode(.inline)
        }
        .background { VolumeButtonHost(shifter: volumeShifter).frame(width: 1, height: 1) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            volumeShifter.onShift = { [bridge] direction in bridge.shift(direction) }
            volumeShifter.start()
        }
        .onChange(of: bridge.lastShift) { _, event in
            guard let event else { return }
            if case .shifted = event.outcome { return }
            limitFlash = true
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                limitFlash = false
            }
        }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
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
        return String(format: "of %d · ratio %.2f", bridge.gearCount, ratio) + (n == bridge.gearCount ? " · top" : "")
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

    private var shiftingSection: some View {
        Section {
            Toggle("Virtual shifting", isOn: $bridge.virtualShifting)
            Toggle("Send power to Zwift", isOn: $bridge.reportsPower)
        } header: {
            Text("Shifting")
        } footer: {
            Text("Volume buttons shift too: up is harder, down is easier. Turn off \"Send power to Zwift\" if Zwift takes power directly from the trainer over ANT+ (needed for \"power meter required\" events), then re-pair in Zwift.")
        }
    }

    private var trainerSection: some View {
        Section("Trainer") {
            Picker("Source", selection: $bridge.source) {
                ForEach(TrainerSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Status", value: bridge.trainerState.label)
            if bridge.source == .mock {
                VStack(alignment: .leading) {
                    Text("Mock cadence: \(Int(bridge.mockCadence)) rpm")
                    Slider(value: $bridge.mockCadence, in: 0...130, step: 1)
                }
            }
        }
    }

    private var zwiftSection: some View {
        Section {
            LabeledContent("Advertised as", value: BridgeController.advertisedName)
            LabeledContent("Status", value: bridge.zwiftLabel)
        } header: {
            Text("Zwift")
        } footer: {
            Text("In Zwift on the Mac, pair Power, Cadence and Controllable to \(BridgeController.advertisedName). Keep this app open.")
        }
    }

    private var logSection: some View {
        Section("Packet log") {
            LabeledContent("Entries", value: "\(bridge.logCount)")
            Button("Export CSV") {
                do {
                    shareItem = ShareItem(url: try bridge.writeLogFile())
                } catch {
                    exportError = error.localizedDescription
                }
            }
            Button("Clear log", role: .destructive) { bridge.clearLog() }
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

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
