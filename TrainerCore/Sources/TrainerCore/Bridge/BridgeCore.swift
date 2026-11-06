import Foundation

/// The bridge's decisions, free of Bluetooth: how to answer Zwift and what to
/// send the trainer. The app feeds it events and performs the outputs.
///
/// Without an engine, Zwift's commands are forwarded unchanged (transparent
/// control). With an engine, simulation commands go through the gear engine,
/// which is re-run on every trainer data packet and every shift. ERG commands
/// are always forwarded unchanged and shifts are ignored while in ERG.
///
/// `time` arguments are a monotonic clock in seconds; they only matter when an
/// engine is set.
public struct BridgeCore: Sendable {
    public enum Output: Equatable, Sendable {
        case respondToZwift(ControlPointResponse)
        case notifyZwiftStatus(FitnessMachineStatus)
        case notifyZwiftData(IndoorBikeData)
        case sendToTrainer(ControlPointRequest)
    }

    /// What Zwift currently wants from the trainer.
    public enum ZwiftMode: Equatable, Sendable {
        case idle
        case simulation(SimulationParameters)
        case targetPower(watts: Int16)
    }

    public enum ShiftOutcome: Equatable, Sendable {
        case shifted(toIndex: Int)
        case atLimit
        /// No engine: virtual shifting is off.
        case disabled
        /// Zwift is in ERG mode, which holds power regardless of gear.
        case ignoredInERG
        /// Something else (calibration) is controlling the trainer.
        case overridden
    }

    /// Road used when no simulation command applies (before Zwift takes
    /// control, or after it resets) and an engine is set: flat, with Zwift's
    /// usual solo rolling resistance and drag so gears still feel like gears.
    public static let idleRoad = SimulationParameters(windSpeed: 0, grade: 0, crr: 0.004, cw: 0.51)

    public private(set) var zwiftHasControl = false
    public private(set) var zwiftMode: ZwiftMode = .idle
    public private(set) var isTrainerConnected = false
    public private(set) var trainerHasControl = false

    public private(set) var engine: ShiftingEngine?
    /// The engine's latest result, for the UI. Nil in ERG or without an engine.
    public private(set) var lastEngineCommand: TrainerCommand?

    /// While set, the trainer holds this command (e.g. during calibration).
    /// Zwift is still answered but its commands only take effect once the
    /// override is cleared, and shifts are ignored.
    public private(set) var trainerOverride: ControlPointRequest?

    /// When false, power is stripped from the data sent to Zwift, so Zwift
    /// takes power from another source (e.g. the trainer over ANT+).
    public var reportsPower = true

    private var throttle = CommandThrottle()

    // MARK: Failure handling state

    /// Why the bridge stopped following Zwift on its own, if it did.
    public enum Fallback: Equatable, Sendable {
        case none
        /// Zwift disconnected (unsubscribed) for longer than `zwiftDisconnectGrace`.
        case zwiftDisconnected
        /// No simulation command for `zwiftQuietTimeout`; eased to a flat road.
        case zwiftQuiet
    }

    public struct Timeouts: Equatable, Sendable {
        /// No trainer data for this long: send Zwift zeros instead of going silent.
        public var trainerDataStale: TimeInterval = 2
        /// Zwift gone this long: release the trainer to a flat road.
        public var zwiftDisconnectGrace: TimeInterval = 5
        /// No simulation command this long: ease to a flat road. Zwift only
        /// sends on change, and was seen going ~40 s without one on flat roads,
        /// so this is long. ERG never times out (targets are held for minutes).
        public var zwiftQuietTimeout: TimeInterval = 120

        public init() {}
    }

    public var timeouts = Timeouts()
    public private(set) var fallback: Fallback = .none
    /// True while trainer data is stale and Zwift is being sent zeros.
    public private(set) var sendingZeros = false

    private var lastTrainerDataTime: TimeInterval?
    private var lastZwiftCommandTime: TimeInterval?
    private var zwiftConnected = false
    private var zwiftDisconnectedSince: TimeInterval?

    public init(engine: ShiftingEngine? = nil) {
        self.engine = engine
    }

    // MARK: Zwift side

    /// A write to the virtual trainer's Control Point.
    public mutating func handleZwiftWrite(_ bytes: [UInt8], at time: TimeInterval = 0) -> [Output] {
        guard let request = try? ControlPointRequest(bytes: bytes) else {
            let response = ControlPointResponse(requestOpcode: bytes.first ?? 0, result: .invalidParameter)
            return [.respondToZwift(response)]
        }
        return handleZwift(request, at: time)
    }

