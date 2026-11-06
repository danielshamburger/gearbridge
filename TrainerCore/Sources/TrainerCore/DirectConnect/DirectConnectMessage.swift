import Foundation

/// One Wahoo Direct Connect message: a 6-byte header (version, message ID,
/// sequence number, response code, big-endian payload length) and a payload.
public struct DirectConnectMessage: Equatable, Sendable {
    public enum ID {
        public static let discoverServices: UInt8 = 0x01
        public static let discoverCharacteristics: UInt8 = 0x02
        public static let read: UInt8 = 0x03
        public static let write: UInt8 = 0x04
        public static let enableNotifications: UInt8 = 0x05
        public static let notification: UInt8 = 0x06
        public static let unknown07: UInt8 = 0x07
        public static let error: UInt8 = 0xFF
    }

    public enum ResponseCode {
        public static let success: UInt8 = 0x00
        public static let unknownMessageType: UInt8 = 0x01
        public static let unexpectedError: UInt8 = 0x02
        public static let serviceNotFound: UInt8 = 0x03
        public static let characteristicNotFound: UInt8 = 0x04
        public static let operationNotSupported: UInt8 = 0x05
        public static let writeFailed: UInt8 = 0x06
    }

    public static let version: UInt8 = 1
    public static let headerLength = 6

    public var id: UInt8
    public var sequence: UInt8
    public var responseCode: UInt8
    public var payload: [UInt8]

    public init(id: UInt8, sequence: UInt8, responseCode: UInt8 = ResponseCode.success, payload: [UInt8] = []) {
        self.id = id
        self.sequence = sequence
        self.responseCode = responseCode
        self.payload = payload
    }

    public func encoded() -> [UInt8] {
        let length = UInt16(truncatingIfNeeded: payload.count)
        return [Self.version, id, sequence, responseCode, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    // MARK: UUIDs

    private static let baseSuffix: [UInt8] = [
        0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB,
    ]

    /// The 16-byte form of a 16-bit Bluetooth UUID given as hex ("2AD2").
    public static func uuidBytes(short: String) -> [UInt8] {
        let value = UInt16(short, radix: 16) ?? 0
        return [0x00, 0x00, UInt8(value >> 8), UInt8(value & 0xFF)] + baseSuffix
    }

    /// The short hex form ("2AD2", upper case) of a 16-byte UUID, or nil if it
    /// isn't a 16-bit Bluetooth UUID.
    public static func shortUUID(from bytes: [UInt8]) -> String? {
        guard bytes.count == 16, bytes[0] == 0, bytes[1] == 0, Array(bytes[4...]) == baseSuffix else { return nil }
        return String(format: "%02X%02X", bytes[2], bytes[3])
    }
}

/// Splits the TCP byte stream into messages. Partial messages wait for the
/// next read; several messages in one read all come out.
public struct DirectConnectDecoder: Sendable {
    public enum DecodeError: Error, Equatable {
        case badVersion(UInt8)
    }

    private var buffer: [UInt8] = []

    public init() {}

    /// Adds bytes and returns every complete message. On a framing error the
    /// caller should close the connection.
    public mutating func feed(_ bytes: [UInt8]) throws -> [DirectConnectMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [DirectConnectMessage] = []
        while buffer.count >= DirectConnectMessage.headerLength {
            guard buffer[0] == DirectConnectMessage.version else {
                let version = buffer[0]
                buffer = []
                throw DecodeError.badVersion(version)
            }
            let length = Int(buffer[4]) << 8 | Int(buffer[5])
            let total = DirectConnectMessage.headerLength + length
            guard buffer.count >= total else { break }
            messages.append(DirectConnectMessage(
                id: buffer[1], sequence: buffer[2], responseCode: buffer[3],
                payload: Array(buffer[DirectConnectMessage.headerLength..<total])))
            buffer.removeFirst(total)
        }
        return messages
    }
}
