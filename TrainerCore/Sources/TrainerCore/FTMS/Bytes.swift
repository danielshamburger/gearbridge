/// Errors raised while decoding FTMS characteristic values.
public enum FTMSDecodingError: Error, Equatable, Sendable {
    /// The value ended before `field` could be read.
    case truncated(field: String, needed: Int, remaining: Int)
    /// The first byte was not the opcode this decoder expects.
    case unexpectedOpcode(UInt8)
    /// A field held a value the spec doesn't define.
    case invalidValue(field: String, value: UInt8)
}

/// Little-endian reader over a characteristic value, as used throughout FTMS.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    private mutating func take(_ count: Int, _ field: String) throws -> ArraySlice<UInt8> {
        guard remaining >= count else {
            throw FTMSDecodingError.truncated(field: field, needed: count, remaining: remaining)
        }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        return slice
    }

    mutating func uint8(_ field: String) throws -> UInt8 {
        try take(1, field).first!
    }

    mutating func uint16(_ field: String) throws -> UInt16 {
        let s = try take(2, field)
        return UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8
    }

    mutating func int16(_ field: String) throws -> Int16 {
        Int16(bitPattern: try uint16(field))
    }

    mutating func uint24(_ field: String) throws -> UInt32 {
        let s = try take(3, field)
        return UInt32(s[s.startIndex])
            | UInt32(s[s.startIndex + 1]) << 8
            | UInt32(s[s.startIndex + 2]) << 16
    }

    mutating func uint32(_ field: String) throws -> UInt32 {
        let s = try take(4, field)
        return UInt32(s[s.startIndex])
            | UInt32(s[s.startIndex + 1]) << 8
            | UInt32(s[s.startIndex + 2]) << 16
            | UInt32(s[s.startIndex + 3]) << 24
    }

    mutating func rest() -> [UInt8] {
        let tail = Array(bytes[offset...])
        offset = bytes.count
        return tail
    }
}

/// Little-endian writer for FTMS characteristic values.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func uint8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func uint16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func int16(_ value: Int16) {
        uint16(UInt16(bitPattern: value))
    }

    mutating func uint24(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    }

    mutating func uint32(_ value: UInt32) {
        uint24(value)
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func append(_ more: [UInt8]) {
        bytes.append(contentsOf: more)
    }
}

/// Converts a physical value to a wire integer: multiply by `scale`, round,
/// and saturate at the integer type's limits (non-finite values become 0).
func quantize<T: FixedWidthInteger>(_ value: Double, scale: Double, as _: T.Type = T.self) -> T {
    let scaled = (value * scale).rounded()
    guard scaled.isFinite else { return 0 }
    if scaled <= Double(T.min) { return T.min }
    if scaled >= Double(T.max) { return T.max }
    return T(scaled)
}
