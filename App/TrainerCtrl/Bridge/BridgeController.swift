import Foundation
import Observation
import TrainerCore

enum TrainerSource: String, CaseIterable, Identifiable {
    case mock = "Mock"
    case bluetooth = "Flux S"

    var id: Self { self }
}

/// Wires the trainer link, the virtual trainer Zwift pairs to, `BridgeCore`
/// and the packet log together, and exposes state for the UI.
@MainActor
@Observable
final class BridgeController {
    static let advertisedName = "TrainerCtrl"

    var source: TrainerSource {
        didSet { if source != oldValue { connectTrainer() } }
    }

    var mockCadence: Double = 85 {
        didSet { (link as? MockTrainerLink)?.cadence = mockCadence }
    }

    private(set) var trainerState: TrainerLinkState = .idle
    private(set) var zwiftState: VirtualTrainerPeripheral.State = .starting
    private(set) var zwiftSubscribers = 0
    private(set) var latestData: IndoorBikeData?
    private(set) var zwiftMode: BridgeCore.ZwiftMode = .idle
    private(set) var logCount = 0

    // MARK: Shifting state (for the UI)

    /// Virtual shifting on (strategy A) or off (Zwift's grade passes through unchanged).
    var virtualShifting: Bool {
        didSet {
            guard virtualShifting != oldValue else { return }
            UserDefaults.standard.set(virtualShifting, forKey: Keys.virtualShifting)
            record(.event, "settings", [], "virtualShifting=\(virtualShifting)")
            perform(core.setEngine(virtualShifting ? makeEngine() : nil, at: now))
            refreshShiftState()
        }
    }

    /// Off when Zwift takes power straight from the trainer (e.g. over ANT+),
    /// so TrainerCtrl doesn't compete as a power source.
    var reportsPower: Bool {
        didSet {
            guard reportsPower != oldValue else { return }
            UserDefaults.standard.set(reportsPower, forKey: Keys.reportsPower)
            record(.event, "settings", [], "reportsPower=\(reportsPower)")
            core.reportsPower = reportsPower
            peripheral.feature = BridgeCore.virtualFeature(copying: trainerFeature, reportsPower: reportsPower)
        }
    }

    /// Volume buttons shift gears (only while virtual shifting is on).
    var volumeButtonsShift: Bool {
        didSet {
            guard volumeButtonsShift != oldValue else { return }
            UserDefaults.standard.set(volumeButtonsShift, forKey: Keys.volumeButtonsShift)
            record(.event, "settings", [], "volumeButtonsShift=\(volumeButtonsShift)")
        }
    }

    private(set) var gearNumber: Int?
    private(set) var gearCount = 0
    private(set) var gearRatio: Double?
    private(set) var trainerGrade: Double?
    private(set) var limit: TrainerCommand.Limit = .none
    /// Bumped on every shift attempt so the UI can animate.
    private(set) var lastShift: ShiftEvent?

    struct ShiftEvent: Equatable {
        let outcome: BridgeCore.ShiftOutcome
        let serial: Int
    }

    let profile = GearProfile.standard
    let rider = RiderSetup()

    @ObservationIgnored private var core = BridgeCore()
    @ObservationIgnored private var log = PacketLog()
    @ObservationIgnored private let peripheral = VirtualTrainerPeripheral(name: BridgeController.advertisedName)
    @ObservationIgnored private var link: TrainerLink?
    @ObservationIgnored private var logStart = Date()
    @ObservationIgnored private var trainerFeature: FitnessMachineFeature?
    @ObservationIgnored private let haptics = ShiftHaptics()
    @ObservationIgnored private let clockStart = ContinuousClock.now

    private enum Keys {
        static let virtualShifting = "virtualShifting"
        static let reportsPower = "reportsPower"
        static let volumeButtonsShift = "volumeButtonsShift"
    }

