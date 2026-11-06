import Foundation
import Observation
import TrainerCore

/// How gears change the trainer's resistance.
enum ShiftingModel: String, CaseIterable, Identifiable {
    /// Strategy A: a fixed grade per gear. Works without calibration.
    case simple = "Simple"
    /// Strategy C: force scaling from a saved calibration.
    case calibrated = "Calibrated"

    var id: Self { self }
}

/// A calibration kept between launches.
struct SavedCalibration: Codable, Equatable {
    var calibration: TrainerCalibration
    var date: Date
    var maxGradeMeasured: Bool
}

enum TrainerSource: String, CaseIterable, Identifiable {
    case bluetooth = "Flux S"
    case mock = "Mock" // the stored value; shown as "Simulate"

    var id: Self { self }

    /// What the app calls it.
    var name: String {
        switch self {
        case .bluetooth: "Flux S"
        case .mock: "Simulate"
        }
    }
}

/// Wires the trainer link, the virtual trainer Zwift pairs to, `BridgeCore`
/// and the packet log together, and exposes state for the UI.
@MainActor
@Observable
final class BridgeController {
    static let advertisedName = "TrainerCtrl"

    /// Which trainer a ride connects to. Saved; the real trainer by default.
    var source: TrainerSource {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source.rawValue, forKey: Keys.source)
            if isRiding { connectTrainer() }
        }
    }

    var mockCadence: Double = 0 {
        didSet { (link as? MockTrainerLink)?.cadence = mockCadence }
    }

    /// A ride is on: trainer connected, Zwift advertised to, packets logged.
    private(set) var isRiding = false
    private(set) var trainerState: TrainerLinkState = .idle
    private(set) var zwiftState: VirtualTrainerPeripheral.State = .starting
    private(set) var zwiftSubscribers = 0
    /// When the real trainer and Zwift last connected, for the home screen's
    /// "ready" hints. Saved across launches.
    private(set) var lastTrainerConnection: Date? {
        didSet { UserDefaults.standard.set(lastTrainerConnection, forKey: Keys.lastTrainerConnection) }
    }
    private(set) var lastZwiftConnection: Date? {
        didSet { UserDefaults.standard.set(lastZwiftConnection, forKey: Keys.lastZwiftConnection) }
    }
    private(set) var latestData: IndoorBikeData?
    private(set) var zwiftMode: BridgeCore.ZwiftMode = .idle
    private(set) var logCount = 0
    /// Set when the bridge stopped following Zwift on its own (see `BridgeCore.Fallback`).
    private(set) var fallback: BridgeCore.Fallback = .none
    /// Trainer data is stale and Zwift is being sent zeros.
    private(set) var sendingZeros = false

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

    /// How speeds are shown (km/h or mph). Display only.
    var speedUnit: SpeedUnit {
        didSet {
            guard speedUnit != oldValue else { return }
            UserDefaults.standard.set(speedUnit.rawValue, forKey: Keys.speedUnit)
        }
    }

    /// Shows the bridge's internals on the ride screen and logs every trainer
    /// data packet. Off, the log keeps commands, responses and events only.
    var debugMode: Bool {
        didSet {
            guard debugMode != oldValue else { return }
            UserDefaults.standard.set(debugMode, forKey: Keys.debugMode)
            record(.event, "settings", [], "debugMode=\(debugMode)")
        }
    }

    /// Preferred model; `activeModel` falls back to simple without a usable calibration.
    var shiftingModel: ShiftingModel {
        didSet {
            guard shiftingModel != oldValue else { return }
            UserDefaults.standard.set(shiftingModel.rawValue, forKey: Keys.shiftingModel)
            record(.event, "settings", [], "shiftingModel=\(shiftingModel.rawValue)")
            rebuildEngine()
        }
    }

    /// The virtual drivetrain. Changing it starts again in its starting gear.
    var profile: GearProfile {
        didSet {
            guard profile != oldValue else { return }
            save(profile, forKey: Keys.gearProfile)
            record(.event, "settings", [], "profile=\(profile.name) (\(profile.gearCount) gears)")
            resetEngine()
        }
    }

    /// The real bike on the trainer. Changing it starts again in the starting gear.
    var rider: RiderSetup {
        didSet {
            guard rider != oldValue else { return }
            save(rider, forKey: Keys.rider)
            record(.event, "settings", [], "real gear=\(rider.realChainring)x\(rider.realCog)")
            (link as? MockTrainerLink)?.realGear = (rider.realChainring, rider.realCog)
            resetEngine()
        }
    }

    /// Simple model: grade added per gear, as a fraction.
    var gradePerGear: Double {
        didSet {
            guard gradePerGear != oldValue else { return }
            UserDefaults.standard.set(gradePerGear, forKey: Keys.gradePerGear)
            record(.event, "settings", [], String(format: "gradePerGear=%.4f", gradePerGear))
            rebuildEngine()
        }
    }

    private(set) var savedCalibration: SavedCalibration?

    /// Gauge ranges: grow to the highest power and speed held this ride.
    private(set) var powerGauge = PeakGaugeScale.power
    private(set) var speedGauge = PeakGaugeScale.speed

    /// The calibration routine, while it runs and until its result is saved or discarded.
    private(set) var calibrationRun: CalibrationRun?
    /// The bridge clock at the last calibration update, for progress bars.
    private(set) var calibrationTime: TimeInterval = 0
    /// Highest power a calibration step asks for, W.
    var calibrationPowerCap: Double = CalibrationPlan().powerCap
    /// With the mock trainer, set its cadence to each step's target automatically.
    var mockFollowsCalibration = true

    private(set) var gearNumber: Int?
    private(set) var gearCount = 0
    private(set) var gearRatio: Double?
    /// "42×18" when the profile has teeth.
    private(set) var gearLabel: String?
    private(set) var trainerGrade: Double?
    private(set) var limit: TrainerCommand.Limit = .none
    /// Bumped on every shift attempt so the UI can animate.
    private(set) var lastShift: ShiftEvent?

    struct ShiftEvent: Equatable {
        let outcome: BridgeCore.ShiftOutcome
        let serial: Int
    }

    @ObservationIgnored private var core = BridgeCore()
    @ObservationIgnored private var log = PacketLog()
    @ObservationIgnored private let peripheral = VirtualTrainerPeripheral(name: BridgeController.advertisedName)
    @ObservationIgnored private var link: TrainerLink?
    @ObservationIgnored private var logStart = Date()
    @ObservationIgnored private var trainerFeature: FitnessMachineFeature?
    @ObservationIgnored private let haptics = ShiftHaptics()
    @ObservationIgnored private let clockStart = ContinuousClock.now
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundGuard = BackgroundRideGuard()
    @ObservationIgnored private let liveActivity = RideActivityController()
    /// Why the last ride ended on its own, for the home screen. Cleared on the next ride.
    private(set) var autoEndNote: String?

    private enum Keys {
        static let virtualShifting = "virtualShifting"
        static let reportsPower = "reportsPower"
        static let volumeButtonsShift = "volumeButtonsShift"
        static let debugMode = "debugMode"
        static let lastTrainerConnection = "lastTrainerConnection"
        static let lastZwiftConnection = "lastZwiftConnection"
        static let speedUnit = "speedUnit"
        static let source = "trainerSource"
        static let shiftingModel = "shiftingModel"
        static let calibration = "trainerCalibration"
        static let gearProfile = "gearProfile"
        static let rider = "riderSetup"
        static let gradePerGear = "gradePerGear"
    }

    private func save(_ value: some Encodable, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// Monotonic seconds since launch, the bridge's clock.
    private var now: TimeInterval {
        let d = ContinuousClock.now - clockStart
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    init() {
        let defaults = UserDefaults.standard
        source = defaults.string(forKey: Keys.source).flatMap(TrainerSource.init) ?? .bluetooth
        lastTrainerConnection = defaults.object(forKey: Keys.lastTrainerConnection) as? Date
        lastZwiftConnection = defaults.object(forKey: Keys.lastZwiftConnection) as? Date
        defaults.register(defaults: [
            Keys.virtualShifting: true,
            Keys.reportsPower: true,
            Keys.volumeButtonsShift: true,
            Keys.gradePerGear: 0.01,
        ])
        profile = Self.load(GearProfile.self, forKey: Keys.gearProfile) ?? .standard
        rider = Self.load(RiderSetup.self, forKey: Keys.rider) ?? RiderSetup()
        gradePerGear = defaults.double(forKey: Keys.gradePerGear)
        virtualShifting = defaults.bool(forKey: Keys.virtualShifting)
        reportsPower = defaults.bool(forKey: Keys.reportsPower)
        volumeButtonsShift = defaults.bool(forKey: Keys.volumeButtonsShift)
        debugMode = defaults.bool(forKey: Keys.debugMode)
        speedUnit = defaults.string(forKey: Keys.speedUnit).flatMap(SpeedUnit.init) ?? .localeDefault
        shiftingModel = defaults.string(forKey: Keys.shiftingModel).flatMap(ShiftingModel.init) ?? .simple
        savedCalibration = defaults.data(forKey: Keys.calibration)
            .flatMap { try? JSONDecoder().decode(SavedCalibration.self, from: $0) }
        peripheral.feature = BridgeCore.virtualFeature(copying: nil, reportsPower: reportsPower)
        resetCore()
        peripheral.onControlPointWrite = { [weak self] bytes in self?.handleZwiftWrite(bytes) }
        peripheral.onLog = { [weak self] message in self?.record(.event, "zwift-ble", [], message) }
        peripheral.onChange = { [weak self] in
            guard let self else { return }
            self.zwiftState = self.peripheral.state
            if self.zwiftSubscribers != self.peripheral.subscriberCount {
                self.zwiftSubscribers = self.peripheral.subscriberCount
                let connected = self.zwiftSubscribers > 0
                if connected { self.lastZwiftConnection = Date() }
                self.record(.event, "zwift", [], connected ? "connected" : "disconnected")
                self.core.zwiftConnectionChanged(connected: connected, at: self.now)
            }
        }
        peripheral.publish() // at launch, so its GATT position is stable (see publish())
        refreshShiftState()
        // Shifts from the lock screen and the Dynamic Island (ShiftIntent).
        ShiftRouter.handler = { [weak self] harder in
            guard let self, self.isRiding else { return }
            self.shift(harder ? .up : .down)
        }
    }

    // MARK: Ride

    /// Starts a fresh log, advertises to Zwift and connects the trainer.
    func startRide() {
        guard !isRiding else { return }
        finishEndingRide() // a ride ended a moment ago: finish its teardown first
        isRiding = true
        mockCadence = 0 // every ride starts stopped; the rider pedals up from 0
        powerGauge.reset()
        speedGauge.reset()
        clearLog()
        record(.event, "ride", [], "start")
        autoEndNote = nil
        backgroundGuard.rideStarted(at: now)
        // Zwift's side of the bridge (control, last command) carries over from
        // the previous ride; only the gears start fresh.
        resetEngine()
        refreshShiftState()
        peripheral.start()
        connectTrainer()
        startTicking()
        startControlLoop()
        liveActivity.start(activityState)
    }

    /// Disconnects the trainer and stops advertising. Zwift stays paired (it
    /// just gets no data) and the log is kept for export.
    ///
    /// The home screen appears first; the teardown runs on the next main-actor
    /// turn, after the screen change has started, so it doesn't redraw the
    /// outgoing ride screen. Bluetooth and timers are main-thread objects, so
    /// "later" rather than "on another thread".
    func endRide() {
        guard isRiding else { return }
        isRiding = false
        teardownPending = true
        Task { @MainActor [weak self] in self?.finishEndingRide() }
    }

    /// Set between `endRide()` and its teardown actually running.
    @ObservationIgnored private var teardownPending = false

    private func finishEndingRide() {
        guard teardownPending else { return }
        teardownPending = false
        if calibrationRun?.phase.isActive == true { cancelCalibration() }
        calibrationRun = nil
        tickTask?.cancel()
        tickTask = nil
        controlTask?.cancel()
        controlTask = nil
        link?.onEvent = nil
        link?.stop()
        link = nil
        peripheral.stop()
        record(.event, "ride", [], "end")
        trainerState = .idle
        latestData = nil
        trainerFeature = nil
        sendingZeros = false
        core.trainerDidDisconnect()
        refreshShiftState()
        liveActivity.end()
    }

    /// A bridge with no trainer or Zwift state, using the current settings.
    private func resetCore() {
        core = BridgeCore()
        core.reportsPower = reportsPower
        if virtualShifting { _ = core.setEngine(makeEngine()) }
    }

    // MARK: Background

    // The app has the Bluetooth background modes, so a ride keeps going with
    // the phone locked. Bluetooth is only used during a ride; a ride left in
    // the background without pedalling ends itself (see BackgroundRideGuard).

    func appEnteredBackground() {
        backgroundGuard.enteredBackground(at: now)
        if isRiding { record(.event, "app", [], "background") }
    }

    func appBecameActive() {
        // Check first: it may have been suspended past the limit.
        if endRideIfAbandoned(at: now) == false, isRiding, backgroundGuard.inBackground {
            record(.event, "app", [], "foreground")
        }
        backgroundGuard.becameActive(at: now)
    }

    /// Ends the ride if it's been left in the background, idle, for too long.
    private func endRideIfAbandoned(at time: TimeInterval) -> Bool {
        guard isRiding, backgroundGuard.shouldEndRide(at: time) else { return false }
        let minutes = Int(backgroundGuard.idleLimit / 60)
        record(.event, "ride", [], "ended automatically: \(minutes) min in the background without pedalling")
        endRide()
        autoEndNote = "Your last ride ended on its own after \(minutes) minutes in the background without pedalling."
        return true
    }

    // MARK: Shifting

    func shift(_ direction: Gearbox.Direction) {
        let (outcome, outputs) = core.shift(direction, at: now)
        perform(outputs) // the trainer first; haptics, log and UI after
        lastShift = ShiftEvent(outcome: outcome, serial: (lastShift?.serial ?? 0) + 1)
        switch outcome {
        case .shifted(let index):
            haptics.shifted()
            record(.event, "shift", [], String(format: "%@ to gear %d (ratio %.2f)",
                                               direction == .up ? "up" : "down", index + 1, profile.ratios[index]))
        case .atLimit:
            haptics.blocked()
            record(.event, "shift", [], "\(direction == .up ? "up" : "down") ignored: at limit")
        case .ignoredInERG, .disabled, .overridden:
            haptics.blocked()
        }
        refreshShiftState()
    }

    /// The model actually in use.
    var activeModel: ShiftingModel {
        shiftingModel == .calibrated && usableCalibration != nil ? .calibrated : .simple
    }

    /// The saved calibration, if it was measured in the current real cog.
    var usableCalibration: TrainerCalibration? {
        guard let cal = savedCalibration?.calibration, cal.realCog == rider.realCog else { return nil }
        return cal
    }

    private func makeEngine() -> ShiftingEngine {
        if activeModel == .calibrated, let calibration = usableCalibration {
            return .forceScaling(profile: profile, rider: rider, calibration: calibration)
        }
        return .gradeOffset(profile: profile, rider: rider, gradePerGear: gradePerGear)
    }

    /// Swaps in a fresh engine, starting in the profile's starting gear.
    private func resetEngine() {
        guard virtualShifting else { return }
        perform(core.setEngine(makeEngine(), at: now))
        refreshShiftState()
    }

    /// Swaps the engine, keeping the selected gear.
    private func rebuildEngine() {
        guard virtualShifting else { return }
        var engine = makeEngine()
        if let current = core.engine?.gearbox.gearIndex {
            let start = engine.gearbox.gearIndex
            for _ in 0..<abs(current - start) { engine.shift(current > start ? .up : .down, at: -1) }
        }
        perform(core.setEngine(engine, at: now))
        refreshShiftState()
    }

    private func refreshShiftState() {
        if let engine = core.engine {
            gearNumber = engine.gearbox.gearNumber
            gearCount = engine.gearbox.profile.gearCount
            gearRatio = engine.gearbox.targetRatio
            gearLabel = engine.gearbox.profile.label(ofGear: engine.gearbox.gearIndex)
        } else {
            gearNumber = nil
            gearCount = 0
            gearRatio = nil
            gearLabel = nil
        }
        let command = core.lastEngineCommand
        trainerGrade = command?.parameters.grade
        limit = command?.limit ?? .none
        if isRiding { liveActivity.update(activityState) }
    }

    /// What the lock screen and Dynamic Island show.
    private var activityState: RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            gear: gearNumber, gearCount: gearCount,
            cogSizes: profile.cogSizes, label: gearLabel)
    }

    // MARK: Control loop

    /// 50 Hz while riding: sends a command the throttle deferred (a shift or
    /// Zwift grade within 0.25 s of the last send) as soon as it's allowed,
    /// rather than at the next trainer data packet. Usually does nothing.
    private func startControlLoop() {
        controlTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                let outputs = self.core.flush(at: self.now)
                if !outputs.isEmpty {
                    self.perform(outputs)
                    self.refreshShiftState()
                }
            }
        }
    }

    // MARK: Failure handling

    /// Once a second: zeros to Zwift while the trainer is silent, and the
    /// Zwift-gone / Zwift-quiet fallbacks.
    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func tick() {
        if endRideIfAbandoned(at: now) { return }
        liveActivity.heartbeat()
        let before = core.fallback
        perform(core.tick(at: now))
        if core.sendingZeros != sendingZeros {
            sendingZeros = core.sendingZeros
            record(.event, "failsafe", [], sendingZeros ? "no trainer data: sending zeros to Zwift" : "trainer data resumed")
        }
        if core.fallback != before {
            switch core.fallback {
            case .zwiftDisconnected: record(.event, "failsafe", [], "Zwift gone: trainer eased to flat")
            case .zwiftQuiet: record(.event, "failsafe", [], "Zwift quiet: trainer eased to flat")
            case .none: break
            }
            zwiftMode = core.zwiftMode
            refreshShiftState()
        }
        fallback = core.fallback
    }

    /// A one-line warning for the main screen, if something needs attention.
    var alertLabel: String? {
        if calibrationRun?.phase.isActive == true { return "Calibrating: Zwift's commands are on hold." }
        if sendingZeros {
            return trainerState.isConnected
                ? "No data from the trainer."
                : "Trainer not connected (\(trainerState.label.lowercased()))."
        }
        switch fallback {
        case .zwiftDisconnected: return "Zwift disconnected, so the trainer was eased to a flat road."
        case .zwiftQuiet: return "No commands from Zwift for 2 minutes, so the trainer was eased to a flat road."
        case .none: return nil
        }
    }

    // MARK: Labels

    var zwiftLabel: String {
        switch zwiftState {
        case .stopped: "Not advertising"
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
        if calibrationRun?.phase.isActive == true { cancelCalibration() }
        link?.onEvent = nil
        link?.stop()
        core.trainerDidDisconnect()
        latestData = nil

        let newLink: TrainerLink
        switch source {
        case .mock:
            let mock = MockTrainerLink()
            mock.cadence = mockCadence
            mock.realGear = (rider.realChainring, rider.realCog)
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
            if state.isConnected, source == .bluetooth { lastTrainerConnection = Date() }
            if !state.isConnected { core.trainerDidDisconnect() }
            record(.event, "trainerState", [], state.label)
        case .ready:
            perform(core.trainerDidConnect())
        case .data(let data, let raw):
            latestData = data
            let time = now
            backgroundGuard.observe(data, at: time)
            if endRideIfAbandoned(at: time) { return }
            if let watts = data.instantaneousPower { powerGauge.observe(Double(watts), at: time) }
            if let kmh = data.instantaneousSpeed { speedGauge.observe(kmh, at: time) }
            // The bulk of the log (several a second); only kept in debug mode.
            if debugMode { record(.fromTrainer, FTMSUUID.indoorBikeData, raw, data.logSummary) }
            perform(core.handleTrainerData(data, at: now))
            updateCalibration(with: data)
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
        fallback = core.fallback
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

// MARK: - Calibration

extension BridgeController {
    var calibrationPlan: CalibrationPlan {
        var plan = CalibrationPlan()
        plan.powerCap = calibrationPowerCap
        plan.wheelCircumference = profile.wheelCircumference
        return plan
    }

    var canCalibrate: Bool {
        trainerState.isConnected && !(calibrationRun?.phase.isActive ?? false)
    }

    func startCalibration() {
        guard canCalibrate else { return }
        var run = CalibrationRun(plan: calibrationPlan, rider: rider)
        let time = now
        guard let command = run.start(at: time) else { return }
        calibrationRun = run
        calibrationTime = time
        record(.event, "calibration", [], "start: \(run.steps.count) steps, cap \(Int(calibrationPowerCap)) W")
        followStepWithMock()
        perform(core.setTrainerOverride(command, at: time))
    }

    func skipCalibrationStep() {
        guard var run = calibrationRun else { return }
        let command = run.skipStep(at: now)
        calibrationRun = run
        record(.event, "calibration", [], "skipped step")
        afterCalibrationChange(command)
    }

    func cancelCalibration() {
        guard var run = calibrationRun else { return }
        run.cancel()
        calibrationRun = nil
        record(.event, "calibration", [], "cancelled")
        perform(core.setTrainerOverride(nil, at: now))
    }

    /// Saves the finished run's calibration and switches to the calibrated model.
    func saveCalibration() {
        guard case .finished(let result)? = calibrationRun?.phase else { return }
        let saved = SavedCalibration(calibration: result.calibration, date: Date(), maxGradeMeasured: result.maxGradeMeasured)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Keys.calibration)
        }
        savedCalibration = saved
        calibrationRun = nil
        record(.event, "calibration", [], "saved")
        if shiftingModel == .calibrated { rebuildEngine() } else { shiftingModel = .calibrated }
    }

    func discardCalibrationResult() {
        calibrationRun = nil
    }

    private func updateCalibration(with data: IndoorBikeData) {
        guard var run = calibrationRun, run.phase.isActive else { return }
        let time = now
        let command = run.handle(data, at: time)
        calibrationRun = run
        calibrationTime = time
        afterCalibrationChange(command)
    }

    /// After the run advanced: send the next step, or hand the trainer back when done.
    private func afterCalibrationChange(_ command: ControlPointRequest?) {
        guard let run = calibrationRun else { return }
        if let command {
            let step = run.steps[run.stepIndex]
            record(.event, "calibration", [], String(format: "step %d/%d: grade %.1f%%, %.0f rpm",
                                                     run.stepIndex + 1, run.steps.count, step.grade * 100, step.targetCadence))
            followStepWithMock()
            perform(core.setTrainerOverride(command, at: now))
        } else if !run.phase.isActive {
            switch run.phase {
            case .finished(let result):
                let c = result.calibration
                record(.event, "calibration", [], String(format: "finished: a=%.2f b=%.1f c=%.3f maxGrade=%.3f rms=%.2f",
                                                         c.a, c.b, c.c, c.maxGrade, c.residualRMS ?? 0))
            case .failed(let error):
                record(.event, "calibration", [], "failed: \(error)")
            default:
                break
            }
            perform(core.setTrainerOverride(nil, at: now))
        }
    }

    private func followStepWithMock() {
        guard source == .mock, mockFollowsCalibration, let step = calibrationRun?.currentStep else { return }
        mockCadence = step.targetCadence
    }
}