    public mutating func handleZwift(_ request: ControlPointRequest, at time: TimeInterval = 0) -> [Output] {
        func reply(_ result: ControlPointResponse.Result, then extra: [Output] = []) -> [Output] {
            [.respondToZwift(ControlPointResponse(to: request, result: result))] + extra
        }

        lastZwiftCommandTime = time
        fallback = .none
        if request == .requestControl {
            zwiftHasControl = true
            return reply(.success)
        }
        guard zwiftHasControl else { return reply(.controlNotPermitted) }

        switch request {
        case .reset:
            // Zwift gives up control. Leave the trainer under our control on a
            // flat road rather than resetting it.
            zwiftHasControl = false
            setMode(.idle)
            return reply(.success, then: [.notifyZwiftStatus(.reset)] + commandTrainer(at: time, force: true))
        case .startOrResume:
            return reply(.success, then: [.notifyZwiftStatus(.startedOrResumedByUser)])
        case .stopOrPause(let control):
            return reply(.success, then: [.notifyZwiftStatus(.stoppedOrPausedByUser(control))])
        case .setIndoorBikeSimulation(let parameters):
            setMode(.simulation(parameters))
            return reply(.success, then: [.notifyZwiftStatus(.indoorBikeSimulationParametersChanged(parameters))]
                + commandTrainer(at: time, force: true))
        case .setTargetPower(let watts):
            setMode(.targetPower(watts: watts))
            return reply(.success, then: [.notifyZwiftStatus(.targetPowerChanged(watts: watts))]
                + commandTrainer(at: time, force: true))
        case .setWheelCircumference(let mm):
            // Acknowledged but not forwarded: the trainer's own wheel setting
            // determines the speed it reports, which the gear math relies on.
            return reply(.success, then: [.notifyZwiftStatus(.wheelCircumferenceChanged(millimeters: mm))])
        case .requestControl, .setTargetSpeed, .setTargetInclination, .setTargetResistanceLevel,
             .setTargetHeartRate, .spinDownControl, .setTargetedCadence, .unsupported:
            return reply(.opCodeNotSupported)
        }
    }

    // MARK: Shifting

    /// Replaces the engine (nil turns virtual shifting off) and re-sends the
    /// trainer command it implies.
    public mutating func setEngine(_ newEngine: ShiftingEngine?, at time: TimeInterval = 0) -> [Output] {
        engine = newEngine
        lastEngineCommand = nil
        throttle.reset()
        return commandTrainer(at: time, force: true)
    }

    /// Sets or clears the override; clearing restores what Zwift last asked for.
    public mutating func setTrainerOverride(_ request: ControlPointRequest?, at time: TimeInterval) -> [Output] {
        trainerOverride = request
        throttle.reset()
        return commandTrainer(at: time, force: true, resendOverride: true)
    }

    public mutating func shift(_ direction: Gearbox.Direction, at time: TimeInterval) -> (ShiftOutcome, [Output]) {
        guard engine != nil else { return (.disabled, []) }
        if trainerOverride != nil { return (.overridden, []) }
        if case .targetPower = zwiftMode { return (.ignoredInERG, []) }
        switch engine!.shift(direction, at: time) {
        case .atLimit:
            return (.atLimit, [])
        case .shifted(let index):
            return (.shifted(toIndex: index), commandTrainer(at: time, force: true))
        }
    }

    // MARK: Trainer side

    /// The trainer link is connected and its Control Point is subscribed.
    public mutating func trainerDidConnect() -> [Output] {
        isTrainerConnected = true
        trainerHasControl = false
        return [.sendToTrainer(.requestControl)]
    }

    public mutating func trainerDidDisconnect() {
        isTrainerConnected = false
        trainerHasControl = false
    }

    public mutating func handleTrainerResponse(_ response: ControlPointResponse, at time: TimeInterval = 0) -> [Output] {
        let requestControl = ControlPointRequest.requestControl.opcode
        switch (response.requestOpcode, response.result) {
        case (requestControl, .success):
            trainerHasControl = true
            // Restore whatever Zwift last asked for (e.g. after a reconnect).
            throttle.reset()
            return [.sendToTrainer(.startOrResume)] + commandTrainer(at: time, force: true, resendOverride: true)
        case (let op, .controlNotPermitted) where op != requestControl:
            trainerHasControl = false
            return [.sendToTrainer(.requestControl)]
        default:
            return []
        }
    }

    public mutating func handleTrainerStatus(_ status: FitnessMachineStatus) -> [Output] {
        guard status == .controlPermissionLost, isTrainerConnected else { return [] }
        trainerHasControl = false
        return [.sendToTrainer(.requestControl)]
    }

    public mutating func handleTrainerData(_ data: IndoorBikeData, at time: TimeInterval = 0) -> [Output] {
        lastTrainerDataTime = time
        sendingZeros = false
        var toZwift = data
        if !reportsPower {
            toZwift.instantaneousPower = nil
            toZwift.averagePower = nil
        }
        var outputs: [Output] = [.notifyZwiftData(toZwift)]

        if engine != nil, let speed = data.speedMetersPerSecond {
            engine!.updateSpeed(speed, at: time)
            // ERG targets don't depend on speed; only re-run the engine in sim.
            if case .targetPower = zwiftMode {} else if trainerOverride == nil {
                outputs += commandTrainer(at: time, force: false)
            }
        }
        return outputs
    }

