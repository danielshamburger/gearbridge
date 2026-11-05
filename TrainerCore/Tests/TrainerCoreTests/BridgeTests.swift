import Testing
@testable import TrainerCore

@Suite("Bridge core")
struct BridgeCoreTests {
    /// A bridge whose trainer is connected and controlled.
    func connectedBridge() -> BridgeCore {
        var bridge = BridgeCore()
        _ = bridge.trainerDidConnect()
        _ = bridge.handleTrainerResponse(.init(to: .requestControl, result: .success))
        return bridge
    }

    @Test func zwiftMustRequestControlFirst() {
        var bridge = connectedBridge()
        let sim = ControlPointRequest.setIndoorBikeSimulation(.init(grade: 0.05))
        #expect(bridge.handleZwift(sim) == [.respondToZwift(.init(to: sim, result: .controlNotPermitted))])
        #expect(bridge.handleZwift(.requestControl) == [.respondToZwift(.init(to: .requestControl, result: .success))])
    }

    @Test func simulationIsAckedAndForwarded() {
        var bridge = connectedBridge()
        _ = bridge.handleZwift(.requestControl)
        let p = SimulationParameters(grade: 0.05, crr: 0.004, cw: 0.51)
        let out = bridge.handleZwift(.setIndoorBikeSimulation(p))
        #expect(out == [
            .respondToZwift(.init(to: .setIndoorBikeSimulation(p), result: .success)),
            .notifyZwiftStatus(.indoorBikeSimulationParametersChanged(p)),
            .sendToTrainer(.setIndoorBikeSimulation(p)),
        ])
        #expect(bridge.zwiftMode == .simulation(p))
    }

    @Test func ergIsForwarded() {
        var bridge = connectedBridge()
        _ = bridge.handleZwift(.requestControl)
        let out = bridge.handleZwift(.setTargetPower(watts: 200))
        #expect(out.contains(.sendToTrainer(.setTargetPower(watts: 200))))
    }

    @Test func commandsWhileTrainerAbsentAreReplayedOnConnect() {
        var bridge = BridgeCore()
        _ = bridge.handleZwift(.requestControl)
        let p = SimulationParameters(grade: 0.03)
        let out = bridge.handleZwift(.setIndoorBikeSimulation(p))
        #expect(!out.contains { if case .sendToTrainer = $0 { true } else { false } })

        #expect(bridge.trainerDidConnect() == [.sendToTrainer(.requestControl)])
        let replay = bridge.handleTrainerResponse(.init(to: .requestControl, result: .success))
        #expect(replay == [.sendToTrainer(.startOrResume), .sendToTrainer(.setIndoorBikeSimulation(p))])
    }

    @Test func zwiftResetLeavesTrainerFlat() {
        var bridge = connectedBridge()
        _ = bridge.handleZwift(.requestControl)
        _ = bridge.handleZwift(.setIndoorBikeSimulation(.init(grade: 0.08)))
        let out = bridge.handleZwift(.reset)
        #expect(out.contains(.sendToTrainer(.setIndoorBikeSimulation(.flat))))
        #expect(!bridge.zwiftHasControl)
    }

    @Test func unsupportedAndMalformedRequests() {
        var bridge = connectedBridge()
        _ = bridge.handleZwift(.requestControl)
        #expect(bridge.handleZwift(.spinDownControl(.start))
            == [.respondToZwift(.init(to: .spinDownControl(.start), result: .opCodeNotSupported))])
        #expect(bridge.handleZwiftWrite([0x11, 0x00])
            == [.respondToZwift(.init(requestOpcode: 0x11, result: .invalidParameter))])
    }

    @Test func wheelCircumferenceIsNotForwarded() {
        var bridge = connectedBridge()
        _ = bridge.handleZwift(.requestControl)
        let out = bridge.handleZwift(.setWheelCircumference(millimeters: 2096))
        #expect(!out.contains { if case .sendToTrainer = $0 { true } else { false } })
    }

    @Test func regainsTrainerControlWhenLost() {
        var bridge = connectedBridge()
        #expect(bridge.handleTrainerStatus(.controlPermissionLost) == [.sendToTrainer(.requestControl)])
        #expect(!bridge.trainerHasControl)
        let rejected = ControlPointResponse(to: .setIndoorBikeSimulation(.flat), result: .controlNotPermitted)
        #expect(bridge.handleTrainerResponse(rejected) == [.sendToTrainer(.requestControl)])
        // A rejected requestControl must not loop.
        #expect(bridge.handleTrainerResponse(.init(to: .requestControl, result: .controlNotPermitted)) == [])
    }

    @Test func dataPassesThrough() {
        let data = IndoorBikeData(instantaneousSpeed: 30, instantaneousCadence: 85, instantaneousPower: 200)
        #expect(BridgeCore().handleTrainerData(data) == [.notifyZwiftData(data)])
    }

    @Test func virtualFeatureAdvertisesOnlyHandledTargets() {
        let feature = BridgeCore.virtualFeature(copying: MockTrainer.feature)
        #expect(feature.machine == MockTrainer.feature.machine)
        #expect(feature.targetSetting == [.power, .indoorBikeSimulation])
    }

    /// Bridge plus mock trainer, wired the way the app wires them.
    @Test func endToEndWithMockTrainer() throws {
        var bridge = BridgeCore()
        var trainer = MockTrainer()
        var pending = bridge.trainerDidConnect()
        var toZwift: [BridgeCore.Output] = []

        func pump() throws {
            while !pending.isEmpty {
                let output = pending.removeFirst()
                if case .sendToTrainer(let request) = output {
                    let response = trainer.handle(try ControlPointRequest(bytes: request.encoded()))
                    pending += bridge.handleTrainerResponse(response)
                } else {
                    toZwift.append(output)
                }
            }
        }
        try pump()
        #expect(trainer.hasControl)
        #expect(trainer.isStarted)

        pending += bridge.handleZwiftWrite(ControlPointRequest.requestControl.encoded())
        let p = SimulationParameters(grade: 0.06, crr: 0.004, cw: 0.51)
        pending += bridge.handleZwiftWrite(ControlPointRequest.setIndoorBikeSimulation(p).encoded())
        try pump()
        #expect(trainer.mode == .simulation(p))
        #expect(toZwift.contains(.respondToZwift(.init(to: .setIndoorBikeSimulation(p), result: .success))))
    }
}

@Suite("Packet log")
struct PacketLogTests {
    @Test func csvEscapesAndFormats() {
        var log = PacketLog()
        log.append(at: 1.5, .fromZwift, "2AD9", bytes: [0x11, 0x00], summary: "sim, \"quoted\"")
        #expect(log.csv() == "time_s,direction,channel,hex,summary\n1.500,zwift>app,2AD9,11 00,\"sim, \"\"quoted\"\"\"\n")
    }

    @Test func dropsOldestWhenFull() {
        var log = PacketLog(capacity: 2)
        for i in 0..<3 { log.append(at: Double(i), .event, "e\(i)") }
        #expect(log.entries.map(\.channel) == ["e1", "e2"])
        #expect(log.droppedCount == 1)
    }

    @Test func summaries() {
        let data = IndoorBikeData(instantaneousSpeed: 31.5, instantaneousCadence: 85, instantaneousPower: 177)
        #expect(data.logSummary == "speed=31.50kmh cadence=85.0 power=177")
        #expect(SimulationParameters(grade: 0.05, crr: 0.004, cw: 0.51).logSummary
            == "grade=5.00% crr=0.0040 cw=0.51 wind=0.000")
    }
}
