import Foundation

/// Serializes writes to a trainer's Control Point. FTMS allows one request in
/// flight: the next goes out only after the trainer's response (or a timeout).
///
/// Queued setters with the same opcode are coalesced, so a burst of grade
/// updates while waiting collapses into the newest one.
public struct ControlPointQueue: Sendable {
    public struct InFlight: Equatable, Sendable {
        public var request: ControlPointRequest
        public var sentAt: TimeInterval
    }

    public var timeout: TimeInterval
    public private(set) var waiting: [ControlPointRequest] = []
    public private(set) var inFlight: InFlight?

    /// Short, because every shift waits behind an unanswered request.
    public init(timeout: TimeInterval = 1.0) {
        self.timeout = timeout
    }

    /// Adds a request. Returns it if it should be written now.
    public mutating func enqueue(_ request: ControlPointRequest, at time: TimeInterval) -> ControlPointRequest? {
        if let current = inFlight, time - current.sentAt >= timeout { inFlight = nil }
        if Self.isCoalescable(request), let i = waiting.firstIndex(where: { $0.opcode == request.opcode }) {
            waiting[i] = request
        } else {
            waiting.append(request)
        }
        return sendNextIfIdle(at: time)
    }

    /// Handles the trainer's response. Returns the next request to write, if any.
    public mutating func didReceive(_ response: ControlPointResponse, at time: TimeInterval) -> ControlPointRequest? {
        guard let current = inFlight, current.request.opcode == response.requestOpcode else { return nil }
        inFlight = nil
        return sendNextIfIdle(at: time)
    }

    /// Gives up on a request with no response after `timeout`. Returns the next to write.
    public mutating func checkTimeout(at time: TimeInterval) -> ControlPointRequest? {
        guard let current = inFlight, time - current.sentAt >= timeout else { return nil }
        inFlight = nil
        return sendNextIfIdle(at: time)
    }

    public mutating func reset() {
        waiting.removeAll()
        inFlight = nil
    }

    private mutating func sendNextIfIdle(at time: TimeInterval) -> ControlPointRequest? {
        guard inFlight == nil, !waiting.isEmpty else { return nil }
        let next = waiting.removeFirst()
        inFlight = InFlight(request: next, sentAt: time)
        return next
    }

    /// Setters where only the latest value matters.
    private static func isCoalescable(_ request: ControlPointRequest) -> Bool {
        switch request {
        case .setIndoorBikeSimulation, .setTargetPower, .setTargetResistanceLevel,
             .setTargetSpeed, .setTargetInclination, .setTargetedCadence:
            true
        default:
            false
        }
    }
}
