import SwiftUI
import TrainerCore

/// Picks or builds the virtual drivetrain and its starting gear.
struct GearProfileView: View {
    @Bindable var bridge: BridgeController

    @State private var chainring = 42
    @State private var smallestCog = 10
    @State private var largestCog = 52
    @State private var cogCount = 12

    static var customID: UUID { GearProfile.customID }

    var body: some View {
        Form {
            presetsSection
            customSection
            startingGearSection
            gearsSection
        }
        .navigationTitle("Gears")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadTeeth)
        .onChange(of: bridge.profile) { loadTeeth() }
    }

    private var presetsSection: some View {
        Section("Presets") {
            ForEach(GearProfile.presets) { preset in
                Button {
                    bridge.profile = preset
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name).foregroundStyle(.primary)
                            Text("\(preset.gearCount) gears").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if bridge.profile.id == preset.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
    }

    private var customSection: some View {
        Section {
            Picker("Chainring", selection: applying($chainring)) {
                ForEach(24...62, id: \.self) { Text("\($0)T").tag($0) }
            }
            Picker("Smallest cog", selection: applying($smallestCog) {
                if largestCog <= smallestCog { largestCog = smallestCog + 1 }
            }) {
                ForEach(10...51, id: \.self) { Text("\($0)T").tag($0) }
            }
            Picker("Largest cog", selection: applying($largestCog) {
                if smallestCog >= largestCog { smallestCog = largestCog - 1 }
            }) {
                ForEach(11...52, id: \.self) { Text("\($0)T").tag($0) }
            }
            Stepper(value: applying($cogCount), in: 2...maxCogCount) {
                LabeledContent("Cogs", value: "\(min(cogCount, maxCogCount))")
            }
            LabeledContent("Cassette", value: customCogs.map(String.init).joined(separator: "-"))
                .font(.footnote)
        } header: {
            HStack {
                Text("Custom")
                Spacer()
                if bridge.profile.id == Self.customID { Image(systemName: "checkmark") }
            }
        } footer: {
            Text("Changes apply straight away, also mid-ride (you restart in the starting gear). Cogs are spaced evenly between the smallest and largest, each step the same percentage harder.")
        }
    }

    /// A binding that applies the custom gears whenever the user changes it.
    /// Only user edits go through here; `loadTeeth` sets the state directly, so
    /// picking a preset doesn't get overwritten by a custom copy of itself.
    private func applying(_ value: Binding<Int>, then adjust: @escaping () -> Void = {}) -> Binding<Int> {
        Binding {
            value.wrappedValue
        } set: { newValue in
            value.wrappedValue = newValue
            adjust()
            applyCustom()
        }
    }

    private var startingGearSection: some View {
        let matching = bridge.profile.closestGearIndex(toRatio: bridge.rider.realRatio)
        return Section {
            Picker("Start in", selection: startingGear) {
                Text("Gear \(matching + 1), matches your real gear").tag(Int?.none)
                ForEach(0..<bridge.profile.gearCount, id: \.self) { index in
                    Text("Gear \(index + 1)\(gearSuffix(index))").tag(Int?.some(index))
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Starting gear")
        } footer: {
            Text("In the gear that matches your real one, Zwift's grade reaches the trainer unchanged.")
        }
    }

    private var gearsSection: some View {
        let matching = bridge.profile.closestGearIndex(toRatio: bridge.rider.realRatio)
        return Section("\(bridge.profile.gearCount) gears, easiest first") {
            ForEach(0..<bridge.profile.gearCount, id: \.self) { index in
                LabeledContent {
                    Text(String(format: "%.2f", bridge.profile.ratios[index])).monospacedDigit()
                } label: {
                    HStack {
                        Text("\(index + 1)").monospacedDigit().frame(minWidth: 24, alignment: .leading)
                        Text(bridge.profile.label(ofGear: index) ?? "")
                        if index == matching {
                            Text("real gear").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var startingGear: Binding<Int?> {
        Binding {
            bridge.profile.startingGearIndex
        } set: { index in
            if let updated = try? bridge.profile.withStartingGear(index) { bridge.profile = updated }
        }
    }

    private func gearSuffix(_ index: Int) -> String {
        bridge.profile.label(ofGear: index).map { " · \($0)" } ?? String(format: " · %.2f", bridge.profile.ratios[index])
    }

    private var maxCogCount: Int { max(largestCog - smallestCog + 1, 2) }

    private var customCogs: [Int] {
        Drivetrain.cassette(smallest: smallestCog, largest: largestCog, count: cogCount)
    }

    /// Fills the custom fields from the current profile.
    private func loadTeeth() {
        guard let drivetrain = bridge.profile.drivetrain,
              let lo = drivetrain.cogs.min(), let hi = drivetrain.cogs.max(), lo < hi
        else { return }
        chainring = min(max(drivetrain.chainring, 24), 62)
        smallestCog = min(max(lo, 10), 51)
        largestCog = min(max(hi, smallestCog + 1), 52)
        cogCount = drivetrain.cogs.count
    }

    private func applyCustom() {
        if let profile = try? GearProfile.custom(
            chainring: chainring,
            smallestCog: smallestCog,
            largestCog: largestCog,
            cogCount: cogCount,
            wheelCircumference: bridge.profile.wheelCircumference
        ) {
            bridge.profile = profile
        }
    }
}
