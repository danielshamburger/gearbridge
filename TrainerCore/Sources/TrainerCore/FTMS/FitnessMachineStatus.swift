/// FTMS Fitness Machine Status characteristic (0x2ADA), sent as notifications
/// when the machine's state changes.
public enum FitnessMachineStatus: Equatable, Sendable {
    case reset
    case stoppedOrPausedByUser(StopOrPause)
    case stoppedBySafetyKey
    case startedOrResumedByUser
    case targetPowerChanged(watts: Int16)
    case indoorBikeSimulationParametersChanged(SimulationParameters)
    case wheelCircumferenceChanged(millimeters: Double)
    case controlPermissionLost
    /// Any status opcode this codec doesn't model (e.g. spin down status 0x14).
    case other(opcode: UInt8, parameters: [UInt8])

    public init(bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        let op = try r.uint8("statusOpcode")
        switch op {
        case 0x01: self = .reset
        case 0x02: self = .stoppedOrPausedByUser(StopOrPause(rawValue: try r.uint8("stopOrPause")))
        case 0x03: self = .stoppedBySafetyKey
        case 0x04: self = .startedOrResumedByUser
        case 0x08: self = .targetPowerChanged(watts: try r.int16("targetPower"))
        case 0x12: self = .indoorBikeSimulationParametersChanged(try SimulationParameters(reading: &r))
        case 0x13:
            self = .wheelCircumferenceChanged(millimeters: Double(try r.uint16("wheelCircumference")) / 10)
        case 0xFF: self = .controlPermissionLost
        default: self = .other(opcode: op, parameters: r.rest())
        }
    }

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .reset:
            w.uint8(0x01)
        case .stoppedOrPausedByUser(let control):
            w.uint8(0x02)
            w.uint8(control.rawValue)
        case .stoppedBySafetyKey:
            w.uint8(0x03)
        case .startedOrResumedByUser:
            w.uint8(0x04)
        case .targetPowerChanged(let watts):
            w.uint8(0x08)
            w.int16(watts)
        case .indoorBikeSimulationParametersChanged(let p):
            w.uint8(0x12)
            p.encodeFields(into: &w)
        case .wheelCircumferenceChanged(let mm):
            w.uint8(0x13)
            w.uint16(quantize(mm, scale: 10))
        case .controlPermissionLost:
            w.uint8(0xFF)
        case .other(let op, let parameters):
            w.uint8(op)
            w.append(parameters)
        }
        return w.bytes
    }
}
