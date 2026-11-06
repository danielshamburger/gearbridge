import Foundation
import Network
import TrainerCore

/// The Wi-Fi way of showing up in Zwift: Wahoo's Direct Connect protocol over
/// TCP, found through Bonjour. The trainer side still runs over Bluetooth.
///
/// Network callbacks run on the main queue, so replies and pushes go out with
/// no extra hop.
@MainActor
final class DirectConnectServer: ZwiftLink {
    static let serviceType = "_wahoo-fitness-tnp._tcp"
    static let preferredPort: NWEndpoint.Port = 36866

    private let name: String
    private let defaults: UserDefaults

    var onControlPointWrite: (@MainActor ([UInt8]) -> Void)?
    var onChange: (@MainActor () -> Void)?
    var onLog: (@MainActor (String) -> Void)?

    private var gatt = VirtualTrainerGATT()
    var feature: FitnessMachineFeature { get { gatt.feature } set { gatt.feature = newValue } }
    var powerRange: SupportedPowerRange { get { gatt.powerRange } set { gatt.powerRange = newValue } }
    var resistanceRange: SupportedResistanceLevelRange { get { gatt.resistanceRange } set { gatt.resistanceRange = newValue } }

    private(set) var state: ZwiftLinkState = .stopped { didSet { if state != oldValue { onChange?() } } }
    private(set) var subscriberCount = 0 { didSet { if subscriberCount != oldValue { onChange?() } } }

    private var wantsRunning = false
    private var listener: NWListener?
    private var pathMonitor: NWPathMonitor?
    private var onWiFi = false
    private var clients: [ObjectIdentifier: Client] = [:]

    init(name: String, defaults: UserDefaults = .standard) {
        self.name = name
        self.defaults = defaults
    }

    // MARK: ZwiftLink

