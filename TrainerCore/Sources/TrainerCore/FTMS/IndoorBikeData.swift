/// FTMS Indoor Bike Data characteristic (0x2AD2), sent as notifications.
///
/// Every field is optional; the leading 16-bit flags say which are present.
/// Values use FTMS-native units (km/h, rpm, W) so codecs round-trip exactly.
public struct IndoorBikeData: Equatable, Sendable {
    public struct ExpendedEnergy: Equatable, Sendable {
        /// kcal
        public var total: UInt16
        /// kcal per hour
        public var perHour: UInt16
        /// kcal per minute
        public var perMinute: UInt8

        public init(total: UInt16, perHour: UInt16, perMinute: UInt8) {
            self.total = total
            self.perHour = perHour
            self.perMinute = perMinute
        }
    }

    /// km/h, 0.01 resolution. Absent when the More Data flag is set.
    public var instantaneousSpeed: Double?
    /// km/h, 0.01 resolution.
    public var averageSpeed: Double?
    /// rpm, 0.5 resolution.
    public var instantaneousCadence: Double?
    /// rpm, 0.5 resolution.
    public var averageCadence: Double?
    /// metres, 24-bit.
    public var totalDistance: UInt32?
    /// Unitless.
    public var resistanceLevel: Int16?
    /// W.
    public var instantaneousPower: Int16?
    /// W.
    public var averagePower: Int16?
    public var expendedEnergy: ExpendedEnergy?
    /// bpm.
    public var heartRate: UInt8?
    /// 0.1 resolution.
    public var metabolicEquivalent: Double?
    /// seconds.
    public var elapsedTime: UInt16?
    /// seconds.
    public var remainingTime: UInt16?

    public init(
        instantaneousSpeed: Double? = nil,
        averageSpeed: Double? = nil,
        instantaneousCadence: Double? = nil,
        averageCadence: Double? = nil,
        totalDistance: UInt32? = nil,
        resistanceLevel: Int16? = nil,
        instantaneousPower: Int16? = nil,
        averagePower: Int16? = nil,
        expendedEnergy: ExpendedEnergy? = nil,
        heartRate: UInt8? = nil,
        metabolicEquivalent: Double? = nil,
        elapsedTime: UInt16? = nil,
        remainingTime: UInt16? = nil
    ) {
        self.instantaneousSpeed = instantaneousSpeed
        self.averageSpeed = averageSpeed
        self.instantaneousCadence = instantaneousCadence
        self.averageCadence = averageCadence
        self.totalDistance = totalDistance
        self.resistanceLevel = resistanceLevel
        self.instantaneousPower = instantaneousPower
        self.averagePower = averagePower
        self.expendedEnergy = expendedEnergy
        self.heartRate = heartRate
        self.metabolicEquivalent = metabolicEquivalent
        self.elapsedTime = elapsedTime
        self.remainingTime = remainingTime
    }

    /// Instantaneous speed in m/s.
    public var speedMetersPerSecond: Double? {
        instantaneousSpeed.map { $0 / 3.6 }
    }

    private enum Flag {
        /// Inverted: 0 means Instantaneous Speed IS present.
        static let moreData: UInt16 = 1 << 0
        static let averageSpeed: UInt16 = 1 << 1
        static let instantaneousCadence: UInt16 = 1 << 2
        static let averageCadence: UInt16 = 1 << 3
        static let totalDistance: UInt16 = 1 << 4
        static let resistanceLevel: UInt16 = 1 << 5
        static let instantaneousPower: UInt16 = 1 << 6
        static let averagePower: UInt16 = 1 << 7
        static let expendedEnergy: UInt16 = 1 << 8
        static let heartRate: UInt16 = 1 << 9
        static let metabolicEquivalent: UInt16 = 1 << 10
        static let elapsedTime: UInt16 = 1 << 11
        static let remainingTime: UInt16 = 1 << 12
    }

