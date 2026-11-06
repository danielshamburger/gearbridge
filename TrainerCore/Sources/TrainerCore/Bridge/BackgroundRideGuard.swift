import Foundation

/// Decides when a ride left running in the background should end on its own,
/// so Bluetooth isn't kept busy for an app nobody is using.
///
/// The app keeps the trainer and Zwift connected while it's in the background
/// (the phone locked mid-ride, say). But once it's been in the background with
/// no pedalling for `idleLimit`, the ride is over: the rider forgot to end it.
/// The clock restarts whenever the app comes to the foreground, so a ride is
/// never ended while someone is looking at it.
public struct BackgroundRideGuard: Sendable {
    public static let defaultIdleLimit: TimeInterval = 10 * 60

    public let idleLimit: TimeInterval
    public private(set) var inBackground = false
    /// The later of: last pedal stroke, ride start, last time in the foreground.
    public private(set) var lastActivity: TimeInterval = 0

    public init(idleLimit: TimeInterval = BackgroundRideGuard.defaultIdleLimit) {
        self.idleLimit = idleLimit
    }

    public mutating func rideStarted(at time: TimeInterval) {
        lastActivity = time
    }

    public mutating func enteredBackground(at time: TimeInterval) {
        inBackground = true
        lastActivity = max(lastActivity, time)
    }

    public mutating func becameActive(at time: TimeInterval) {
        inBackground = false
        lastActivity = max(lastActivity, time)
    }

    /// Feed every trainer data packet; any cadence or power counts as riding.
    public mutating func observe(_ data: IndoorBikeData, at time: TimeInterval) {
        if Self.isPedalling(data) { lastActivity = max(lastActivity, time) }
    }

    /// True once the app has been in the background and idle for `idleLimit`.
    public func shouldEndRide(at time: TimeInterval) -> Bool {
        inBackground && time - lastActivity >= idleLimit
    }

    static func isPedalling(_ data: IndoorBikeData) -> Bool {
        (data.instantaneousCadence ?? 0) > 0 || (data.instantaneousPower ?? 0) > 0
    }
}