    func start() {
        wantsRunning = true
        guard pathMonitor == nil else { return } // already running
        state = .starting
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            MainActor.assumeIsolated { self?.wifiChanged(satisfied) }
        }
        pathMonitor = monitor
        monitor.start(queue: .main)
    }

    func stop() {
        wantsRunning = false
        pathMonitor?.cancel()
        pathMonitor = nil
        tearDown()
        state = .stopped
    }

    func notify(_ data: IndoorBikeData) { push(FTMSUUID.indoorBikeData, data.encoded()) }
    func notify(_ machineStatus: FitnessMachineStatus) { push(FTMSUUID.status, machineStatus.encoded()) }
    func indicate(_ response: ControlPointResponse) { push(FTMSUUID.controlPoint, response.encoded()) }

    // MARK: Listener

    private func wifiChanged(_ satisfied: Bool) {
        onWiFi = satisfied
        guard wantsRunning else { return }
        if satisfied {
            if listener == nil { startListener() }
        } else {
            onLog?("not on Wi-Fi")
            tearDown()
            state = .unavailable("Not on Wi-Fi")
        }
    }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // small packets go out at once
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let listener: NWListener
        do {
            // Real Wahoo devices use this port; fall back to any free one.
            listener = try (try? NWListener(using: parameters, on: Self.preferredPort)) ?? NWListener(using: parameters)
        } catch {
            state = .failed("Wi-Fi listener failed: \(error.localizedDescription)")
            return
        }
        listener.service = NWListener.Service(
            name: name, type: Self.serviceType,
            txtRecord: NWTXTRecord([
                "ble-service-uuids": "0x\(FTMSUUID.service)",
                "mac-address": identity(key: "directConnect.mac", make: Self.randomMAC),
                "serial-number": identity(key: "directConnect.serial", make: Self.randomSerial),
            ]))
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                self.listenerChanged(newState, port: listener.port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func listenerChanged(_ newState: NWListener.State, port: NWEndpoint.Port?) {
        switch newState {
        case .ready:
            onLog?("listening on port \(port?.rawValue ?? 0) as \(name)")
            state = .advertising
        case .waiting(let error), .failed(let error):
            onLog?("listener \(newState): \(error)")
            if Self.isLocalNetworkDenied(error) {
                state = .unavailable("Local network access is off. Allow it in the Settings app.")
            } else if case .failed = newState {
                state = .failed("Wi-Fi listener failed: \(error.localizedDescription)")
            } else {
                state = .unavailable("Wi-Fi isn't ready")
            }
        default:
            break
        }
    }

    private static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 } // kDNSServiceErr_PolicyDenied
        return false
    }

    private func tearDown() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for client in clients.values { client.close() }
        clients = [:]
        subscriberCount = 0
    }

    // MARK: Clients

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        let id = ObjectIdentifier(client)
        clients[id] = client
        onLog?("client connected: \(connection.endpoint)")
        client.onMessages = { [weak self] client, messages in self?.handle(messages, from: client) }
        client.onClosed = { [weak self] client, reason in
            guard let self, self.clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
            self.onLog?("client disconnected: \(reason)")
            self.updateSubscriberCount()
        }
        client.start()
    }

    private func handle(_ messages: [DirectConnectMessage], from client: Client) {
        for message in messages {
            let result = client.session.handle(message, gatt: gatt)
            for reply in result.replies { client.send(reply, isBikeData: false) }
            if let change = result.subscriptionChanged {
                onLog?("\(change.enabled ? "subscribe" : "unsubscribe") \(change.uuid)")
                updateSubscriberCount()
            }
            if let write = result.controlPointWrite { onControlPointWrite?(write) }
        }
    }

    private func updateSubscriberCount() {
        subscriberCount = clients.values.filter { $0.session.isSubscribedToBikeData }.count
    }

    private func push(_ uuid: String, _ value: [UInt8]) {
        for client in clients.values {
            if let message = client.session.push(uuid: uuid, value: value) {
                client.send(message, isBikeData: uuid == FTMSUUID.indoorBikeData)
            }
        }
    }

    // MARK: Identity

    private func identity(key: String, make: () -> String) -> String {
        if let saved = defaults.string(forKey: key) { return saved }
        let value = make()
        defaults.set(value, forKey: key)
        return value
    }

    /// `02` in the first byte marks a locally administered address.
    private static func randomMAC() -> String {
        let rest = (0..<5).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }
        return (["02"] + rest).joined(separator: ":")
    }

    private static func randomSerial() -> String {
        String((0..<8).map { _ in "0123456789ABCDEF".randomElement()! })
    }
}

/// One connected Zwift: its socket, session and send queue.
@MainActor
private final class Client {
    let connection: NWConnection
    var session = DirectConnectSession()
    var onMessages: (@MainActor (Client, [DirectConnectMessage]) -> Void)?
    var onClosed: (@MainActor (Client, String) -> Void)?

    private var decoder = DirectConnectDecoder()
    private var queue: [(message: DirectConnectMessage, isBikeData: Bool)] = []
    private var sending = false
    private var closed = false

    init(connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let error): self?.finish("failed: \(error)")
                case .cancelled: self?.finish("closed")
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        closed = true
        onClosed = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// One send at a time. While one is in flight only the newest bike data
    /// waits: a backlog would reach Zwift late. Replies and other pushes keep order.
    func send(_ message: DirectConnectMessage, isBikeData: Bool) {
        guard !closed else { return }
        if isBikeData { queue.removeAll { $0.isBikeData } }
        queue.append((message, isBikeData))
        flush()
    }

    private func flush() {
        guard !sending, !closed, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        sending = true
        connection.send(content: Data(next.message.encoded()), completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sending = false
                if let error { self.finish("send failed: \(error)") } else { self.flush() }
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    do {
                        let messages = try self.decoder.feed([UInt8](data))
                        if !messages.isEmpty { self.onMessages?(self, messages) }
                    } catch {
                        self.finish("bad data: \(error)")
                        return
                    }
                }
                if let error { self.finish("receive failed: \(error)") }
                else if isComplete { self.finish("closed by Zwift") }
                else { self.receive() }
            }
        }
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?(self, reason)
    }
}
