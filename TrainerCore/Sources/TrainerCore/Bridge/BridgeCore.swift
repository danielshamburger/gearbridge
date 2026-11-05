/// The bridge's decisions, free of Bluetooth: how to answer Zwift and what to
/// send the trainer. The app feeds it events and performs the outputs.
///
/// Milestones 2–3 (transparent control): Zwift's commands are acknowledged
/// immediately and forwarded unchanged; trainer data passes through to Zwift.
/// The gear engine will later replace the forwarding of simulation commands.
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

    public private(set) var zwiftHasControl = false
    public private(set) var zwiftMode: ZwiftMode = .idle
    public private(set) var isTrainerConnected = false
    public private(set) var trainerHasControl = false

    public init() {}

    // MARK: Zwift side

    /// A write to the virtual trainer's Control Point.
    public mutating func handleZwiftWrite(_ bytes: [UInt8]) -> [Output] {
        guard let request = try? ControlPointRequest(bytes: bytes) else {
            let response = ControlPointResponse(requestOpcode: bytes.first ?? 0, result: .invalidParameter)
            return [.respondToZwift(response)]
        }
        return handleZwift(request)
    }

    public mutating func handleZwift(_ request: ControlPointRequest) -> [Output] {
        func reply(_ result: ControlPointResponse.Result, then extra: [Output] = []) -> [Output] {
            [.respondToZwift(ControlPointResponse(to: request, result: result))] + extra
        }

        if request == .requestControl {
            zwiftHasControl = true
            return reply(.success)
        }
        guard zwiftHasControl else { return reply(.controlNotPermitted) }

        switch request {
        case .reset:
            // Zwift gives up control. Leave the trainer under our control at a
            // flat, moderate resistance rather than resetting it.
            zwiftHasControl = false
            zwiftMode = .idle
            return reply(.success, then: [.notifyZwiftStatus(.reset)] + toTrainer(trainerCommand))
        case .startOrResume:
            return reply(.success, then: [.notifyZwiftStatus(.startedOrResumedByUser)])
        case .stopOrPause(let control):
            return reply(.success, then: [.notifyZwiftStatus(.stoppedOrPausedByUser(control))])
        case .setIndoorBikeSimulation(let parameters):
            zwiftMode = .simulation(parameters)
            return reply(.success, then: [.notifyZwiftStatus(.indoorBikeSimulationParametersChanged(parameters))]
                + toTrainer(trainerCommand))
        case .setTargetPower(let watts):
            zwiftMode = .targetPower(watts: watts)
            return reply(.success, then: [.notifyZwiftStatus(.targetPowerChanged(watts: watts))]
                + toTrainer(trainerCommand))
        case .setWheelCircumference(let mm):
            // Acknowledged but not forwarded: the trainer's own wheel setting
            // determines the speed it reports, which the gear math relies on.
            return reply(.success, then: [.notifyZwiftStatus(.wheelCircumferenceChanged(millimeters: mm))])
        case .requestControl, .setTargetSpeed, .setTargetInclination, .setTargetResistanceLevel,
             .setTargetHeartRate, .spinDownControl, .setTargetedCadence, .unsupported:
            return reply(.opCodeNotSupported)
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

    public mutating func handleTrainerResponse(_ response: ControlPointResponse) -> [Output] {
        let requestControl = ControlPointRequest.requestControl.opcode
        switch (response.requestOpcode, response.result) {
        case (requestControl, .success):
            trainerHasControl = true
            // Restore whatever Zwift last asked for (e.g. after a reconnect).
            return [.sendToTrainer(.startOrResume), .sendToTrainer(trainerCommand)]
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

    public func handleTrainerData(_ data: IndoorBikeData) -> [Output] {
        [.notifyZwiftData(data)]
    }

    // MARK: Helpers

    /// The command the trainer should currently be holding.
    public var trainerCommand: ControlPointRequest {
        switch zwiftMode {
        case .idle: .setIndoorBikeSimulation(.flat)
        case .simulation(let p): .setIndoorBikeSimulation(p)
        case .targetPower(let watts): .setTargetPower(watts: watts)
        }
    }

    private func toTrainer(_ request: ControlPointRequest) -> [Output] {
        trainerHasControl ? [.sendToTrainer(request)] : []
    }

    // MARK: Advertised capabilities

    /// Features the virtual trainer advertises: the trainer's data fields
    /// (copied when known) and only the targets the bridge handles.
    public static func virtualFeature(copying trainer: FitnessMachineFeature?) -> FitnessMachineFeature {
        FitnessMachineFeature(
            machine: trainer?.machine ?? [.cadence, .totalDistance, .powerMeasurement, .elapsedTime],
            targetSetting: [.power, .indoorBikeSimulation]
        )
    }

    public static let defaultPowerRange = SupportedPowerRange(minimum: 0, maximum: 1500, increment: 1)
    public static let defaultResistanceRange = SupportedResistanceLevelRange(minimum: 0, maximum: 100, increment: 1)
}
