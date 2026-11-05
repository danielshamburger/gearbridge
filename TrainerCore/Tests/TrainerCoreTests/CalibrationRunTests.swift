import Testing
@testable import TrainerCore

@Suite("Calibration routine")
struct CalibrationRunTests {
    let rider = RiderSetup.fiftySeventeen // 50×17

    @Test func planKeepsStepsUnderPowerCap() {
        let steps = CalibrationPlan().steps(for: rider)
        let climb = steps.filter { !$0.isFloor }
        #expect(climb.first == CalibrationStep(grade: 0, targetCadence: 90, targetSpeed: climb[0].targetSpeed))
        #expect(near(climb[0].targetSpeed, 90.0 / 60 * 50 / 17 * 2.1, 1e-9))
        // 10 % needs over 350 W even at 50 rpm in 50×17, so the plan stops at 8 %.
        #expect(climb.map(\.grade).max() == 0.08)
        #expect(climb.filter { $0.grade == 0.08 }.map(\.targetCadence) == [50])
        #expect(steps.filter(\.isFloor).count == 2)
        #expect(steps.last?.isFloor == true)
    }

    @Test func higherCapReachesSteeperGrades() {
        var plan = CalibrationPlan()
        plan.powerCap = 600
        #expect(plan.steps(for: rider).filter { !$0.isFloor }.map(\.grade).max() == 0.10)
    }

    /// Rides the routine on the mock, holding each step's target cadence.
    func ride(_ run: inout CalibrationRun, _ trainer: inout MockTrainer, wobbleUntil: Double = 0) -> Double {
        var time = 0.0
        _ = trainer.handle(.requestControl)
        if let command = run.start(at: time) { _ = trainer.handle(command) }
        while run.phase.isActive, time < 3600 {
            if let step = run.currentStep {
                // Before wobbleUntil, swing cadence ±20 % so samples are unsteady.
                let wobble = time < wobbleUntil ? (Int(time * 2).isMultiple(of: 2) ? 1.2 : 0.8) : 1
                trainer.rider.cadence = step.targetCadence * wobble
            }
            time += 0.5
            let data = trainer.step(dt: 0.5)
            if let command = run.handle(data, at: time) { _ = trainer.handle(command) }
        }
        return time
    }

    @Test func recoversMockCharacteristics() throws {
        var trainer = MockTrainer(seed: 11)
        var run = CalibrationRun(rider: rider)
        let duration = ride(&run, &trainer)
        guard case .finished(let result) = run.phase else {
            Issue.record("run ended in \(run.phase)")
            return
        }
        let ch = trainer.characteristics
        let cal = result.calibration
        #expect(near(cal.b, ch.simulationMass * BikePhysics.gravity, 0.03 * 735))
        #expect(near(cal.a, ch.parasiticForce.intercept, 2))
        #expect(near(cal.c, ch.parasiticForce.slope, 0.3))
        #expect(near(cal.floorForce.intercept, ch.floorForce.intercept, 1))
        #expect(near(cal.floorForce.slope, ch.floorForce.slope, 0.15))
        // Never pushed past 8 %, so the max grade is the assumed 10 %.
        #expect(!result.maxGradeMeasured)
        #expect(cal.maxGrade == 0.10)
        #expect(cal.realCog == 17)
        #expect(result.measurements.count == run.steps.count)
        #expect(duration < 5 * 60) // 11 steps × 20 s plus a little
    }

    @Test func detectsEarlySaturation() throws {
        var characteristics = MockTrainer.Characteristics()
        characteristics.maxGrade = 0.04
        var trainer = MockTrainer(characteristics: characteristics, seed: 5)
        var run = CalibrationRun(rider: rider)
        _ = ride(&run, &trainer)
        guard case .finished(let result) = run.phase else {
            Issue.record("run ended in \(run.phase)")
            return
        }
        #expect(result.maxGradeMeasured)
        #expect(result.calibration.maxGrade == 0.04)
        #expect(near(result.calibration.b, 735.75, 0.05 * 735))
    }

    @Test func unsteadyRidingRestartsTheSample() {
        var trainer = MockTrainer(seed: 2)
        var run = CalibrationRun(rider: rider)
        _ = trainer.handle(.requestControl)
        _ = run.start(at: 0)
        var time = 0.0
        while time < 30 { // settle (10 s) + one full sample window, wobbling throughout
            trainer.rider.cadence = 90 * (Int(time * 2).isMultiple(of: 2) ? 1.2 : 0.8)
            time += 0.5
            _ = run.handle(trainer.step(dt: 0.5), at: time)
        }
        #expect(run.stepIndex == 0)
        #expect(run.restarts >= 1)
        #expect(run.measurements.isEmpty)
    }

    @Test func skipAndCancel() {
        var run = CalibrationRun(rider: rider)
        #expect(run.start(at: 0) == run.steps[0].command)
        #expect(run.skipStep(at: 1) == run.steps[1].command)
        #expect(run.stepIndex == 1)
        run.cancel()
        #expect(run.phase == .cancelled)
        #expect(run.skipStep(at: 2) == nil)
    }

    @Test func tooFewMeasurementsFail() {
        var run = CalibrationRun(rider: rider)
        _ = run.start(at: 0)
        for t in 1...run.steps.count { _ = run.skipStep(at: Double(t)) }
        #expect(run.phase == .failed(.insufficientSamples(0)))
    }
}

@Suite("Bridge trainer override")
struct BridgeOverrideTests {
    @Test func overrideHoldsTrainerUntilCleared() {
        var bridge = BridgeCore(engine: .gradeOffset(profile: .standard, rider: RiderSetup.fiftySeventeen))
        _ = bridge.trainerDidConnect()
        _ = bridge.handleTrainerResponse(.init(to: .requestControl, result: .success), at: 0)
        _ = bridge.handleZwift(.requestControl, at: 0)

        let step = CalibrationStep(grade: 0.04, targetCadence: 90, targetSpeed: 9).command
        #expect(bridge.setTrainerOverride(step, at: 1) == [.sendToTrainer(step)])

        // Zwift is answered, but the trainer keeps the calibration grade.
        let road = SimulationParameters(windSpeed: 0, grade: 0.07, crr: 0.004, cw: 0.51)
        let out = bridge.handleZwift(.setIndoorBikeSimulation(road), at: 2)
        #expect(out.contains(.respondToZwift(.init(to: .setIndoorBikeSimulation(road), result: .success))))
        #expect(!out.contains { if case .sendToTrainer = $0 { true } else { false } })
        #expect(bridge.shift(.up, at: 3) == (.overridden, []))
        let data = IndoorBikeData(instantaneousSpeed: 30, instantaneousPower: 200)
        #expect(bridge.handleTrainerData(data, at: 4) == [.notifyZwiftData(data)])

        // A reconnect mid-calibration restores the calibration grade.
        _ = bridge.trainerDidConnect()
        #expect(bridge.handleTrainerResponse(.init(to: .requestControl, result: .success), at: 4.5)
            == [.sendToTrainer(.startOrResume), .sendToTrainer(step)])

        // Cleared: Zwift's latest road, through the engine, goes to the trainer.
        let restored = bridge.setTrainerOverride(nil, at: 5)
        #expect(restored.count == 1)
        #expect(bridge.lastEngineCommand?.parameters.crr == 0.004)
    }
}
