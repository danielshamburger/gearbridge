import Testing
@testable import TrainerCore

@Suite("Bridge with shifting engine")
struct ShiftingBridgeTests {
    static let rider = RiderSetup() // 50×17, ratio 2.94
    static let profile = GearProfile.standard // neutral (closest to 2.94) is 42×14 = 3.0, index 9

    /// Bridge with strategy A, trainer controlled and Zwift in control.
    func bridge(startingGear: Int = 9) throws -> BridgeCore {
        let profile = try GearProfile(
            name: "test",
            ratios: Self.profile.ratios,
            startingGearIndex: startingGear
        )
        var bridge = BridgeCore(engine: .gradeOffset(profile: profile, rider: Self.rider))
        _ = bridge.trainerDidConnect()
        _ = bridge.handleTrainerResponse(.init(to: .requestControl, result: .success), at: 0)
        _ = bridge.handleZwift(.requestControl, at: 0)
        return bridge
    }

    func sentGrades(_ outputs: [BridgeCore.Output]) -> [Double] {
        outputs.compactMap {
            if case .sendToTrainer(.setIndoorBikeSimulation(let p)) = $0 { p.grade } else { nil }
        }
    }

    let road = SimulationParameters(windSpeed: 0, grade: 0.05, crr: 0.004, cw: 0.51)
    let data = IndoorBikeData(instantaneousSpeed: 31.5, instantaneousCadence: 85, instantaneousPower: 200)

    @Test func neutralGearIsClosestToRealRatio() {
        let engine = ShiftingEngine.gradeOffset(profile: Self.profile, rider: Self.rider)
        guard case .gradeOffset(let a) = engine.strategy else { Issue.record("wrong strategy"); return }
        #expect(a.neutralGearIndex == 9)
    }

    @Test func zwiftGradeIsOffsetByGear() throws {
        var b = try bridge(startingGear: 7)
        let out = b.handleZwift(.setIndoorBikeSimulation(road), at: 1)
        #expect(out.first == .respondToZwift(.init(to: .setIndoorBikeSimulation(road), result: .success)))
        // Status echoes what Zwift asked for, not what the trainer got.
        #expect(out.contains(.notifyZwiftStatus(.indoorBikeSimulationParametersChanged(road))))
        let grades = sentGrades(out)
        #expect(grades.count == 1)
        #expect(near(grades[0], 0.03, 1e-9)) // 5 % − 2 gears × 1 %
        #expect(b.lastEngineCommand?.parameters.crr == 0.004)
    }

    @Test func shiftSendsNewGrade() throws {
        var b = try bridge()
        _ = b.handleZwift(.setIndoorBikeSimulation(road), at: 1)
        let (outcome, out) = b.shift(.up, at: 2)
        #expect(outcome == .shifted(toIndex: 10))
        #expect(sentGrades(out).count == 1)
        #expect(near(sentGrades(out)[0], 0.06, 1e-9))
    }

    @Test func shiftAtEndOfRangeDoesNothing() throws {
        var b = try bridge(startingGear: 0)
        let (outcome, out) = b.shift(.down, at: 1)
        #expect(outcome == .atLimit)
        #expect(out.isEmpty)
    }

    @Test func quickShiftIsDeferredNotDropped() throws {
        var b = try bridge()
        _ = b.handleZwift(.setIndoorBikeSimulation(road), at: 1)
        let (_, out) = b.shift(.up, at: 1.1) // inside the 0.25 s throttle window
        #expect(out.isEmpty)
        let later = b.handleTrainerData(data, at: 1.4)
        #expect(sentGrades(later).count == 1)
        #expect(near(sentGrades(later)[0], 0.06, 1e-9))
    }

    @Test func steadyDataDoesNotResend() throws {
        var b = try bridge()
        _ = b.handleZwift(.setIndoorBikeSimulation(road), at: 1)
        for t in stride(from: 1.5, to: 5, by: 0.5) {
            #expect(sentGrades(b.handleTrainerData(data, at: t)).isEmpty)
        }
    }

