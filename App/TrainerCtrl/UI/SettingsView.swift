import SwiftUI
import TrainerCore
import UIKit

/// Everything that's set up once rather than touched while riding.
struct SettingsView: View {
    @Bindable var bridge: BridgeController
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    @State private var showingCalibration = false

    var body: some View {
        NavigationStack {
            Form {
                shiftingSection
                bikeSection
                calibrationSection
                displaySection
                trainerSection
                zwiftSection
                logSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
            .sheet(isPresented: $showingCalibration) { CalibrationView(bridge: bridge) }
            .alert("Export failed", isPresented: .constant(exportError != nil)) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    private var shiftingSection: some View {
        Section {
            Toggle("Virtual shifting", isOn: $bridge.virtualShifting)
            Toggle("Shift with volume buttons", isOn: $bridge.volumeButtonsShift)
                .disabled(!bridge.virtualShifting)
            NavigationLink {
                GearProfileView(bridge: bridge)
            } label: {
                LabeledContent("Gears", value: bridge.profile.name)
            }
        } header: {
            Text("Shifting")
        } footer: {
            Text("With virtual shifting off, Zwift's grade goes to the trainer unchanged. Volume buttons: up is a harder gear, down is easier. Turned off, they change the volume as usual.")
        }
    }

    private var bikeSection: some View {
        Section {
            Stepper(value: $bridge.rider.realChainring, in: 20...60) {
                LabeledContent("Chainring", value: "\(bridge.rider.realChainring)T")
            }
            Stepper(value: $bridge.rider.realCog, in: 9...40) {
                LabeledContent("Cog", value: "\(bridge.rider.realCog)T")
            }
        } header: {
            Text("Real gear on the trainer")
        } footer: {
            Text("The chainring and cog your chain sits in. Leave it there while riding: the app needs it to know which virtual gear you're in.")
        }
    }

    private var calibrationSection: some View {
        Section {
            Picker("Shifting model", selection: $bridge.shiftingModel) {
                ForEach(ShiftingModel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(bridge.usableCalibration == nil && bridge.shiftingModel == .simple)
            if bridge.activeModel == .simple {
                Stepper(value: $bridge.gradePerGear, in: 0.0025...0.03, step: 0.0025) {
                    LabeledContent("Grade per gear", value: (bridge.gradePerGear * 100).formatted(.number.precision(.fractionLength(0...2))) + "%")
                }
            }
            if let saved = bridge.savedCalibration {
                LabeledContent("Calibrated", value: saved.date.formatted(date: .abbreviated, time: .shortened))
                CalibrationSummary(calibration: saved.calibration, maxGradeMeasured: saved.maxGradeMeasured)
            }
            Button(bridge.savedCalibration == nil ? "Calibrate trainer…" : "Recalibrate…") {
                showingCalibration = true
            }
        } header: {
            Text("Shifting model")
        } footer: {
            Text(modelFooter)
        }
    }

    private var modelFooter: String {
        if let cal = bridge.savedCalibration?.calibration, cal.realCog != bridge.rider.realCog {
            return "The saved calibration was measured in a \(cal.realCog.map(String.init) ?? "?")T cog, not the \(bridge.rider.realCog)T you ride in, so simple shifting is used. Recalibrate."
        }
        if bridge.usableCalibration == nil {
            return "Simple adds 1% grade per gear. Calibrated matches each gear's real effort and needs a trainer calibration first."
        }
        return "Simple adds 1% grade per gear. Calibrated scales the trainer's resistance so power and cadence match the virtual gear."
    }

    private var displaySection: some View {
        Section("Display") {
            Picker("Units", selection: $bridge.speedUnit) {
                ForEach(SpeedUnit.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var trainerSection: some View {
        Section("Trainer") {
            Picker("Source", selection: $bridge.source) {
                ForEach(TrainerSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Status", value: bridge.trainerState.label)
        }
    }

    private var zwiftSection: some View {
        Section {
            LabeledContent("Advertised as", value: BridgeController.advertisedName)
            LabeledContent("Status", value: bridge.zwiftLabel)
            Toggle("Send power to Zwift", isOn: $bridge.reportsPower)
        } header: {
            Text("Zwift")
        } footer: {
            Text("In Zwift on the Mac, pair Controllable (and Cadence) to \(BridgeController.advertisedName), plus Power unless Zwift takes power directly from the trainer over ANT+. Events that require a power meter need the ANT+ setup: turn off \"Send power to Zwift\", then re-pair.")
        }
    }

    private var logSection: some View {
        Section {
            Toggle("Debug mode", isOn: $bridge.debugMode)
            LabeledContent("Log entries", value: "\(bridge.logCount)")
            Button("Export CSV") {
                do {
                    shareItem = ShareItem(url: try bridge.writeLogFile())
                } catch {
                    exportError = error.localizedDescription
                }
            }
            Button("Clear log", role: .destructive) { bridge.clearLog() }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Debug mode shows Zwift's command and the trainer grade while riding, and logs every trainer reading. Off, the log keeps commands, responses and events only.")
        }
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