    /// Monotonic seconds since launch, the bridge's clock.
    private var now: TimeInterval {
        let d = ContinuousClock.now - clockStart
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    init(source: TrainerSource = .mock) {
        self.source = source
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.virtualShifting: true,
            Keys.reportsPower: true,
            Keys.volumeButtonsShift: true,
        ])
        virtualShifting = defaults.bool(forKey: Keys.virtualShifting)
        reportsPower = defaults.bool(forKey: Keys.reportsPower)
        volumeButtonsShift = defaults.bool(forKey: Keys.volumeButtonsShift)
        core.reportsPower = reportsPower
        peripheral.feature = BridgeCore.virtualFeature(copying: nil, reportsPower: reportsPower)
        if virtualShifting { _ = core.setEngine(makeEngine()) }
        peripheral.onControlPointWrite = { [weak self] bytes in self?.handleZwiftWrite(bytes) }
        peripheral.onChange = { [weak self] in
            guard let self else { return }
            self.zwiftState = self.peripheral.state
            self.zwiftSubscribers = self.peripheral.subscriberCount
        }
        peripheral.start()
        connectTrainer()
        refreshShiftState()
    }

    // MARK: Shifting

    func shift(_ direction: Gearbox.Direction) {
        let (outcome, outputs) = core.shift(direction, at: now)
        lastShift = ShiftEvent(outcome: outcome, serial: (lastShift?.serial ?? 0) + 1)
        switch outcome {
        case .shifted(let index):
            haptics.shifted()
            record(.event, "shift", [], String(format: "%@ to gear %d (ratio %.2f)",
                                               direction == .up ? "up" : "down", index + 1, profile.ratios[index]))
        case .atLimit:
            haptics.blocked()
            record(.event, "shift", [], "\(direction == .up ? "up" : "down") ignored: at limit")
        case .ignoredInERG, .disabled:
            haptics.blocked()
        }
        perform(outputs)
        refreshShiftState()
    }

    private func makeEngine() -> ShiftingEngine {
        .gradeOffset(profile: profile, rider: rider)
    }

    private func refreshShiftState() {
        if let engine = core.engine {
            gearNumber = engine.gearbox.gearNumber
            gearCount = engine.gearbox.profile.gearCount
            gearRatio = engine.gearbox.targetRatio
        } else {
            gearNumber = nil
            gearCount = 0
            gearRatio = nil
        }
        let command = core.lastEngineCommand
        trainerGrade = command?.parameters.grade
        limit = command?.limit ?? .none
    }

    // MARK: Labels

    var zwiftLabel: String {
        switch zwiftState {
        case .starting: "Starting…"
        case .unavailable(let reason), .failed(let reason): reason
        case .advertising: zwiftSubscribers > 0 ? "Zwift connected" : "Waiting for Zwift to pair"
        }
    }

    var commandLabel: String {
        switch zwiftMode {
        case .idle: "None yet"
        case .simulation(let p): String(format: "Sim %.1f%%  Crr %.4f  Cw %.2f", p.grade * 100, p.crr, p.cw)
        case .targetPower(let w): "ERG \(w) W"
        }
    }

    // MARK: Packet log

    func writeLogFile() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trainerctrl-\(formatter.string(from: logStart)).csv")
        try log.csv().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func clearLog() {
        log.clear()
        logStart = Date()
        logCount = 0
    }

    private func record(_ direction: PacketLog.Direction, _ channel: String, _ bytes: [UInt8] = [], _ summary: String = "") {
        log.append(at: Date().timeIntervalSince(logStart), direction, channel, bytes: bytes, summary: summary)
        logCount = log.entries.count
    }

    // MARK: Trainer side

    private func connectTrainer() {
        link?.onEvent = nil
        link?.stop()
        core.trainerDidDisconnect()
        latestData = nil

        let newLink: TrainerLink
        switch source {
        case .mock:
            let mock = MockTrainerLink()
            mock.cadence = mockCadence
            newLink = mock
        case .bluetooth:
            newLink = FTMSTrainerLink()
        }
        newLink.onEvent = { [weak self] event in self?.handle(event) }
        link = newLink
        record(.event, "source", [], source.rawValue)
        newLink.start()
    }

    private func handle(_ event: TrainerLinkEvent) {
        switch event {
        case .state(let state):
            trainerState = state
            if !state.isConnected { core.trainerDidDisconnect() }
            record(.event, "trainerState", [], state.label)
        case .ready:
            perform(core.trainerDidConnect())
        case .data(let data, let raw):
            latestData = data
            record(.fromTrainer, FTMSUUID.indoorBikeData, raw, data.logSummary)
            perform(core.handleTrainerData(data, at: now))
            refreshShiftState()
        case .response(let response, let raw):
            record(.fromTrainer, FTMSUUID.controlPoint, raw, response.logSummary)
            perform(core.handleTrainerResponse(response, at: now))
        case .status(let status, let raw):
            record(.fromTrainer, FTMSUUID.status, raw, status.logSummary)
            perform(core.handleTrainerStatus(status))
        case .feature(let feature, let raw):
            record(.fromTrainer, FTMSUUID.feature, raw, "feature")
            trainerFeature = feature
            peripheral.feature = BridgeCore.virtualFeature(copying: feature, reportsPower: reportsPower)
        case .powerRange(let range, let raw):
            record(.fromTrainer, FTMSUUID.supportedPowerRange, raw, "\(range.minimum)–\(range.maximum) W")
            peripheral.powerRange = range
        case .sent(let request, let raw):
            record(.toTrainer, FTMSUUID.controlPoint, raw, request.logSummary)
        case .decodeError(let channel, let raw, let message):
            record(.fromTrainer, channel, raw, "decode error: \(message)")
        }
    }

    // MARK: Zwift side

    private func handleZwiftWrite(_ bytes: [UInt8]) {
        let summary = (try? ControlPointRequest(bytes: bytes))?.logSummary ?? "malformed"
        record(.fromZwift, FTMSUUID.controlPoint, bytes, summary)
        perform(core.handleZwiftWrite(bytes, at: now))
        zwiftMode = core.zwiftMode
        refreshShiftState()
    }

    private func perform(_ outputs: [BridgeCore.Output]) {
        for output in outputs {
            switch output {
            case .respondToZwift(let response):
                peripheral.indicate(response)
                record(.toZwift, FTMSUUID.controlPoint, response.encoded(), response.logSummary)
            case .notifyZwiftStatus(let status):
                peripheral.notify(status)
                record(.toZwift, FTMSUUID.status, status.encoded(), status.logSummary)
            case .notifyZwiftData(let data):
                // Not logged: identical to the trainer packet already logged.
                peripheral.notify(data)
            case .sendToTrainer(let request):
                link?.send(request)
            }
        }
    }
}
