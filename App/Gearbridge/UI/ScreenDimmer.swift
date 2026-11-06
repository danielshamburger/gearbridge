import UIKit

/// "Dim screen while riding": after `idleTime` without a touch, eases the
/// screen down to `dimLevel`; any touch brings it straight back.
///
/// Brightness is system-wide and outlives the app, so it's always put back:
/// on a touch, when the setting is turned off, when the ride screen goes
/// away, and when the app stops being active.
@MainActor
final class ScreenDimmer {
    static let idleTime: TimeInterval = 15
    static let dimLevel: CGFloat = 0.15

    /// Dimming allowed (the setting is on, and the ride screen is up and active).
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { touched() } else { wake(); countdown?.cancel(); countdown = nil }
        }
    }

    /// The brightness to go back to, while dimmed.
    private var savedBrightness: CGFloat?
    private var lastTouch = Date()
    private var countdown: Task<Void, Never>?
    private var fade: Task<Void, Never>?

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    /// Call on every touch. Cheap: called for each finger movement.
    func touched() {
        lastTouch = Date()
        wake()
        guard enabled, countdown == nil else { return }
        countdown = Task { [weak self] in
            // One wait per quiet spell, extended by touches, not a task per touch.
            while let self, !Task.isCancelled {
                let remaining = Self.idleTime - Date().timeIntervalSince(self.lastTouch)
                if remaining <= 0 {
                    self.countdown = nil
                    self.dim()
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    private func dim() {
        guard enabled, savedBrightness == nil, let screen else { return }
        let start = screen.brightness
        guard start > Self.dimLevel else { return } // already darker than this
        savedBrightness = start
        fade = Task { [weak self] in
            let steps = 20
            for step in 1...steps { // over about 0.6 s
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, let screen = self?.screen else { return }
                let t = CGFloat(step) / CGFloat(steps)
                screen.brightness = start + (Self.dimLevel - start) * t
            }
        }
    }

    private func wake() {
        fade?.cancel()
        fade = nil
        guard let saved = savedBrightness else { return }
        savedBrightness = nil
        screen?.brightness = saved
    }
}