    /// Decodes a characteristic value. Trailing bytes beyond the flagged fields are ignored.
    public init(bytes: [UInt8]) throws {
        self.init()
        var r = ByteReader(bytes)
        let flags = try r.uint16("flags")
        func has(_ flag: UInt16) -> Bool { flags & flag != 0 }

        if !has(Flag.moreData) {
            instantaneousSpeed = Double(try r.uint16("instantaneousSpeed")) / 100
        }
        if has(Flag.averageSpeed) {
            averageSpeed = Double(try r.uint16("averageSpeed")) / 100
        }
        if has(Flag.instantaneousCadence) {
            instantaneousCadence = Double(try r.uint16("instantaneousCadence")) / 2
        }
        if has(Flag.averageCadence) {
            averageCadence = Double(try r.uint16("averageCadence")) / 2
        }
        if has(Flag.totalDistance) {
            totalDistance = try r.uint24("totalDistance")
        }
        if has(Flag.resistanceLevel) {
            resistanceLevel = try r.int16("resistanceLevel")
        }
        if has(Flag.instantaneousPower) {
            instantaneousPower = try r.int16("instantaneousPower")
        }
        if has(Flag.averagePower) {
            averagePower = try r.int16("averagePower")
        }
        if has(Flag.expendedEnergy) {
            expendedEnergy = ExpendedEnergy(
                total: try r.uint16("totalEnergy"),
                perHour: try r.uint16("energyPerHour"),
                perMinute: try r.uint8("energyPerMinute")
            )
        }
        if has(Flag.heartRate) {
            heartRate = try r.uint8("heartRate")
        }
        if has(Flag.metabolicEquivalent) {
            metabolicEquivalent = Double(try r.uint8("metabolicEquivalent")) / 10
        }
        if has(Flag.elapsedTime) {
            elapsedTime = try r.uint16("elapsedTime")
        }
        if has(Flag.remainingTime) {
            remainingTime = try r.uint16("remainingTime")
        }
    }

    /// Encodes as a characteristic value. A nil `instantaneousSpeed` sets the More Data flag.
    public func encoded() -> [UInt8] {
        var flags: UInt16 = 0
        var w = ByteWriter()

        if let v = instantaneousSpeed {
            w.uint16(quantize(v, scale: 100))
        } else {
            flags |= Flag.moreData
        }
        if let v = averageSpeed {
            flags |= Flag.averageSpeed
            w.uint16(quantize(v, scale: 100))
        }
        if let v = instantaneousCadence {
            flags |= Flag.instantaneousCadence
            w.uint16(quantize(v, scale: 2))
        }
        if let v = averageCadence {
            flags |= Flag.averageCadence
            w.uint16(quantize(v, scale: 2))
        }
        if let v = totalDistance {
            flags |= Flag.totalDistance
            w.uint24(min(v, 0xFF_FFFF))
        }
        if let v = resistanceLevel {
            flags |= Flag.resistanceLevel
            w.int16(v)
        }
        if let v = instantaneousPower {
            flags |= Flag.instantaneousPower
            w.int16(v)
        }
        if let v = averagePower {
            flags |= Flag.averagePower
            w.int16(v)
        }
        if let v = expendedEnergy {
            flags |= Flag.expendedEnergy
            w.uint16(v.total)
            w.uint16(v.perHour)
            w.uint8(v.perMinute)
        }
        if let v = heartRate {
            flags |= Flag.heartRate
            w.uint8(v)
        }
        if let v = metabolicEquivalent {
            flags |= Flag.metabolicEquivalent
            w.uint8(quantize(v, scale: 10))
        }
        if let v = elapsedTime {
            flags |= Flag.elapsedTime
            w.uint16(v)
        }
        if let v = remainingTime {
            flags |= Flag.remainingTime
            w.uint16(v)
        }

        var out = ByteWriter()
        out.uint16(flags)
        out.append(w.bytes)
        return out.bytes
    }
}
