import SwiftUI
import TrainerCore
import UIKit

/// The categories in Settings, each its own page. The home screen's setup
/// card opens Settings straight to one of them.
enum SettingsPage: String, Hashable, CaseIterable, Identifiable {
    case trainer, zwift, gears, shifting, display, diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .trainer: "Trainer"
        case .zwift: "Zwift"
        case .gears: "Gears"
        case .shifting: "Shifting"
        case .display: "Display"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .trainer: "figure.indoor.cycle"
        case .zwift: "display"
        case .gears: "gearshape.2.fill"
        case .shifting: "slider.horizontal.3"
        case .display: "textformat.size"
        case .diagnostics: "stethoscope"
        }
    }

    var color: Color {
        switch self {
        case .trainer: .orange
        case .zwift: .blue
        case .gears: .green
        case .shifting: .purple
        case .display: .indigo
        case .diagnostics: .red
        }
    }
}

/// A Settings-style icon tile: white symbol on a coloured rounded square.
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    init(symbol: String, color: Color) {
        self.symbol = symbol
        self.color = color
    }

    init(page: SettingsPage) {
        self.init(symbol: page.symbol, color: page.color)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Settings as a sheet (from the ride screen): the category list, with Done.
struct SettingsView: View {
    @Bindable var bridge: BridgeController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsList(bridge: bridge)
                .navigationDestination(for: SettingsPage.self) { page in
                    SettingsDestination(page: page, bridge: bridge)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Everything that's set up once rather than touched while riding: a list of
/// categories, each opening its own page. Pushed from the home screen, or the
/// root of `SettingsView`. The enclosing stack registers `SettingsPage`.
struct SettingsList: View {
    @Bindable var bridge: BridgeController

    var body: some View {
        List {
            Section {
                row(.trainer, value: "\(bridge.trainerName) · \(bridge.rider.realChainring)×\(bridge.rider.realCog)")
                row(.zwift, value: bridge.reportsPower ? nil : "Power off")
            }
            Section {
                row(.gears, value: bridge.virtualShifting ? bridge.profile.name : "Off")
                row(.shifting, value: bridge.virtualShifting ? bridge.activeModel.rawValue : "Off")
            }
            Section {
                row(.display, value: bridge.speedUnit.label)
                row(.diagnostics, value: bridge.debugMode ? "Debug on" : nil)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ page: SettingsPage, value: String?) -> some View {
        NavigationLink(value: page) {
            HStack(spacing: 12) {
                SettingsIcon(page: page)
                Text(page.title)
                Spacer(minLength: 8)
                if let value {
                    Text(value).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// The page for one Settings category.
struct SettingsDestination: View {
    let page: SettingsPage
    @Bindable var bridge: BridgeController

    var body: some View {
        switch page {
        case .trainer: TrainerSettings(bridge: bridge)
        case .zwift: ZwiftSettings(bridge: bridge)
        case .gears: GearProfileView(bridge: bridge)
        case .shifting: ShiftingSettings(bridge: bridge)
        case .display: DisplaySettings(bridge: bridge)
        case .diagnostics: DiagnosticsSettings(bridge: bridge)
        }
    }
}

// MARK: Pages

private struct TrainerSettings: View {
    @Bindable var bridge: BridgeController

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: $bridge.source) {
                    ForEach(TrainerSource.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                if bridge.source == .bluetooth {
                    NavigationLink {
                        TrainerPicker(bridge: bridge)
                    } label: {
                        LabeledContent("Trainer", value: bridge.trainerBluetoothName ?? "First one found")
                    }
                }
                LabeledContent("Status", value: bridge.isRiding ? bridge.trainerState.label : "Connects when you start a ride")
                if let last = bridge.lastTrainerConnection {
                    LabeledContent("Last connected", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                Text("Bluetooth connects to your smart trainer: the one you choose, or the first one it finds, which it then remembers. Simulate is a pretend trainer for trying the app without the bike. Choosing it turns on debug mode; switching back turns it off.")
            }
            Section {
                Stepper(value: $bridge.rider.realChainring, in: 20...60) {
                    LabeledContent("Chainring", value: "\(bridge.rider.realChainring)T")
                }
                Stepper(value: $bridge.rider.realCog, in: 9...40) {
                    LabeledContent("Cog", value: "\(bridge.rider.realCog)T")
                }
            } header: {
                Text("Real gear")
            } footer: {
                Text("The chainring and cog your chain sits in on the trainer. Leave it there while riding: the app needs it to know which virtual gear you're in.")
            }
        }
        .navigationTitle("Trainer")
    }
}

private struct ZwiftSettings: View {
    @Bindable var bridge: BridgeController

    var body: some View {
        Form {
            Section {
                LabeledContent("Advertised as", value: BridgeController.advertisedName)
                LabeledContent("Status", value: bridge.zwiftLabel)
                if let last = bridge.lastZwiftConnection {
                    LabeledContent("Last connected", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                Toggle("Send power to Zwift", isOn: $bridge.reportsPower)
            } footer: {
                Text("In Zwift on the Mac, pair Controllable (and Cadence) to \(BridgeController.advertisedName), plus Power unless Zwift takes power directly from the trainer over ANT+. Events that require a power meter need the ANT+ setup: turn off \"Send power to Zwift\", then re-pair.")
            }
        }
        .navigationTitle("Zwift")
    }
}

private struct ShiftingSettings: View {
    @Bindable var bridge: BridgeController
    @State private var showingCalibration = false

    var body: some View {
        Form {
            Section {
                Toggle("Virtual shifting", isOn: $bridge.virtualShifting)
                Toggle("Shift with volume buttons", isOn: $bridge.volumeButtonsShift)
                    .disabled(!bridge.virtualShifting)
            } footer: {
                Text("With virtual shifting off, Zwift's grade goes to the trainer unchanged. Volume buttons: up is a harder gear, down is easier. Turned off, they change the volume as usual.")
            }
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
        .navigationTitle("Shifting")
        .sheet(isPresented: $showingCalibration) { CalibrationView(bridge: bridge) }
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
}

private struct DisplaySettings: View {
    @Bindable var bridge: BridgeController

    var body: some View {
        Form {
            Section {
                Picker("Units", selection: $bridge.speedUnit) {
                    ForEach(SpeedUnit.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Units")
            }
        }
        .navigationTitle("Display")
    }
}

private struct DiagnosticsSettings: View {
    @Bindable var bridge: BridgeController
    @State private var shareItem: ShareItem?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Debug mode", isOn: $bridge.debugMode)
            } footer: {
                Text("Debug mode shows Zwift's command and the trainer grade while riding, and logs every trainer reading. Off, the log keeps commands, responses and events only.")
            }
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
        .navigationTitle("Diagnostics")
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
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

/// Settings → Trainer → Trainer: the smart trainers in range, to pick which one
/// rides connect to, and the remembered one, to forget it.
private struct TrainerPicker: View {
    @Bindable var bridge: BridgeController
    @State private var scanner = TrainerScanner()
    @State private var savedID = FTMSTrainerLink.savedID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let name = bridge.trainerBluetoothName ?? (bridge.hasSavedTrainer ? "Saved trainer" : nil) {
                Section {
                    LabeledContent(name) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                    Button("Forget trainer", role: .destructive) {
                        bridge.forgetTrainer()
                        savedID = nil
                    }
                } header: {
                    Text("Rides connect to")
                } footer: {
                    Text("Forget it and the next ride connects to the first trainer it finds.")
                }
            }
            Section {
                if let problem = scanner.problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if others.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for trainers…").foregroundStyle(.secondary)
                    }
                }
                ForEach(others) { trainer in
                    Button {
                        bridge.chooseTrainer(id: trainer.id, name: trainer.name)
                        dismiss()
                    } label: {
                        HStack {
                            Text(trainer.name).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "cellularbars", variableValue: signal(trainer.rssi))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Signal \(Int(signal(trainer.rssi) * 100))%")
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Nearby")
                    if scanner.problem == nil && !others.isEmpty { ProgressView().controlSize(.mini) }
                }
            } footer: {
                Text("Turn the trainer on and pedal to wake it. A trainer that's already connected to something, like Zwift or this app mid-ride, doesn't show up here. Closest first.")
            }
        }
        .navigationTitle("Choose trainer")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: scanner.trainers.map(\.id))
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    /// The trainers in range, less the one already chosen.
    private var others: [TrainerScanner.Found] {
        scanner.trainers.filter { $0.id != savedID }
    }

    /// Signal strength as 0…1 for the bars: about −95 dBm (barely there) to −50 (next to it).
    private func signal(_ rssi: Int) -> Double {
        min(1, max(0, Double(rssi + 95) / 45))
    }
}