    @Test func ergIgnoresShiftsAndData() throws {
        var b = try bridge()
        let out = b.handleZwift(.setTargetPower(watts: 220), at: 1)
        #expect(out.contains(.sendToTrainer(.setTargetPower(watts: 220))))
        #expect(b.shift(.up, at: 2) == (.ignoredInERG, []))
        #expect(b.handleTrainerData(data, at: 3) == [.notifyZwiftData(data)])
        #expect(b.lastEngineCommand == nil)

        // Back to sim: the gear (unchanged) applies again immediately.
        let back = b.handleZwift(.setIndoorBikeSimulation(road), at: 4)
        #expect(sentGrades(back).count == 1)
        #expect(near(sentGrades(back)[0], 0.05, 1e-9))
    }

    @Test func idleUsesFlatRoadWithDrag() throws {
        var b = try bridge(startingGear: 10)
        let out = b.handleZwift(.reset, at: 1)
        #expect(out.contains(.sendToTrainer(.setIndoorBikeSimulation(
            SimulationParameters(windSpeed: 0, grade: 0.01, crr: 0.004, cw: 0.51)))))
    }

    @Test func noEngineMeansShiftingDisabled() {
        var b = BridgeCore()
        #expect(b.shift(.up, at: 0) == (.disabled, []))
    }

    @Test func turningEngineOffRestoresZwiftGrade() throws {
        var b = try bridge(startingGear: 11)
        _ = b.handleZwift(.setIndoorBikeSimulation(road), at: 1)
        #expect(b.setEngine(nil, at: 2) == [.sendToTrainer(.setIndoorBikeSimulation(road))])
    }

    @Test func powerCanBeLeftToAnotherSource() {
        var b = BridgeCore()
        b.reportsPower = false
        var full = data
        full.averagePower = 190
        var stripped = full
        stripped.instantaneousPower = nil
        stripped.averagePower = nil
        #expect(b.handleTrainerData(full) == [.notifyZwiftData(stripped)])

        let feature = BridgeCore.virtualFeature(copying: MockTrainer.feature, reportsPower: false)
        #expect(!feature.machine.contains(.powerMeasurement))
        #expect(feature.machine.contains(.cadence))
    }

    /// Bridge, strategy A and the mock trainer: harder gears mean more power
    /// at the same cadence, easier gears less.
    @Test func shiftingChangesMockPower() throws {
        var b = BridgeCore(engine: .gradeOffset(profile: Self.profile, rider: Self.rider))
        var trainer = MockTrainer(seed: 7)
        trainer.characteristics.powerNoise = 0
        var time = 0.0
        var pending = b.trainerDidConnect()

        func pump() throws {
            while !pending.isEmpty {
                if case .sendToTrainer(let request) = pending.removeFirst() {
                    let response = trainer.handle(try ControlPointRequest(bytes: request.encoded()))
                    pending += b.handleTrainerResponse(response, at: time)
                }
            }
        }
        func ride(seconds: Double) throws -> Int16 {
            var last: IndoorBikeData?
            for _ in 0..<Int(seconds / 0.25) {
                time += 0.25
                let d = trainer.step(dt: 0.25)
                pending += b.handleTrainerData(d, at: time)
                try pump()
                last = d
            }
            return last?.instantaneousPower ?? 0
        }

        try pump()
        pending += b.handleZwift(.requestControl, at: time)
        pending += b.handleZwift(.setIndoorBikeSimulation(.init(windSpeed: 0, grade: 0.02, crr: 0.004, cw: 0.51)), at: time)
        try pump()
        let start = try ride(seconds: 5)

        for _ in 0..<3 { pending += b.shift(.up, at: time).1; time += 0.3; try pump() }
        let harder = try ride(seconds: 5)

        for _ in 0..<6 { pending += b.shift(.down, at: time).1; time += 0.3; try pump() }
        let easier = try ride(seconds: 5)

        #expect(harder > start + 50)
        #expect(easier < start - 50)
    }
}
