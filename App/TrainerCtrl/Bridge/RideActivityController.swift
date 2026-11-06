import ActivityKit
import Foundation

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

    init() {
        // A ride from a previous launch (the app was killed mid-ride) can leave
        // its activity behind; nothing will update it now.
        Task { await Self.endAll(except: nil) }
    }

    func start(_ state: State) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(
                attributes: RideActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            activityID = activity.id
            lastState = state
        } catch {
            activityID = nil
        }
    }

    func update(_ state: State) {
        guard let activityID, state != lastState else { return }
        lastState = state
        Task { await Self.update(id: activityID, to: state) }
    }

    func end() {
        guard let activityID else { return }
        self.activityID = nil
        lastState = nil
        Task { await Self.end(id: activityID) }
    }

    private nonisolated static func update(id: String, to state: State) async {
        for activity in Activity<RideActivityAttributes>.activities where activity.id == id {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private nonisolated static func end(id: String) async {
        for activity in Activity<RideActivityAttributes>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func endAll(except id: String?) async {
        for activity in Activity<RideActivityAttributes>.activities where activity.id != id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
