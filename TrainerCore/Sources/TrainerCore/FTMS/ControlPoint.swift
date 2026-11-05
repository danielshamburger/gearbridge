/// FTMS Fitness Machine Control Point (0x2AD9) opcodes.
public enum ControlPointOpcode: UInt8, Sendable {
    case requestControl = 0x00
    case reset = 0x01
    case setTargetSpeed = 0x02
    case setTargetInclination = 0x03
    case setTargetResistanceLevel = 0x04
    case setTargetPower = 0x05
    case setTargetHeartRate = 0x06
    case startOrResume = 0x07
    case stopOrPause = 0x08
    case setIndoorBikeSimulation = 0x11
    case setWheelCircumference = 0x12
    case spinDownControl = 0x13
    case setTargetedCadence = 0x14
    case responseCode = 0x80
}

public enum StopOrPause: Equatable, Sendable {
    case stop
    case pause
    case other(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .stop
        case 0x02: self = .pause
        default: self = .other(rawValue)
        }
    }

    var rawValue: UInt8 {
        switch self {
        case .stop: 0x01
        case .pause: 0x02
        case .other(let v): v
        }
    }
}

public enum SpinDownControl: Equatable, Sendable {
    case start
    case ignore
    case other(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .start
        case 0x02: self = .ignore
        default: self = .other(rawValue)
        }
    }

    var rawValue: UInt8 {
        switch self {
        case .start: 0x01
        case .ignore: 0x02
        case .other(let v): v
        }
    }
}

/// A command written to the Control Point by a client (Zwift, or this app to the trainer).
public enum ControlPointRequest: Equatable, Sendable {
    case requestControl
    case reset
    /// km/h, 0.01 resolution.
    case setTargetSpeed(kmh: Double)
    /// percent, 0.1 resolution.
    case setTargetInclination(percent: Double)
    /// unitless, 0.1 resolution.
    case setTargetResistanceLevel(Double)
    case setTargetPower(watts: Int16)
    case setTargetHeartRate(bpm: UInt8)
    case startOrResume
    case stopOrPause(StopOrPause)
    case setIndoorBikeSimulation(SimulationParameters)
    /// millimetres, 0.1 resolution.
    case setWheelCircumference(millimeters: Double)
    case spinDownControl(SpinDownControl)
    /// rpm, 0.5 resolution.
    case setTargetedCadence(rpm: Double)
    /// Any opcode this codec doesn't model. The bridge answers it with Op Code Not Supported.
    case unsupported(opcode: UInt8, parameters: [UInt8])

    public var opcode: UInt8 {
        switch self {
        case .requestControl: ControlPointOpcode.requestControl.rawValue
        case .reset: ControlPointOpcode.reset.rawValue
        case .setTargetSpeed: ControlPointOpcode.setTargetSpeed.rawValue
        case .setTargetInclination: ControlPointOpcode.setTargetInclination.rawValue
        case .setTargetResistanceLevel: ControlPointOpcode.setTargetResistanceLevel.rawValue
        case .setTargetPower: ControlPointOpcode.setTargetPower.rawValue
        case .setTargetHeartRate: ControlPointOpcode.setTargetHeartRate.rawValue
        case .startOrResume: ControlPointOpcode.startOrResume.rawValue
        case .stopOrPause: ControlPointOpcode.stopOrPause.rawValue
        case .setIndoorBikeSimulation: ControlPointOpcode.setIndoorBikeSimulation.rawValue
        case .setWheelCircumference: ControlPointOpcode.setWheelCircumference.rawValue
        case .spinDownControl: ControlPointOpcode.spinDownControl.rawValue
        case .setTargetedCadence: ControlPointOpcode.setTargetedCadence.rawValue
        case .unsupported(let op, _): op
        }
    }

