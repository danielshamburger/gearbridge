import ActivityKit
import Foundation
import UIKit

/// Starts, updates and ends the ride's Live Activity (lock screen and Dynamic
/// Island). Updates are skipped when nothing the activity shows has changed.
///
/// `Activity` isn't Sendable, so this keeps only its id and looks the activity
/// up again inside each nonisolated async call.
@MainActor
final class RideActivityController {
    typealias State = RideActivityAttributes.ContentState

    private var activityID: String?
    private var lastState: State?
    private var lastPush = Date.distantPast
    private var terminateObserver: NSObjectProtocol?

    /// The activity is marked stale this long after the app last updated it,
    /// so a card left behind by a killed app stops offering dead buttons.
    /// `heartbeat()` pushes well inside this while the app is alive.
    private nonisolated static let staleAfter: TimeInterval = 90
    private static let heartbeatEvery: TimeInterval = 30

    init() {
        // A ride from a previous launch (the app was killed mid-ride) can leave
        // its activity behind; nothing will update it now.
        Task { await Self.endAll(except: nil) }
        // Swiping the app away: iOS gives a running app a moment here (not a
        // suspended one; the stale date covers that). End the activity before
        // the process goes, blocking briefly since the end call is async.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Self.endAllBlocking()
        }
    }

    func start(_ state: State) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(
                attributes: RideActivityAttributes(),
                content: Self.content(state),
                pushType: nil)
            activityID = activity.id
            lastState = state
            lastPush = Date()
        } catch {
            activityID = nil
        }
    }

    func update(_ state: State) {
        guard let activityID, state != lastState else { return }
        push(state, to: activityID)
    }

    /// Call about once a second during a ride: re-sends the current state when
    /// needed to push the stale date forward.
    func heartbeat() {
        guard let activityID, let lastState,
              Date().timeIntervalSince(lastPush) >= Self.heartbeatEvery else { return }
        push(lastState, to: activityID)
    }

    private func push(_ state: State, to id: String) {
        lastState = state
        lastPush = Date()
        let content = Self.content(state)
        Task { await Self.update(id: id, to: content) }
    }

    private nonisolated static func content(_ state: State) -> ActivityContent<State> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))
    }

    func end() {
        guard let activityID else { return }
        self.activityID = nil
        lastState = nil
        Task { await Self.end(id: activityID) }
    }

    private nonisolated static func update(id: String, to content: ActivityContent<State>) async {
        for activity in Activity<RideActivityAttributes>.activities where activity.id == id {
            await activity.update(content)
        }
    }

    private nonisolated static func end(id: String) async {
        for activity in Activity<RideActivityAttributes>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Ends every ride activity, waiting up to a second. Only for app termination.
    private nonisolated static func endAllBlocking() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await endAll(except: nil)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    private nonisolated static func endAll(except id: String?) async {
        for activity in Activity<RideActivityAttributes>.activities where activity.id != id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
