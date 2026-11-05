import UIKit

/// A crisp tap for a shift, and a distinct double buzz when a shift is refused
/// (end of the cassette, ERG mode, shifting off).
@MainActor
final class ShiftHaptics {
    private let shift = UIImpactFeedbackGenerator(style: .rigid)
    private let refused = UINotificationFeedbackGenerator()

    init() {
        shift.prepare()
        refused.prepare()
    }

    func shifted() {
        shift.impactOccurred()
        shift.prepare()
    }

    func blocked() {
        refused.notificationOccurred(.warning)
        refused.prepare()
    }
}
