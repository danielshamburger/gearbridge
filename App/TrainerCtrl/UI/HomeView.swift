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
                VStack(spacing: 12) {
                    appIcon
                    Text("TrainerCtrl").font(.largeTitle.bold())
                }
                summary
                if let note = bridge.autoEndNote {
                    Label(note, systemImage: "moon.zzz")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                bridgeBackdrop
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .sheet(isPresented: $showingSettings) { SettingsView(bridge: bridge) }
        }
    }

    /// The Mackinac Bridge, faint, filling the space between the setup card and
    /// the buttons (so it never sits behind either, whatever the phone size).
    /// Wider than the screen so the towers sit near the edges and the
    /// approaches run off both sides.
    private var bridgeBackdrop: some View {
        GeometryReader { geo in
            let height = min(geo.size.height - 8, 150)
            if height > 60 {
                SuspensionBridgeArt()
                    .frame(width: (geo.size.width + 48) * 1.65, height: height)
                    .position(x: geo.size.width / 2, y: geo.size.height - height / 2)
            }
        }
        .frame(maxHeight: .infinity)
        .opacity(0.16)
        .allowsHitTesting(false)
    }

    /// The app icon, as on the home screen of the phone.
    private var appIcon: some View {
        let size: CGFloat = 96
        return Image("AppIconImage")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .accessibilityHidden(true)
    }

    /// The current setup, styled like a Settings list; tap to change it in Settings.
    private var summary: some View {
        Button {
            showingSettings = true
        } label: {
            VStack(spacing: 0) {
                let rows = summaryRows
                ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                    SummaryRow(item: item)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 16 + 29 + 12) // in line with the labels
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }

    private var summaryRows: [SummaryRow.Item] {
        var rows: [SummaryRow.Item] = [
            .init(symbol: "figure.indoor.cycle", color: .orange, label: "Trainer", value: bridge.source.rawValue,
                  hint: bridge.source == .bluetooth
                      ? readiness(bridge.lastTrainerConnection, "Connected", never: "Not connected yet") : nil),
            .init(symbol: "display", color: .blue, label: "Zwift",
                  value: bridge.lastZwiftConnection == nil ? "Not paired" : "Paired",
                  hint: bridge.lastZwiftConnection == nil ? nil : readiness(bridge.lastZwiftConnection, "Last connected", never: "")),
            .init(symbol: "gearshape.2.fill", color: .green, label: "Gears",
                  value: bridge.virtualShifting ? bridge.profile.name : "Off", hint: nil),
        ]
        if bridge.virtualShifting {
            rows.append(.init(symbol: "slider.horizontal.3", color: .purple, label: "Shifting",
                              value: bridge.activeModel.rawValue, hint: nil))
        }
        rows.append(.init(symbol: "link", color: .gray, label: "Real gear",
                          value: "\(bridge.rider.realChainring)×\(bridge.rider.realCog)", hint: nil))
        return rows
    }

    /// "Connected today", "Connected yesterday", "Connected 3 days ago", or a date.
    private func readiness(_ date: Date?, _ verb: String, never: String) -> String {
        guard let date else { return never }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: .now)).day ?? 0
        switch days {
        case ..<1: return "\(verb) today"
        case 1: return "\(verb) yesterday"
        case 2..<7: return "\(verb) \(days) days ago"
        default: return "\(verb) \(date.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }
}

/// One row of the home screen's setup card: coloured icon tile, label (with an
/// optional hint under it), value on the right, chevron.
private struct SummaryRow: View {
    struct Item {
        let symbol: String
        let color: Color
        let label: String
        let value: String
        let hint: String?
    }

    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                if let hint = item.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(item.value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, item.hint == nil ? 11 : 7)
        .frame(minHeight: 52)
    }
}
