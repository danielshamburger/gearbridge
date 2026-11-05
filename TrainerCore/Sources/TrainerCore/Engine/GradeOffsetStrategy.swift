/// Strategy A: each gear away from neutral adds or removes a fixed grade.
/// Zwift's Crr, Cw and wind are forwarded unchanged.
///
/// Not physically accurate, but needs no calibration; built first to prove the loop.
public struct GradeOffsetStrategy: ShiftingStrategy {
    /// Gear index that adds no offset, usually the gear closest to the real ratio.
    public var neutralGearIndex: Int
    /// Grade added per gear, as a fraction (0.01 = 1 %).
    public var gradePerGear: Double
    public var minimumGrade: Double
    public var maximumGrade: Double

    public init(
        neutralGearIndex: Int,
        gradePerGear: Double = 0.01,
        minimumGrade: Double = -0.10,
        maximumGrade: Double = 0.10
    ) {
        self.neutralGearIndex = neutralGearIndex
        self.gradePerGear = gradePerGear
        self.minimumGrade = minimumGrade
        self.maximumGrade = maximumGrade
    }

    public func command(for input: EngineInput, context: EngineContext) -> TrainerCommand {
        let offset = Double(input.gearIndex - neutralGearIndex) * gradePerGear
        let (grade, limit) = clamp(
            input.simulation.grade * context.gradeScale + offset,
            min: minimumGrade,
            max: maximumGrade
        )
        var parameters = input.simulation
        parameters.grade = grade
        return TrainerCommand(
            parameters: parameters,
            limit: limit,
            virtualSpeed: virtualSpeed(input, context)
        )
    }
}
