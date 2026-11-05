import TrainerCore

enum TrainerLinkState: Equatable {
    case idle
    case bluetoothUnavailable(String)
    case scanning
    case connecting(String)
    case connected(String)
    /// Lost the trainer; reconnecting automatically.
    case disconnected(String)

    var label: String {
        switch self {
        case .idle: "Stopped"
        case .bluetoothUnavailable(let reason): reason
        case .scanning: "Searching…"
        case .connecting(let name): "Connecting to \(name)…"
        case .connected(let name): "Connected: \(name)"
        case .disconnected(let name): "Lost \(name), reconnecting…"
        }
    }

    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }
}

enum TrainerLinkEvent {
    case state(TrainerLinkState)
    /// Control Point subscribed: the bridge may take control now.
    case ready
    case data(IndoorBikeData, raw: [UInt8])
    case response(ControlPointResponse, raw: [UInt8])
    case status(FitnessMachineStatus, raw: [UInt8])
    case feature(FitnessMachineFeature, raw: [UInt8])
    case powerRange(SupportedPowerRange, raw: [UInt8])
    case sent(ControlPointRequest, raw: [UInt8])
    case decodeError(channel: String, raw: [UInt8], message: String)
}

/// Upstream connection to a trainer: real (Bluetooth) or mock.
@MainActor
protocol TrainerLink: AnyObject {
    var onEvent: (@MainActor (TrainerLinkEvent) -> Void)? { get set }
    func start()
    func stop()
    func send(_ request: ControlPointRequest)
}
