/// FTMS Fitness Machine Feature characteristic (0x2ACC): two little-endian
/// 32-bit bitfields. The virtual trainer should copy the Flux S's real values.
public struct FitnessMachineFeature: Equatable, Sendable {
    public struct MachineFeatures: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let averageSpeed = Self(rawValue: 1 << 0)
        public static let cadence = Self(rawValue: 1 << 1)
        public static let totalDistance = Self(rawValue: 1 << 2)
        public static let inclination = Self(rawValue: 1 << 3)
        public static let elevationGain = Self(rawValue: 1 << 4)
        public static let pace = Self(rawValue: 1 << 5)
        public static let stepCount = Self(rawValue: 1 << 6)
        public static let resistanceLevel = Self(rawValue: 1 << 7)
        public static let strideCount = Self(rawValue: 1 << 8)
        public static let expendedEnergy = Self(rawValue: 1 << 9)
        public static let heartRateMeasurement = Self(rawValue: 1 << 10)
        public static let metabolicEquivalent = Self(rawValue: 1 << 11)
        public static let elapsedTime = Self(rawValue: 1 << 12)
        public static let remainingTime = Self(rawValue: 1 << 13)
        public static let powerMeasurement = Self(rawValue: 1 << 14)
        public static let forceOnBeltAndPowerOutput = Self(rawValue: 1 << 15)
        public static let userDataRetention = Self(rawValue: 1 << 16)
    }

    public struct TargetSettingFeatures: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let speed = Self(rawValue: 1 << 0)
        public static let inclination = Self(rawValue: 1 << 1)
        public static let resistance = Self(rawValue: 1 << 2)
        public static let power = Self(rawValue: 1 << 3)
        public static let heartRate = Self(rawValue: 1 << 4)
        public static let expendedEnergy = Self(rawValue: 1 << 5)
        public static let stepNumber = Self(rawValue: 1 << 6)
        public static let strideNumber = Self(rawValue: 1 << 7)
        public static let distance = Self(rawValue: 1 << 8)
        public static let trainingTime = Self(rawValue: 1 << 9)
        public static let timeInTwoHeartRateZones = Self(rawValue: 1 << 10)
        public static let timeInThreeHeartRateZones = Self(rawValue: 1 << 11)
        public static let timeInFiveHeartRateZones = Self(rawValue: 1 << 12)
        public static let indoorBikeSimulation = Self(rawValue: 1 << 13)
        public static let wheelCircumference = Self(rawValue: 1 << 14)
        public static let spinDownControl = Self(rawValue: 1 << 15)
        public static let targetedCadence = Self(rawValue: 1 << 16)
    }

    public var machine: MachineFeatures
    public var targetSetting: TargetSettingFeatures

    public init(machine: MachineFeatures, targetSetting: TargetSettingFeatures) {
        self.machine = machine
        self.targetSetting = targetSetting
    }

    public init(bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        machine = MachineFeatures(rawValue: try r.uint32("machineFeatures"))
        targetSetting = TargetSettingFeatures(rawValue: try r.uint32("targetSettingFeatures"))
    }

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        w.uint32(machine.rawValue)
        w.uint32(targetSetting.rawValue)
        return w.bytes
    }
}

/// Supported Power Range characteristic (0x2AD8), in watts.
public struct SupportedPowerRange: Equatable, Sendable {
    public var minimum: Int16
    public var maximum: Int16
    public var increment: UInt16

    public init(minimum: Int16, maximum: Int16, increment: UInt16) {
        self.minimum = minimum
        self.maximum = maximum
        self.increment = increment
    }

    public init(bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        minimum = try r.int16("minimumPower")
        maximum = try r.int16("maximumPower")
        increment = try r.uint16("powerIncrement")
    }

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        w.int16(minimum)
        w.int16(maximum)
        w.uint16(increment)
        return w.bytes
    }
}

/// Supported Resistance Level Range characteristic (0x2AD6), unitless, 0.1 resolution.
public struct SupportedResistanceLevelRange: Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var increment: Double

    public init(minimum: Double, maximum: Double, increment: Double) {
        self.minimum = minimum
        self.maximum = maximum
        self.increment = increment
    }

    public init(bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        minimum = Double(try r.int16("minimumResistance")) / 10
        maximum = Double(try r.int16("maximumResistance")) / 10
        increment = Double(try r.uint16("resistanceIncrement")) / 10
    }

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        w.int16(quantize(minimum, scale: 10))
        w.int16(quantize(maximum, scale: 10))
        w.uint16(quantize(increment, scale: 10))
        return w.bytes
    }
}
