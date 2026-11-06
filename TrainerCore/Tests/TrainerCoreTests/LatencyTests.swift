import Testing
@testable import TrainerCore

/// Shifts and Zwift grades must reach the trainer without waiting for trainer data.
@Suite("Latency")
struct LatencyTests {
    let road = SimulationParameters(windSpeed: 0, grade: 0.03, crr: 0.004, cw: 0.51)
    let data = IndoorBikeData(instantaneousSpeed: 28.8, instantaneousCadence: 85, instantaneousPower: 200)

    func bridge(_ engine: ShiftingEngine?) -> BridgeCore {
        var b = BridgeCore(engine: engine)
        _ = b.trainerDidConnect()
        _ = b.handleTrainerResponse(.init(to: .requestControl, result: .success), at: 0)
        _ = b.handleZwift(.requestControl, at: 0)
        _ = b.handleZwift(.setIndoorBikeSimulation(road), at: 0)
        return b
    }

    var calibrated: ShiftingEngine {
        .forceScaling(profile: .standard, rider: .fiftySeventeen, calibration: .nominal())
    }

    func grades(_ outputs: [BridgeCore.Output]) -> [Double] {
        outputs.compactMap {
            if case .sendToTrainer(.setIndoorBikeSimulation(let p)) = $0 { p.grade } else { nil }
        }
    }

    @Test func calibratedShiftSendsNewGearImmediately() {
        var b = bridge(calibrated)
        let before = grades(b.handleTrainerData(data, at: 1.0))
        let (_, out) = b.shift(.up, at: 2.0)
        let atShift = grades(out)
        #expect(before.count == 1 && atShift.count == 1)
        #expect(atShift[0] > before[0])
        // Nothing left to send: the shift's command was already final.
        #expect(grades(b.flush(at: 2.5)).isEmpty)
    }

    @Test func shiftInsideThrottleWindowGoesOutViaFlush() {
        var b = bridge(calibrated)
        _ = b.handleTrainerData(data, at: 1.0)            // sends at 1.0
        let (_, out) = b.shift(.up, at: 1.1)               // too soon: deferred
        #expect(grades(out).isEmpty)
        #expect(grades(b.flush(at: 1.2)).isEmpty)          // still inside the window
        #expect(grades(b.flush(at: 1.25)).count == 1)      // out as soon as allowed
        #expect(grades(b.flush(at: 1.3)).isEmpty)          // and only once
    }

    @Test func zwiftGradeInsideThrottleWindowGoesOutViaFlush() {
        var b = bridge(calibrated)
        _ = b.handleTrainerData(data, at: 1.0)
        var steeper = road
        steeper.grade = 0.06
        #expect(grades(b.handleZwift(.setIndoorBikeSimulation(steeper), at: 1.05)).isEmpty)
        #expect(grades(b.flush(at: 1.25)).count == 1)
    }

    @Test func flushIsQuietWhenNothingChanged() {
        var b = bridge(calibrated)
        _ = b.handleTrainerData(data, at: 1.0)
        for t in stride(from: 1.02, to: 3.0, by: 0.02) {
            #expect(b.flush(at: t).isEmpty)
        }
    }

    @Test func flushDoesNothingWithoutEngineOrInERG() {
        var plain = bridge(nil)
        #expect(plain.flush(at: 5).isEmpty)

        var erg = bridge(calibrated)
        _ = erg.handleZwift(.setTargetPower(watts: 200), at: 1)
        #expect(erg.flush(at: 5).isEmpty)
    }

    @Test func unansweredRequestBlocksBriefly() {
        var q = ControlPointQueue()
        let a = ControlPointRequest.setIndoorBikeSimulation(SimulationParameters(grade: 0.01))
        let b = ControlPointRequest.setIndoorBikeSimulation(SimulationParameters(grade: 0.02))
        #expect(q.enqueue(a, at: 0) == a)
        #expect(q.enqueue(b, at: 0.5) == nil)               // a still in flight
        #expect(q.checkTimeout(at: 0.75) == b)              // a given up on
        // Enqueueing also notices a timed-out request, without waiting for the loop.
        let c = ControlPointRequest.setIndoorBikeSimulation(SimulationParameters(grade: 0.03))
        #expect(q.enqueue(c, at: 1.6) == c)
    }
}
