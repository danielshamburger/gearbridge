import Testing
@testable import TrainerCore

@Suite("Failure handling")
struct FailureHandlingTests {
    let steep = SimulationParameters(windSpeed: 0, grade: 0.12, crr: 0.004, cw: 0.51)
    let data = IndoorBikeData(instantaneousSpeed: 30, instantaneousCadence: 85, instantaneousPower: 200)
    let zeros = IndoorBikeData(instantaneousSpeed: 0, instantaneousCadence: 0, instantaneousPower: 0)

    /// Trainer controlled, Zwift connected and riding up `steep` since t = 0.
    func riding() -> BridgeCore {
        var b = BridgeCore()
        _ = b.trainerDidConnect()
        _ = b.handleTrainerResponse(.init(to: .requestControl, result: .success), at: 0)
        b.zwiftConnectionChanged(connected: true, at: 0)
        _ = b.handleZwift(.requestControl, at: 0)
        _ = b.handleZwift(.setIndoorBikeSimulation(steep), at: 0)
        _ = b.handleTrainerData(data, at: 0)
        return b
    }

    func sendsToTrainer(_ outputs: [BridgeCore.Output]) -> [ControlPointRequest] {
        outputs.compactMap { if case .sendToTrainer(let r) = $0 { r } else { nil } }
    }

    @Test func freshDataMeansNoZeros() {
        var b = riding()
        #expect(b.tick(at: 1) == [])
        #expect(!b.sendingZeros)
    }

    @Test func staleTrainerDataSendsZerosUntilDataReturns() {
        var b = riding()
        b.trainerDidDisconnect()
        #expect(b.tick(at: 2.5) == [.notifyZwiftData(zeros)])
        #expect(b.sendingZeros)
        #expect(b.tick(at: 3.5) == [.notifyZwiftData(zeros)])
        _ = b.handleTrainerData(data, at: 4)
        #expect(b.tick(at: 4.5) == [])
        #expect(!b.sendingZeros)
    }

    @Test func zerosRespectPowerSetting() {
        var b = BridgeCore()
        b.reportsPower = false
        #expect(b.tick(at: 10) == [.notifyZwiftData(IndoorBikeData(instantaneousSpeed: 0, instantaneousCadence: 0))])
    }

    @Test func zwiftDisconnectReleasesTrainerAfterGrace() {
        var b = riding()
        b.zwiftConnectionChanged(connected: false, at: 10)
        _ = b.handleTrainerData(data, at: 12)
        #expect(sendsToTrainer(b.tick(at: 12)).isEmpty) // within the 5 s grace
        _ = b.handleTrainerData(data, at: 15)
        #expect(sendsToTrainer(b.tick(at: 15)) == [.setIndoorBikeSimulation(.flat)])
        #expect(b.fallback == .zwiftDisconnected)
        #expect(!b.zwiftHasControl)
        // Only once.
        _ = b.handleTrainerData(data, at: 16)
        #expect(b.tick(at: 16) == [])
    }

    @Test func briefZwiftDropIsIgnored() {
        var b = riding()
        b.zwiftConnectionChanged(connected: false, at: 10)
        b.zwiftConnectionChanged(connected: true, at: 12)
        _ = b.handleTrainerData(data, at: 20)
        #expect(b.tick(at: 20) == [])
        #expect(b.fallback == .none)
    }

    @Test func quietZwiftEasesToFlatAndResumesOnNextCommand() {
        var b = riding()
        _ = b.handleTrainerData(data, at: 119)
        #expect(b.tick(at: 119) == [])
        _ = b.handleTrainerData(data, at: 120)
        #expect(sendsToTrainer(b.tick(at: 120)) == [.setIndoorBikeSimulation(.flat)])
        #expect(b.fallback == .zwiftQuiet)
        #expect(b.zwiftHasControl)

        let next = SimulationParameters(windSpeed: 0, grade: 0.03, crr: 0.004, cw: 0.51)
        #expect(sendsToTrainer(b.handleZwift(.setIndoorBikeSimulation(next), at: 125)) == [.setIndoorBikeSimulation(next)])
        #expect(b.fallback == .none)
    }

    @Test func ergNeverTimesOut() {
        var b = riding()
        _ = b.handleZwift(.setTargetPower(watts: 250), at: 1)
        _ = b.handleTrainerData(data, at: 600)
        #expect(b.tick(at: 600) == [])
        #expect(b.zwiftMode == .targetPower(watts: 250))
    }

    @Test func freshTrainerAfterAppRestartGetsFlatRoad() {
        // The plan's "bridge app crashed" case: a new bridge resets the trainer
        // (which may still hold a steep grade) as soon as it has control.
        var b = BridgeCore()
        _ = b.trainerDidConnect()
        #expect(b.handleTrainerResponse(.init(to: .requestControl, result: .success), at: 0)
            == [.sendToTrainer(.startOrResume), .sendToTrainer(.setIndoorBikeSimulation(.flat))])
    }
}
