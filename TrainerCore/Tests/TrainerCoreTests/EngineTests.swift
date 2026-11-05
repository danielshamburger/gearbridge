import Testing
@testable import TrainerCore

/// The plan's worked example: 80 kg, 5 % climb, 85 rpm, real 50×17,
/// virtual 34×28, 2.1 m wheel, Crr 0.004, Cw 0.51.
enum WorkedExample {
    static let rider = RiderSetup(systemMass: 80, realChainring: 50, realCog: 17)
    static let context = EngineContext(rider: rider)
    static let virtualRatio = 34.0 / 28.0
    static let sim = SimulationParameters(windSpeed: 0, grade: 0.05, crr: 0.004, cw: 0.51)
    static let realSpeed = BikePhysics.speed(cadence: 85, ratio: rider.realRatio, wheelCircumference: 2.1)
    static let input = EngineInput(simulation: sim, realSpeed: realSpeed, virtualRatio: virtualRatio, gearIndex: 0)
}

func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
    abs(a - b) <= tolerance
}

@Suite("Physics")
struct PhysicsTests {
    @Test func workedExampleForces() {
        let vReal = WorkedExample.realSpeed
        let vVirtual = BikePhysics.speed(cadence: 85, ratio: WorkedExample.virtualRatio, wheelCircumference: 2.1)
        #expect(near(vReal, 8.75, 0.005))
        #expect(near(vVirtual, 3.61, 0.005))

        let f = BikePhysics.resistiveForce(mass: 80, speed: vVirtual, parameters: WorkedExample.sim)
        #expect(near(f, 49.0, 0.05))
        #expect(near(f * vVirtual, 177, 0.5))
    }

    @Test func windChangesDrag() {
        let still = BikePhysics.resistiveForce(mass: 80, speed: 10, parameters: .init(cw: 0.5))
        let head = BikePhysics.resistiveForce(mass: 80, speed: 10, parameters: .init(windSpeed: 3, cw: 0.5))
        let tail = BikePhysics.resistiveForce(mass: 80, speed: 10, parameters: .init(windSpeed: -3, cw: 0.5))
        let strongTail = BikePhysics.resistiveForce(mass: 80, speed: 2, parameters: .init(windSpeed: -5, cw: 0.5))
        #expect(head > still)
        #expect(tail < still)
        #expect(strongTail < 0) // wind faster than the rider pushes
    }

    @Test func cadenceAndSpeedAreInverse() {
        let v = BikePhysics.speed(cadence: 90, ratio: 2.5, wheelCircumference: 2.1)
        #expect(near(BikePhysics.cadence(speed: v, ratio: 2.5, wheelCircumference: 2.1), 90, 1e-9))
    }
}

@Suite("Strategy C: force scaling")
struct ForceScalingTests {
    let strategy = ForceScalingStrategy(calibration: .nominal(trainerMass: 75))

    @Test func workedExample() {
        let cmd = strategy.command(for: WorkedExample.input, context: WorkedExample.context)
        #expect(near(cmd.virtualSpeed, 3.61, 0.005))
        #expect(near(cmd.virtualForce!, 49.0, 0.05))
        #expect(near(cmd.realForce!, 20.2, 0.05))
        #expect(near(cmd.parameters.grade, 0.0275, 0.0003))
        #expect(cmd.limit == .none)
        // Real power equals virtual power.
        #expect(near(cmd.realForce! * WorkedExample.realSpeed, cmd.virtualForce! * cmd.virtualSpeed, 1e-9))
    }

    @Test func sendsOnlyAGrade() {
        let cmd = strategy.command(for: WorkedExample.input, context: WorkedExample.context)
        #expect(cmd.parameters.crr == 0)
        #expect(cmd.parameters.cw == 0)
        #expect(cmd.parameters.windSpeed == 0)
    }

    @Test func harderGearMeansMoreForce() {
        var input = WorkedExample.input
        let easy = strategy.command(for: input, context: WorkedExample.context)
        input.virtualRatio = 50.0 / 14.0
        let hard = strategy.command(for: input, context: WorkedExample.context)
        #expect(hard.realForce! > easy.realForce!)
        #expect(hard.parameters.grade > easy.parameters.grade)
    }

    @Test func draftingLowersResistance() {
        var input = WorkedExample.input
        input.simulation = .init(grade: 0, crr: 0.004, cw: 0.51)
        input.virtualRatio = 50.0 / 12.0
        let solo = strategy.command(for: input, context: WorkedExample.context)
        input.simulation.cw = 0.3
        let drafting = strategy.command(for: input, context: WorkedExample.context)
        #expect(drafting.parameters.grade < solo.parameters.grade)
    }

    @Test func clampsAtMaximumAndFlagsMaxed() {
        var input = WorkedExample.input
        input.simulation.grade = 0.15
        input.virtualRatio = 50.0 / 11.0
        let cmd = strategy.command(for: input, context: WorkedExample.context)
        #expect(cmd.parameters.grade == 0.10)
        #expect(cmd.isMaxed)
    }

    @Test func clampsAtMinimumOnDescents() {
        var input = WorkedExample.input
        input.simulation.grade = -0.08
        let cmd = strategy.command(for: input, context: WorkedExample.context)
        #expect(cmd.limit == .minimum)
        #expect(cmd.parameters.grade == 0) // nominal floor is the grade-0 force
    }

    @Test func gradeScaleSoftensClimbs() {
        let full = strategy.command(for: WorkedExample.input, context: WorkedExample.context)
        var half = WorkedExample.context
        half.gradeScale = 0.5
        let softened = strategy.command(for: WorkedExample.input, context: half)
        #expect(softened.parameters.grade < full.parameters.grade)
    }
}

@Suite("Strategy A: grade offset")
struct GradeOffsetTests {
    let strategy = GradeOffsetStrategy(neutralGearIndex: 5, gradePerGear: 0.01)

    @Test func neutralGearForwardsZwiftUnchanged() {
        var input = WorkedExample.input
        input.gearIndex = 5
        let cmd = strategy.command(for: input, context: WorkedExample.context)
        #expect(cmd.parameters == WorkedExample.sim)
    }

    @Test func eachGearAddsOffset() {
        var input = WorkedExample.input
        input.gearIndex = 7
        #expect(near(strategy.command(for: input, context: WorkedExample.context).parameters.grade, 0.07, 1e-12))
        input.gearIndex = 3
        #expect(near(strategy.command(for: input, context: WorkedExample.context).parameters.grade, 0.03, 1e-12))
    }

    @Test func clamps() {
        var input = WorkedExample.input
        input.gearIndex = 11
        let cmd = strategy.command(for: input, context: WorkedExample.context)
        #expect(cmd.parameters.grade == 0.10)
        #expect(cmd.isMaxed)
    }
}
