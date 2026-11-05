import Foundation
import Observation
import TrainerCore

enum TrainerSource: String, CaseIterable, Identifiable {
    case mock = "Mock"
    case bluetooth = "Flux S"

    var id: Self { self }
}

/// Wires the trainer link, the virtual trainer Zwift pairs to, `BridgeCore`
/// and the packet log together, and exposes state for the UI.
@MainActor
@Observable
final class BridgeController {
    static let advertisedName = "TrainerCtrl"

    var source: TrainerSource {
        didSet { if source != oldValue { connectTrainer() } }
    }

    var mockCadence: Double = 85 {
        didSet { (link as? MockTrainerLink)?.cadence = mockCadence }
    }

    private(set) var trainerState: TrainerLinkState = .idle
    private(set) var zwiftState: VirtualTrainerPeripheral.State = .starting
    private(set) var zwiftSubscribers = 0
    private(set) var latestData: IndoorBikeData?
    private(set) var zwiftMode: BridgeCore.ZwiftMode = .idle
    private(set) var logCount = 0

    @ObservationIgnored private var core = BridgeCore()
    @ObservationIgnored private var log = PacketLog()
    @ObservationIgnored private let peripheral = VirtualTrainerPeripheral(name: BridgeController.advertisedName)
    @ObservationIgnored private var link: TrainerLink?
    @ObservationIgnored private var logStart = Date()

    init(source: TrainerSource = .mock) {
        self.source = source
        peripheral.onControlPointWrite = { [weak self] bytes in self?.handleZwiftWrite(bytes) }
        peripheral.onChange = { [weak self] in
            guard let self else { return }
            self.zwiftState = self.peripheral.state
            self.zwiftSubscribers = self.peripheral.subscriberCount
        }
        peripheral.start()
        connectTrainer()
    }

    // MARK: Labels

    var zwiftLabel: String {
        switch zwiftState {
        case .starting: "Starting…"
        case .unavailable(let reason), .failed(let reason): reason
        case .advertising: zwiftSubscribers > 0 ? "Zwift connected" : "Waiting for Zwift to pair"
        }
    }

    var commandLabel: String {
        switch zwiftMode {
        case .idle: "None yet"
        case .simulation(let p): String(format: "Sim %.1f%%  Crr %.4f  Cw %.2f", p.grade * 100, p.crr, p.cw)
        case .targetPower(let w): "ERG \(w) W"
        }
    }

    // MARK: Packet log

    func writeLogFile() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trainerctrl-\(formatter.string(from: logStart)).csv")
        try log.csv().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func clearLog() {
        log.clear()
        logStart = Date()
        logCount = 0
    }

    private func record(_ direction: PacketLog.Direction, _ channel: String, _ bytes: [UInt8] = [], _ summary: String = "") {
        log.append(at: Date().timeIntervalSince(logStart), direction, channel, bytes: bytes, summary: summary)
        logCount = log.entries.count
    }

    // MARK: Trainer side

    private func connectTrainer() {
        link?.onEvent = nil
        link?.stop()
        core.trainerDidDisconnect()
        latestData = nil

        let newLink: TrainerLink
        switch source {
        case .mock:
            let mock = MockTrainerLink()
            mock.cadence = mockCadence
            newLink = mock
        case .bluetooth:
            newLink = FTMSTrainerLink()
        }
        newLink.onEvent = { [weak self] event in self?.handle(event) }
        link = newLink
        record(.event, "source", [], source.rawValue)
        newLink.start()
    }

    private func handle(_ event: TrainerLinkEvent) {
        switch event {
        case .state(let state):
            trainerState = state
            if !state.isConnected { core.trainerDidDisconnect() }
            record(.event, "trainerState", [], state.label)
        case .ready:
            perform(core.trainerDidConnect())
        case .data(let data, let raw):
            latestData = data
            record(.fromTrainer, FTMSUUID.indoorBikeData, raw, data.logSummary)
            perform(core.handleTrainerData(data))
        case .response(let response, let raw):
            record(.fromTrainer, FTMSUUID.controlPoint, raw, response.logSummary)
            perform(core.handleTrainerResponse(response))
        case .status(let status, let raw):
            record(.fromTrainer, FTMSUUID.status, raw, status.logSummary)
            perform(core.handleTrainerStatus(status))
        case .feature(let feature, let raw):
            record(.fromTrainer, FTMSUUID.feature, raw, "feature")
            peripheral.feature = BridgeCore.virtualFeature(copying: feature)
        case .powerRange(let range, let raw):
            record(.fromTrainer, FTMSUUID.supportedPowerRange, raw, "\(range.minimum)–\(range.maximum) W")
            peripheral.powerRange = range
        case .sent(let request, let raw):
            record(.toTrainer, FTMSUUID.controlPoint, raw, request.logSummary)
        case .decodeError(let channel, let raw, let message):
            record(.fromTrainer, channel, raw, "decode error: \(message)")
        }
    }

    // MARK: Zwift side

    private func handleZwiftWrite(_ bytes: [UInt8]) {
        let summary = (try? ControlPointRequest(bytes: bytes))?.logSummary ?? "malformed"
        record(.fromZwift, FTMSUUID.controlPoint, bytes, summary)
        perform(core.handleZwiftWrite(bytes))
        zwiftMode = core.zwiftMode
    }

    private func perform(_ outputs: [BridgeCore.Output]) {
        for output in outputs {
            switch output {
            case .respondToZwift(let response):
                peripheral.indicate(response)
                record(.toZwift, FTMSUUID.controlPoint, response.encoded(), response.logSummary)
            case .notifyZwiftStatus(let status):
                peripheral.notify(status)
                record(.toZwift, FTMSUUID.status, status.encoded(), status.logSummary)
            case .notifyZwiftData(let data):
                // Not logged: identical to the trainer packet already logged.
                peripheral.notify(data)
            case .sendToTrainer(let request):
                link?.send(request)
            }
        }
    }
}
