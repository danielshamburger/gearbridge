/// Strategy C: keep the trainer in sim mode and scale its force so pedal torque
/// matches the virtual gear. Real power then equals virtual power.
///
///     v_virtual = v_real · R_virtual / R_real
///     F_virtual = m g (sin θ + Crr cos θ) + Cw (v_virtual + wind)|v_virtual + wind|
///     F_real    = F_virtual · R_virtual / R_real
///     grade_cmd = (F_real − a − c · v_real) / b       clamped to the trainer's limits
///
/// The trainer gets Crr = Cw = wind = 0 so its force is just the calibrated slope term.
/// Zwift's drafting arrives as a lower Cw and flows through F_virtual.
public struct ForceScalingStrategy: ShiftingStrategy {
    public var calibration: TrainerCalibration

    public init(calibration: TrainerCalibration) {
        self.calibration = calibration
    }

    public func command(for input: EngineInput, context: EngineContext) -> TrainerCommand {
        var sim = input.simulation
        sim.grade *= context.gradeScale

        let vReal = max(input.realSpeed, 0)
        let gearFactor = context.realRatio > 0 ? input.virtualRatio / context.realRatio : 1
        let vVirtual = vReal * gearFactor

        let fVirtual = BikePhysics.resistiveForce(mass: context.systemMass, speed: vVirtual, parameters: sim)
        let fReal = fVirtual * gearFactor

        let (grade, limit) = clamp(
            calibration.grade(forForce: fReal, speed: vReal),
            min: calibration.minGrade(speed: vReal),
            max: calibration.maxGrade
        )

        return TrainerCommand(
            parameters: SimulationParameters(windSpeed: 0, grade: grade, crr: 0, cw: 0),
            limit: limit,
            virtualSpeed: vVirtual,
            virtualForce: fVirtual,
            realForce: fReal
        )
    }
}
