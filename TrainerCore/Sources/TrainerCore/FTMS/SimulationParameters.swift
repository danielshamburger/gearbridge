/// The four values of an FTMS "Set Indoor Bike Simulation Parameters" command,
/// in SI units.
///
/// Wire format (6 bytes, following opcode 0x11 or status 0x12):
/// wind speed sint16 (0.001 m/s), grade sint16 (0.01 %),
/// Crr uint8 (0.0001), Cw uint8 (0.01 kg/m).
public struct SimulationParameters: Equatable, Sendable, Codable {
    /// Wind speed in m/s. Positive is a headwind (adds drag), negative a tailwind.
    /// Zwift is expected to always send 0; confirm from packet logs.
    public var windSpeed: Double
    /// Road grade as a fraction: 0.05 is a 5 % climb.
    public var grade: Double
    /// Coefficient of rolling resistance.
    public var crr: Double
    /// Wind resistance coefficient in kg/m (0.5 · air density · CdA).
    /// Zwift lowers this to represent drafting.
    public var cw: Double

    public init(windSpeed: Double = 0, grade: Double = 0, crr: Double = 0, cw: Double = 0) {
        self.windSpeed = windSpeed
        self.grade = grade
        self.crr = crr
        self.cw = cw
    }

    public static let flat = SimulationParameters()

    /// These values rounded to what the wire format can carry.
    public var quantized: SimulationParameters {
        var w = ByteWriter()
        encodeFields(into: &w)
        var r = ByteReader(w.bytes)
        // Decoding bytes we just wrote cannot fail.
        return try! SimulationParameters(reading: &r)
    }

    init(reading r: inout ByteReader) throws {
        windSpeed = Double(try r.int16("windSpeed")) / 1000
        grade = Double(try r.int16("grade")) / 10000
        crr = Double(try r.uint8("crr")) / 10000
        cw = Double(try r.uint8("cw")) / 100
    }

    func encodeFields(into w: inout ByteWriter) {
        w.int16(quantize(windSpeed, scale: 1000))
        w.int16(quantize(grade, scale: 10000))
        w.uint8(quantize(crr, scale: 10000))
        w.uint8(quantize(cw, scale: 100))
    }
}
