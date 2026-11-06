import Foundation
import Testing
@testable import TrainerCore

@Suite("Direct Connect")
struct DirectConnectTests {
    typealias Msg = DirectConnectMessage
    let gatt = VirtualTrainerGATT()

    func uuid(_ short: String) -> [UInt8] { Msg.uuidBytes(short: short) }

    @Test func roundTripEveryID() throws {
        for id: UInt8 in [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0xFF] {
            let message = Msg(id: id, sequence: 9, responseCode: 3, payload: [1, 2, 3])
            var decoder = DirectConnectDecoder()
            #expect(try decoder.feed(message.encoded()) == [message])
        }
    }

    @Test func lengthIsBigEndian() {
        let bytes = Msg(id: 3, sequence: 1, payload: [UInt8](repeating: 0, count: 258)).encoded()
        #expect(Array(bytes[0..<6]) == [1, 3, 1, 0, 1, 2])
    }

    @Test func splitAcrossReads() throws {
        let bytes = Msg(id: 3, sequence: 4, payload: [9, 8, 7]).encoded()
        var decoder = DirectConnectDecoder()
        #expect(try decoder.feed(Array(bytes[0..<4])).isEmpty)
        #expect(try decoder.feed(Array(bytes[4..<8])).isEmpty)
        #expect(try decoder.feed(Array(bytes[8...])).count == 1)
    }

    @Test func twoInOneRead() throws {
        let a = Msg(id: 1, sequence: 1), b = Msg(id: 7, sequence: 2)
        var decoder = DirectConnectDecoder()
        #expect(try decoder.feed(a.encoded() + b.encoded()) == [a, b])
    }

    @Test func badVersionThrows() {
        var decoder = DirectConnectDecoder()
        #expect(throws: DirectConnectDecoder.DecodeError.badVersion(2)) {
            try decoder.feed([2, 1, 0, 0, 0, 0])
        }
    }

    @Test func uuidLayout() {
        #expect(uuid("2AD2") == [0, 0, 0x2A, 0xD2, 0, 0, 0x10, 0, 0x80, 0, 0, 0x80, 0x5F, 0x9B, 0x34, 0xFB])
        #expect(Msg.shortUUID(from: uuid("2AD2")) == "2AD2")
        #expect(Msg.shortUUID(from: [UInt8](repeating: 1, count: 16)) == nil)
    }

    @Test func discoverServicesReturnsOnlyFTMS() {
        var session = DirectConnectSession()
        let r = session.handle(Msg(id: 1, sequence: 5), gatt: gatt)
        #expect(r.replies == [Msg(id: 1, sequence: 5, payload: uuid("1826"))])
    }

    @Test func discoverCharacteristics() {
        var session = DirectConnectSession()
        let r = session.handle(Msg(id: 2, sequence: 6, payload: uuid("1826")), gatt: gatt)
        let payload = r.replies[0].payload
        #expect(Array(payload[0..<16]) == uuid("1826"))
        #expect(payload.count == 16 + 7 * 17)
        let flags = Dictionary(uniqueKeysWithValues: stride(from: 16, to: payload.count, by: 17).map {
            (Msg.shortUUID(from: Array(payload[$0..<$0 + 16]))!, payload[$0 + 16])
        })
        #expect(flags == ["2ACC": 0x01, "2AD2": 0x04, "2AD3": 0x05, "2AD6": 0x01, "2AD8": 0x01, "2AD9": 0x0A, "2ADA": 0x04])
    }

    @Test func unknownServiceIs03() {
        var session = DirectConnectSession()
        let r = session.handle(Msg(id: 2, sequence: 1, payload: uuid("180D")), gatt: gatt)
        #expect(r.replies == [Msg(id: 2, sequence: 1, responseCode: 0x03)])
    }

    @Test func readFeature() {
        var session = DirectConnectSession()
        let r = session.handle(Msg(id: 3, sequence: 2, payload: uuid("2ACC")), gatt: gatt)
        #expect(r.replies[0].payload == uuid("2ACC") + gatt.feature.encoded())
    }

    @Test func readUnknownIs04AndNonReadableIs05() {
        var session = DirectConnectSession()
        #expect(session.handle(Msg(id: 3, sequence: 1, payload: uuid("2A00")), gatt: gatt).replies[0].responseCode == 0x04)
        #expect(session.handle(Msg(id: 3, sequence: 1, payload: uuid("2AD2")), gatt: gatt).replies[0].responseCode == 0x05)
    }

    @Test func controlPointWrite() {
        var session = DirectConnectSession()
        let r = session.handle(Msg(id: 4, sequence: 3, payload: uuid("2AD9") + [0x00]), gatt: gatt)
        #expect(r.controlPointWrite == [0x00])
        #expect(r.replies == [Msg(id: 4, sequence: 3, payload: uuid("2AD9"))])
    }

    @Test func writeToBikeDataIs05() {
        var session = DirectConnectSession()
        let r = session.handle(Msg(id: 4, sequence: 3, payload: uuid("2AD2") + [1]), gatt: gatt)
        #expect(r.controlPointWrite == nil)
        #expect(r.replies[0].responseCode == 0x05)
    }

    @Test func notificationsFollowSubscription() {
        var session = DirectConnectSession()
        #expect(session.push(uuid: "2AD2", value: [1]) == nil)
        let on = session.handle(Msg(id: 5, sequence: 1, payload: uuid("2AD2") + [1]), gatt: gatt)
        #expect(on.replies == [Msg(id: 5, sequence: 1, payload: uuid("2AD2"))])
        #expect(session.isSubscribedToBikeData)
        #expect(session.push(uuid: "2AD2", value: [1, 2]) == Msg(id: 6, sequence: 0, payload: uuid("2AD2") + [1, 2]))
        _ = session.handle(Msg(id: 5, sequence: 2, payload: uuid("2AD2") + [0]), gatt: gatt)
        #expect(session.push(uuid: "2AD2", value: [1]) == nil)
        #expect(!session.isSubscribedToBikeData)
    }

    @Test func controlPointResponseReachesUnsubscribedClient() {
        let session = DirectConnectSession()
        #expect(session.push(uuid: "2AD9", value: [0x80, 0, 1]) != nil)
        #expect(session.push(uuid: "2ADA", value: [1]) == nil)
    }

    @Test func type07AndUnknownIDs() {
        var session = DirectConnectSession()
        #expect(session.handle(Msg(id: 7, sequence: 8), gatt: gatt).replies == [Msg(id: 7, sequence: 8)])
        #expect(session.handle(Msg(id: 0x42, sequence: 8), gatt: gatt).replies == [Msg(id: 0x42, sequence: 8, responseCode: 0x01)])
    }
}
