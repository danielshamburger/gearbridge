import AppIntents

/// A shift from the lock screen or the Dynamic Island.
///
/// As a `LiveActivityIntent`, iOS runs `perform()` in the app's process (waking
/// it in the background if needed), not in the widget extension, so it can
/// reach the bridge through `ShiftRouter`.
struct ShiftIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Shift"
    static let description = IntentDescription("Shift to a harder or easier virtual gear.")
    static let isDiscoverable = false
    /// Run from the lock screen without unlocking the phone first. Without
    /// this, iOS asks for Face ID or the passcode before it runs the shift.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// True for a harder gear, false for an easier one.
    @Parameter(title: "Harder") var harder: Bool

    init() { harder = true }
    init(harder: Bool) { self.harder = harder }

    func perform() async throws -> some IntentResult {
        await ShiftRouter.shift(harder: harder)
        return .result()
    }
}

/// Where `ShiftIntent` delivers its shift. The app sets the handler at launch;
/// in the widget extension it stays nil.
@MainActor
enum ShiftRouter {
    static var handler: ((_ harder: Bool) -> Void)?

    static func shift(harder: Bool) {
        handler?(harder)
    }
}
