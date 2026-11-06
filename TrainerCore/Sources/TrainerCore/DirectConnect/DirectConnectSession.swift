import Foundation

/// One connected Direct Connect client (Zwift). Pure protocol logic: no
/// networking. Feed it the client's messages and send what it returns.
public struct DirectConnectSession: Sendable {
    public struct Characteristic: Sendable {
        public let uuid: String
        public let properties: UInt8
    }

    public enum Property {
        public static let read: UInt8 = 0x01
        public static let write: UInt8 = 0x02
        public static let notify: UInt8 = 0x04
        public static let indicate: UInt8 = 0x08
    }

    /// What the app serves: the same characteristics as the Bluetooth service.
    public static let characteristics: [Characteristic] = [
        Characteristic(uuid: FTMSUUID.feature, properties: Property.read),
        Characteristic(uuid: FTMSUUID.indoorBikeData, properties: Property.notify),
        Characteristic(uuid: FTMSUUID.trainingStatus, properties: Property.read | Property.notify),
        Characteristic(uuid: FTMSUUID.supportedResistanceLevelRange, properties: Property.read),
        Characteristic(uuid: FTMSUUID.supportedPowerRange, properties: Property.read),
        Characteristic(uuid: FTMSUUID.controlPoint, properties: Property.write | Property.indicate),
        Characteristic(uuid: FTMSUUID.status, properties: Property.notify),
    ]

    public struct Result: Equatable, Sendable {
        public var replies: [DirectConnectMessage] = []
        /// A write to the Control Point, to hand to the bridge.
        public var controlPointWrite: [UInt8]?
        /// The client turned notifications on or off for this characteristic.
        public var subscriptionChanged: (uuid: String, enabled: Bool)?

        public static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.replies == rhs.replies && lhs.controlPointWrite == rhs.controlPointWrite
                && lhs.subscriptionChanged?.uuid == rhs.subscriptionChanged?.uuid
                && lhs.subscriptionChanged?.enabled == rhs.subscriptionChanged?.enabled
        }
    }

    public private(set) var subscriptions: Set<String> = []

    /// Zwift is actually listening: it enabled Indoor Bike Data.
    public var isSubscribedToBikeData: Bool { subscriptions.contains(FTMSUUID.indoorBikeData) }

    public init() {}

    private static func characteristic(_ uuid: String) -> Characteristic? {
        characteristics.first { $0.uuid == uuid }
    }

    private func reply(to request: DirectConnectMessage, code: UInt8 = DirectConnectMessage.ResponseCode.success,
                       payload: [UInt8] = []) -> DirectConnectMessage {
        DirectConnectMessage(id: request.id, sequence: request.sequence, responseCode: code, payload: payload)
    }

    public mutating func handle(_ message: DirectConnectMessage, gatt: VirtualTrainerGATT) -> Result {
        typealias Code = DirectConnectMessage.ResponseCode
        var result = Result()
        func fail(_ code: UInt8) -> Result { Result(replies: [reply(to: message, code: code)]) }

        switch message.id {
        case DirectConnectMessage.ID.discoverServices:
            result.replies = [reply(to: message, payload: DirectConnectMessage.uuidBytes(short: FTMSUUID.service))]

        case DirectConnectMessage.ID.discoverCharacteristics:
            guard message.payload.count >= 16 else { return fail(Code.unexpectedError) }
            let serviceBytes = Array(message.payload[0..<16])
            guard DirectConnectMessage.shortUUID(from: serviceBytes) == FTMSUUID.service else {
                return fail(Code.serviceNotFound)
            }
            var payload = serviceBytes
            for characteristic in Self.characteristics {
                payload += DirectConnectMessage.uuidBytes(short: characteristic.uuid) + [characteristic.properties]
            }
            result.replies = [reply(to: message, payload: payload)]

        case DirectConnectMessage.ID.read:
            guard message.payload.count >= 16 else { return fail(Code.unexpectedError) }
            let uuidBytes = Array(message.payload[0..<16])
            guard let uuid = DirectConnectMessage.shortUUID(from: uuidBytes), let characteristic = Self.characteristic(uuid) else {
                return fail(Code.characteristicNotFound)
            }
            guard characteristic.properties & Property.read != 0, let value = gatt.readValue(forUUID: uuid) else {
                return fail(Code.operationNotSupported)
            }
            result.replies = [reply(to: message, payload: uuidBytes + value)]

        case DirectConnectMessage.ID.write:
            guard message.payload.count >= 16 else { return fail(Code.unexpectedError) }
            let uuidBytes = Array(message.payload[0..<16])
            guard let uuid = DirectConnectMessage.shortUUID(from: uuidBytes), let characteristic = Self.characteristic(uuid) else {
                return fail(Code.characteristicNotFound)
            }
            guard characteristic.properties & Property.write != 0 else { return fail(Code.operationNotSupported) }
            result.controlPointWrite = Array(message.payload[16...])
            result.replies = [reply(to: message, payload: uuidBytes)]

        case DirectConnectMessage.ID.enableNotifications:
            guard message.payload.count >= 17 else { return fail(Code.unexpectedError) }
            let uuidBytes = Array(message.payload[0..<16])
            guard let uuid = DirectConnectMessage.shortUUID(from: uuidBytes), let characteristic = Self.characteristic(uuid) else {
                return fail(Code.characteristicNotFound)
            }
            guard characteristic.properties & (Property.notify | Property.indicate) != 0 else {
                return fail(Code.operationNotSupported)
            }
            let enabled = message.payload[16] != 0
            if enabled { subscriptions.insert(uuid) } else { subscriptions.remove(uuid) }
            result.subscriptionChanged = (uuid, enabled)
            result.replies = [reply(to: message, payload: uuidBytes)]

        case DirectConnectMessage.ID.unknown07:
            result.replies = [reply(to: message)]

        default:
            return fail(Code.unknownMessageType)
        }
        return result
    }

    /// The unsolicited notification to send this client for a value the app
    /// pushes, or nil if the client shouldn't get it. Control Point responses
    /// always go out: Zwift doesn't always enable notifications on it, and
    /// pairing never finishes without the Request Control response.
    public func push(uuid: String, value: [UInt8]) -> DirectConnectMessage? {
        guard uuid == FTMSUUID.controlPoint || subscriptions.contains(uuid) else { return nil }
        return DirectConnectMessage(
            id: DirectConnectMessage.ID.notification, sequence: 0,
            payload: DirectConnectMessage.uuidBytes(short: uuid) + value)
    }
}
