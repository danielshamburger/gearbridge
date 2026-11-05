import SwiftUI
import TrainerCore

/// Picks or builds the virtual drivetrain and its starting gear.
struct GearProfileView: View {
    @Bindable var bridge: BridgeController

    @State private var chainringsText = ""
    @State private var cogsText = ""
    @State private var customError: String?

    /// Custom profiles reuse one id so re-editing replaces the previous one.
    static let customID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!

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
            LabeledContent("Chainrings") {
                TextField("50, 34", text: $chainringsText)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
            }
            LabeledContent("Cassette") {
                TextField("11-12-13-…-28", text: $cogsText)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
            }
            Button("Use these gears", action: applyCustom)
                .disabled(teeth(chainringsText).isEmpty || teeth(cogsText).isEmpty)
            if let customError {
                Text(customError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Custom")
                Spacer()
                if bridge.profile.id == Self.customID { Image(systemName: "checkmark") }
            }
        } footer: {
            Text("Teeth separated by commas, spaces or dashes. With two chainrings, all combinations make one list of gears, easiest first, and gears less than 3% apart are merged.")
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

    private func teeth(_ text: String) -> [Int] {
        text.split { !$0.isNumber }.compactMap { Int($0) }
    }

    private func loadTeeth() {
        guard let drivetrain = bridge.profile.drivetrain else { return }
        chainringsText = drivetrain.chainrings.map(String.init).joined(separator: ", ")
        cogsText = drivetrain.cogs.sorted().map(String.init).joined(separator: "-")
    }

    private func applyCustom() {
        let rings = Array(Set(teeth(chainringsText))).sorted(by: >)
        let cogs = Array(Set(teeth(cogsText))).sorted()
        guard rings.allSatisfy({ (20...60).contains($0) }) else {
            customError = "Chainrings should be 20–60 teeth."
            return
        }
        guard cogs.allSatisfy({ (9...60).contains($0) }) else {
            customError = "Cogs should be 9–60 teeth."
            return
        }
        guard rings.count <= 3 else {
            customError = "At most three chainrings."
            return
        }
        let name = rings.count == 1
            ? "1× \(rings[0])T, \(cogs.first!)–\(cogs.last!)"
            : "\(rings.count)× \(rings.map(String.init).joined(separator: "/")), \(cogs.first!)–\(cogs.last!)"
        do {
            bridge.profile = try GearProfile(
                id: Self.customID,
                name: name,
                drivetrain: Drivetrain(chainrings: rings, cogs: cogs),
                wheelCircumference: bridge.profile.wheelCircumference
            )
            customError = nil
        } catch {
            customError = "Those teeth don't make a usable set of gears."
        }
    }
}