    public init(bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        let op = try r.uint8("opcode")
        switch ControlPointOpcode(rawValue: op) {
        case .requestControl:
            self = .requestControl
        case .reset:
            self = .reset
        case .setTargetSpeed:
            self = .setTargetSpeed(kmh: Double(try r.uint16("targetSpeed")) / 100)
        case .setTargetInclination:
            self = .setTargetInclination(percent: Double(try r.int16("targetInclination")) / 10)
        case .setTargetResistanceLevel:
            self = .setTargetResistanceLevel(Double(try r.uint8("targetResistanceLevel")) / 10)
        case .setTargetPower:
            self = .setTargetPower(watts: try r.int16("targetPower"))
        case .setTargetHeartRate:
            self = .setTargetHeartRate(bpm: try r.uint8("targetHeartRate"))
        case .startOrResume:
            self = .startOrResume
        case .stopOrPause:
            self = .stopOrPause(StopOrPause(rawValue: try r.uint8("stopOrPause")))
        case .setIndoorBikeSimulation:
            self = .setIndoorBikeSimulation(try SimulationParameters(reading: &r))
        case .setWheelCircumference:
            self = .setWheelCircumference(millimeters: Double(try r.uint16("wheelCircumference")) / 10)
        case .spinDownControl:
            self = .spinDownControl(SpinDownControl(rawValue: try r.uint8("spinDownControl")))
        case .setTargetedCadence:
            self = .setTargetedCadence(rpm: Double(try r.uint16("targetedCadence")) / 2)
        case .responseCode, nil:
            self = .unsupported(opcode: op, parameters: r.rest())
        }
    }

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        w.uint8(opcode)
        switch self {
        case .requestControl, .reset, .startOrResume:
            break
        case .setTargetSpeed(let kmh):
            w.uint16(quantize(kmh, scale: 100))
        case .setTargetInclination(let percent):
            w.int16(quantize(percent, scale: 10))
        case .setTargetResistanceLevel(let level):
            w.uint8(quantize(level, scale: 10))
        case .setTargetPower(let watts):
            w.int16(watts)
        case .setTargetHeartRate(let bpm):
            w.uint8(bpm)
        case .stopOrPause(let control):
            w.uint8(control.rawValue)
        case .setIndoorBikeSimulation(let p):
            p.encodeFields(into: &w)
        case .setWheelCircumference(let mm):
            w.uint16(quantize(mm, scale: 10))
        case .spinDownControl(let control):
            w.uint8(control.rawValue)
        case .setTargetedCadence(let rpm):
            w.uint16(quantize(rpm, scale: 2))
        case .unsupported(_, let parameters):
            w.append(parameters)
        }
        return w.bytes
    }
}

/// The indication a server sends back on the Control Point after each request.
/// Format: 0x80, request opcode, result code, optional response parameters.
public struct ControlPointResponse: Equatable, Sendable {
    public enum Result: UInt8, Sendable {
        case success = 0x01
        case opCodeNotSupported = 0x02
        case invalidParameter = 0x03
        case operationFailed = 0x04
        case controlNotPermitted = 0x05
    }

    public var requestOpcode: UInt8
    public var result: Result
    public var parameters: [UInt8]

    public init(requestOpcode: UInt8, result: Result, parameters: [UInt8] = []) {
        self.requestOpcode = requestOpcode
        self.result = result
        self.parameters = parameters
    }

    public init(to request: ControlPointRequest, result: Result, parameters: [UInt8] = []) {
        self.init(requestOpcode: request.opcode, result: result, parameters: parameters)
    }

    public init(bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        let op = try r.uint8("responseOpcode")
        guard op == ControlPointOpcode.responseCode.rawValue else {
            throw FTMSDecodingError.unexpectedOpcode(op)
        }
        requestOpcode = try r.uint8("requestOpcode")
        let raw = try r.uint8("result")
        guard let result = Result(rawValue: raw) else {
            throw FTMSDecodingError.invalidValue(field: "result", value: raw)
        }
        self.result = result
        parameters = r.rest()
    }

    public func encoded() -> [UInt8] {
        [ControlPointOpcode.responseCode.rawValue, requestOpcode, result.rawValue] + parameters
    }
}
