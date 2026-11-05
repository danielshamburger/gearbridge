import Testing
@testable import TrainerCore

@Suite("Calibration fit")
struct CalibrationFitTests {
    @Test func recoversExactModel() throws {
        var samples: [CalibrationSample] = []
        for grade in [0.0, 0.02, 0.04, 0.06] {
            for speed in [6.0, 8.0, 10.0] {
                let force = 3 + 735 * grade + 0.4 * speed
                samples.append(CalibrationSample(grade: grade, speed: speed, power: force * speed))
            }
        }
        let fit = try CalibrationFitter.fitForceModel(samples)
        #expect(near(fit.a, 3, 1e-6))
        #expect(near(fit.b, 735, 1e-6))
        #expect(near(fit.c, 0.4, 1e-6))
        #expect(fit.residualRMS < 1e-6)
        #expect(near(fit.rSquared, 1, 1e-9))
    }

    @Test func rejectsTooFewSamples() {
        let samples = [CalibrationSample(grade: 0, speed: 8, power: 50),
                       CalibrationSample(grade: 0.02, speed: 0.5, power: 10)]
        #expect(throws: CalibrationError.insufficientSamples(1)) {
            try CalibrationFitter.fitForceModel(samples)
        }
    }

    @Test func rejectsSingleSpeed() {
        let samples = [0.0, 0.02, 0.04, 0.06].map {
            CalibrationSample(grade: $0, speed: 8, power: (3 + 735 * $0) * 8)
        }
        #expect(throws: CalibrationError.degenerate) {
            try CalibrationFitter.fitForceModel(samples)
        }
    }

    @Test func detectsSaturation() {
        let points = [(0.0, 5.0), (0.02, 20.0), (0.04, 35.0), (0.06, 50.0), (0.08, 52.0), (0.10, 52.5)]
            .map { (grade: $0.0, force: $0.1) }
        #expect(CalibrationFitter.detectMaxGrade(points) == 0.06)
    }

    @Test func noSaturationReturnsHighestGrade() {
        let points = [(0.0, 5.0), (0.05, 40.0), (0.10, 75.0)].map { (grade: $0.0, force: $0.1) }
        #expect(CalibrationFitter.detectMaxGrade(points) == 0.10)
    }

    @Test func linearModelFit() {
        let model = LinearModel.fit([(x: 1, y: 3), (x: 2, y: 5), (x: 3, y: 7)])
        #expect(model == LinearModel(intercept: 1, slope: 2))
        #expect(LinearModel.fit([(x: 1, y: 3), (x: 1, y: 5)]) == nil)
    }

    @Test func minGradeComesFromFloor() {
        let cal = TrainerCalibration(a: 3, b: 735, c: 0.4, maxGrade: 0.1,
                                     floorForce: LinearModel(intercept: 2, slope: 0.3))
        // floor at 10 m/s = 5 N; a + c·v = 7 N, so the floor needs grade -2/735.
        #expect(near(cal.minGrade(speed: 10), -2.0 / 735, 1e-12))
        #expect(near(cal.force(grade: cal.grade(forForce: 40, speed: 8), speed: 8), 40, 1e-9))
    }
}

@Suite("Mock trainer")
struct MockTrainerTests {
    @Test func requiresControlBeforeCommands() {
        var trainer = MockTrainer()
        let sim = ControlPointRequest.setIndoorBikeSimulation(.init(grade: 0.05))
        #expect(trainer.handle(sim).result == .controlNotPermitted)
        #expect(trainer.handle(.requestControl).result == .success)
        #expect(trainer.handle(sim).result == .success)
        #expect(trainer.mode == .simulation(.init(grade: 0.05)))
    }

    @Test func resetDropsControl() {
        var trainer = MockTrainer()
        _ = trainer.handle(.requestControl)
        _ = trainer.handle(.reset)
        #expect(!trainer.hasControl)
        #expect(trainer.handle(.startOrResume).result == .controlNotPermitted)
    }

    @Test func unsupportedOpcodes() {
        var trainer = MockTrainer()
        _ = trainer.handle(.requestControl)
        #expect(trainer.handle(.setTargetSpeed(kmh: 30)).result == .opCodeNotSupported)
        #expect(trainer.handle(.unsupported(opcode: 0x42, parameters: [])).result == .opCodeNotSupported)
    }

    @Test func producesPlausibleData() throws {
        var trainer = MockTrainer()
        let data = trainer.step(dt: 0.5)
        let speed = try #require(data.speedMetersPerSecond)
        #expect(near(speed, 8.75, 0.5))
        #expect(data.instantaneousCadence != nil)
        #expect(try IndoorBikeData(bytes: data.encoded()).instantaneousPower == data.instantaneousPower)
    }