    /// When `flush(at:)` has something to send: a re-send the throttle held
    /// back. Nil when nothing is waiting, so the app sets one timer for this
    /// time rather than polling. Shifts and Zwift commands go out at once and
    /// never wait here.
    public var flushDue: TimeInterval? {
        guard engine != nil, trainerOverride == nil, trainerHasControl else { return nil }
        if case .targetPower = zwiftMode { return nil }
        return throttle.nextDue
    }

    /// Sends a command the throttle held back, once it's allowed (at
    /// `flushDue`), instead of waiting for the next trainer data packet.
    /// Does nothing without an engine, in ERG, or during an override.
    public mutating func flush(at time: TimeInterval) -> [Output] {
        guard engine != nil, trainerOverride == nil else { return [] }
        if case .targetPower = zwiftMode { return [] }
        return commandTrainer(at: time, force: false)
    }

    // MARK: Failure handling

    /// Zwift subscribed to or left the virtual trainer.
    public mutating func zwiftConnectionChanged(connected: Bool, at time: TimeInterval) {
        guard connected != zwiftConnected else { return }
        zwiftConnected = connected
        zwiftDisconnectedSince = connected ? nil : time
    }

    /// Call about once a second. Sends Zwift zeros while trainer data is
    /// stale, and eases the trainer to a flat road if Zwift has gone away or
    /// gone quiet, rather than holding the last (possibly steep) grade.
    public mutating func tick(at time: TimeInterval) -> [Output] {
        var outputs: [Output] = []

        if time - (lastTrainerDataTime ?? -.infinity) >= timeouts.trainerDataStale {
            sendingZeros = true
            var zero = IndoorBikeData(instantaneousSpeed: 0, instantaneousCadence: 0, instantaneousPower: 0)
            if !reportsPower { zero.instantaneousPower = nil }
            outputs.append(.notifyZwiftData(zero))
        }

        if let since = zwiftDisconnectedSince, time - since >= timeouts.zwiftDisconnectGrace,
           zwiftHasControl || zwiftMode != .idle {
            zwiftHasControl = false
            setMode(.idle)
            fallback = .zwiftDisconnected
            outputs += commandTrainer(at: time, force: true)
        } else if case .simulation = zwiftMode,
                  time - (lastZwiftCommandTime ?? time) >= timeouts.zwiftQuietTimeout {
            // Zwift keeps control; its next command resumes normally.
            setMode(.idle)
            fallback = .zwiftQuiet
            outputs += commandTrainer(at: time, force: true)
        }
        return outputs
    }

    // MARK: Trainer command

    /// The command the trainer should currently be holding, and the engine's
    /// result when the engine produced it.
    public func trainerCommand(at time: TimeInterval = 0) -> (request: ControlPointRequest, engine: TrainerCommand?) {
        if let trainerOverride { return (trainerOverride, nil) }
        let road: SimulationParameters
        switch zwiftMode {
        case .targetPower(let watts):
            return (.setTargetPower(watts: watts), nil)
        case .simulation(let p):
            road = p
        case .idle:
            road = engine == nil ? .flat : Self.idleRoad
        }
        guard let engine else { return (.setIndoorBikeSimulation(road), nil) }
        let command = engine.command(for: road, at: time)
        return (.setIndoorBikeSimulation(command.parameters), command)
    }

    private mutating func setMode(_ mode: ZwiftMode) {
        if case .targetPower = mode { lastEngineCommand = nil }
        if case .targetPower = zwiftMode, mode != zwiftMode { throttle.reset() }
        zwiftMode = mode
    }

    /// Sends the current command if the trainer is controllable. Without an
    /// engine every call sends; with one, `CommandThrottle` drops repeats and
    /// limits the rate, and `force` guarantees the next allowed send happens.
    /// While an override is set, only `resendOverride` calls (setting it, or
    /// replaying after a reconnect) send anything.
    private mutating func commandTrainer(at time: TimeInterval, force: Bool, resendOverride: Bool = false) -> [Output] {
        if trainerOverride != nil, !resendOverride { return [] }
        let (request, command) = trainerCommand(at: time)
        if let command { lastEngineCommand = command }
        guard trainerHasControl else { return [] }
        if let command, !throttle.shouldSend(command.parameters, at: time, force: force) {
            return []
        }
        return [.sendToTrainer(request)]
    }

    // MARK: Advertised capabilities

    /// Features the virtual trainer advertises: the trainer's data fields
    /// (copied when known) and only the targets the bridge handles.
    public static func virtualFeature(
        copying trainer: FitnessMachineFeature?,
        reportsPower: Bool = true
    ) -> FitnessMachineFeature {
        var machine = trainer?.machine ?? [.cadence, .totalDistance, .powerMeasurement, .elapsedTime]
        if !reportsPower { machine.remove(.powerMeasurement) }
        return FitnessMachineFeature(machine: machine, targetSetting: [.power, .indoorBikeSimulation])
    }

    public static let defaultPowerRange = SupportedPowerRange(minimum: 0, maximum: 1500, increment: 1)
    public static let defaultResistanceRange = SupportedResistanceLevelRange(minimum: 0, maximum: 100, increment: 1)
}
