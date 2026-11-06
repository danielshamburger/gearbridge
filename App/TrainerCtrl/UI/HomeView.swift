import SwiftUI
import TrainerCore

/// The opening screen. Nothing connects or records until a ride starts.
struct HomeView: View {
    @Bindable var bridge: BridgeController
    /// Settings pages are pushed onto the home screen's own stack, so Back (or
    /// a swipe) from a page opened here returns home.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
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
                        path.append(HomeRoute.settings)
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
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("Home")
            .navigationDestination(for: HomeRoute.self) { _ in SettingsList(bridge: bridge) }
            .navigationDestination(for: SettingsPage.self) { page in
                SettingsDestination(page: page, bridge: bridge)
            }
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

    /// The current setup, styled like a Settings list. Each row opens Settings
    /// on its own page.
    private var summary: some View {
        VStack(spacing: 0) {
            let rows = summaryRows
            ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                Button {
                    path.append(item.page)
                } label: {
                    SummaryRow(item: item)
                }
                .buttonStyle(SummaryRowStyle())
                .accessibilityHint("Opens \(item.page.title) settings")
                if index < rows.count - 1 {
                    Divider().padding(.leading, 16 + 29 + 12) // in line with the labels
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var summaryRows: [SummaryRow.Item] {
        var rows: [SummaryRow.Item] = [
            .init(page: .trainer, value: bridge.source.rawValue,
                  hint: bridge.source == .bluetooth
                      ? readiness(bridge.lastTrainerConnection, "Connected", never: "Not connected yet") : nil),
            .init(page: .zwift, value: bridge.lastZwiftConnection == nil ? "Not paired" : "Paired",
                  hint: bridge.lastZwiftConnection == nil ? nil : readiness(bridge.lastZwiftConnection, "Last connected", never: "")),
            .init(page: .gears, value: bridge.virtualShifting ? bridge.profile.name : "Off", hint: nil),
        ]
        if bridge.virtualShifting {
            rows.append(.init(page: .shifting, value: bridge.activeModel.rawValue, hint: nil))
        }
        rows.append(.init(page: .trainer, title: "Real gear", symbol: "link", color: .gray, value: "\(bridge.rider.realChainring)×\(bridge.rider.realCog)", hint: nil))
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

/// The Settings category list, pushed from the home screen's Settings button.
private enum HomeRoute: Hashable {
    case settings
}

/// Grey highlight while a row is pressed, like a List row.
private struct SummaryRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemGray4) : .clear)
            .contentShape(Rectangle())
    }
}

/// One row of the home screen's setup card: the Settings icon tile, label
/// (with an optional hint under it), value on the right, chevron.
private struct SummaryRow: View {
    struct Item {
        let page: SettingsPage
        /// Defaults to the page's own title and icon.
        var title: String? = nil
        var symbol: String? = nil
        var color: Color? = nil
        let value: String
        let hint: String?
    }

    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: item.symbol ?? item.page.symbol, color: item.color ?? item.page.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? item.page.title)
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
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, item.hint == nil ? 11 : 7)
        .frame(minHeight: 52)
    }
}
