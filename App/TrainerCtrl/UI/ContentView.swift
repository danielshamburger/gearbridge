import SwiftUI
import TrainerCore
import UIKit

struct ContentView: View {
    @State private var bridge = BridgeController()
    @State private var shareItem: ShareItem?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            List {
                liveSection
                trainerSection
                zwiftSection
                logSection
            }
            .navigationTitle("TrainerCtrl")
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var liveSection: some View {
        Section {
            HStack {
                Readout(title: "Power", value: bridge.latestData?.instantaneousPower.map { "\($0)" }, unit: "W")
                Readout(title: "Cadence", value: bridge.latestData?.instantaneousCadence.map { String(format: "%.0f", $0) }, unit: "rpm")
                Readout(title: "Speed", value: bridge.latestData?.instantaneousSpeed.map { String(format: "%.1f", $0) }, unit: "km/h")
            }
            .padding(.vertical, 4)
            LabeledContent("Zwift command", value: bridge.commandLabel)
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