    @Test func steeperGradeMeansMorePower() {
        var trainer = MockTrainer()
        _ = trainer.handle(.requestControl)
        let flat = trainer.trainerForce(speed: 8)
        _ = trainer.handle(.setIndoorBikeSimulation(.init(grade: 0.05)))
        #expect(trainer.trainerForce(speed: 8) > flat)
    }

    @Test func ergHoldsTargetPower() {
        var trainer = MockTrainer()
        _ = trainer.handle(.requestControl)
        _ = trainer.handle(.setTargetPower(watts: 200))
        #expect(near(trainer.trainerForce(speed: 8) * 8, 200, 1e-9))
    }
}

/// Runs the plan's calibration routine against the mock, through encoded packets.
func calibrate(_ trainer: inout MockTrainer, grades: [Double], cadences: [Double]) throws -> (fit: CalibrationFit, samples: [CalibrationSample]) {
    _ = trainer.handle(.requestControl)
    var samples: [CalibrationSample] = []
    for grade in grades {
        let command = ControlPointRequest.setIndoorBikeSimulation(.init(grade: grade))
        _ = trainer.handle(try ControlPointRequest(bytes: command.encoded()))
        for cadence in cadences {
            trainer.rider.cadence = cadence
            for _ in 0..<20 {
                let data = try IndoorBikeData(bytes: trainer.step(dt: 0.5).encoded())
                samples.append(CalibrationSample(
                    grade: grade,
                    speed: data.speedMetersPerSecond!,
                    power: Double(data.instantaneousPower!)
                ))
            }
        }
    }
    return (try CalibrationFitter.fitForceModel(samples), samples)
}

@Suite("Calibration against the mock trainer")
struct MockCalibrationTests {
    @Test func fitRecoversHiddenCharacteristics() throws {
        var trainer = MockTrainer(seed: 42)
        let (fit, _) = try calibrate(&trainer, grades: [0, 0.02, 0.04, 0.06, 0.08, 0.10], cadences: [70, 90, 110])
        let ch = trainer.characteristics
        #expect(near(fit.b, ch.simulationMass * BikePhysics.gravity, 0.03 * 735))
        #expect(near(fit.a, ch.parasiticForce.intercept, 1.5))
        #expect(near(fit.c, ch.parasiticForce.slope, 0.2))
        #expect(fit.rSquared > 0.99)
    }

    @Test func detectsMockMaxGrade() throws {
        var characteristics = MockTrainer.Characteristics()
        characteristics.maxGrade = 0.06
        var trainer = MockTrainer(characteristics: characteristics, seed: 7)
        let (_, samples) = try calibrate(&trainer, grades: [0, 0.02, 0.04, 0.06, 0.08, 0.10], cadences: [90])

        let byGrade = Dictionary(grouping: samples, by: \.grade).map { grade, group in
            (grade: grade, force: group.map(\.force).reduce(0, +) / Double(group.count))
        }
        #expect(CalibrationFitter.detectMaxGrade(byGrade) == 0.06)
    }

    /// The core promise of strategy C: with a fitted calibration, the power the
    /// trainer actually demands matches the virtual bike's power.
    @Test(arguments: [0.0, 0.03, 0.05, 0.08])
    func strategyCKeepsRealPowerEqualToVirtual(zwiftGrade: Double) throws {
        var trainer = MockTrainer(seed: 3)
        let (fit, _) = try calibrate(&trainer, grades: [0, 0.02, 0.04, 0.06, 0.08, 0.10], cadences: [70, 90, 110])
        let calibration = fit.calibration(
            maxGrade: trainer.characteristics.maxGrade,
            floorForce: trainer.characteristics.floorForce,
            realCog: 17
        )
        let strategy = ForceScalingStrategy(calibration: calibration)
        let context = WorkedExample.context

        let realSpeed = BikePhysics.speed(cadence: 85, ratio: context.realRatio, wheelCircumference: 2.1)
        let input = EngineInput(
            simulation: .init(grade: zwiftGrade, crr: 0.004, cw: 0.51),
            realSpeed: realSpeed,
            virtualRatio: 34.0 / 28.0,
            gearIndex: 0
        )
        let command = strategy.command(for: input, context: context)
        #expect(command.limit != .maximum)

        _ = trainer.handle(.setIndoorBikeSimulation(command.parameters.quantized))
        let realPower = trainer.trainerForce(speed: realSpeed) * realSpeed
        let virtualPower = command.virtualForce! * command.virtualSpeed

        if command.limit == .minimum {
            // Flat in an easy gear asks for less than the trainer's minimum
            // resistance: the rider gets the floor, which is more than virtual.
            let floorPower = trainer.characteristics.floorForce.value(at: realSpeed) * realSpeed
            #expect(near(realPower, floorPower, 0.5))
            #expect(realPower > virtualPower)
        } else {
            #expect(near(realPower, virtualPower, max(0.02 * virtualPower, 2)))
        }
    }
}
