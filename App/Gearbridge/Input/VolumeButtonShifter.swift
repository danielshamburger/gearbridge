import AVFoundation
import MediaPlayer
import SwiftUI
import TrainerCore

/// Turns the iPhone's volume buttons into shift buttons: up = harder gear,
/// down = easier. Holding a button repeats at the system's key-repeat rate.
///
/// iOS has no public API for the buttons, so this uses the common workaround:
/// watch the audio session's output volume, and after each press put the
/// volume back where it was through a hidden `MPVolumeView`. The hidden view
/// also stops the system volume HUD from appearing. Media volume is unchanged
/// overall, but each press briefly nudges it.
@MainActor
final class VolumeButtonShifter: NSObject {
    var onShift: (@MainActor (Gearbox.Direction) -> Void)?

    /// Placed in the view hierarchy by `VolumeButtonHost`.
    let volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01 // hidden views don't suppress the HUD; nearly transparent ones do
        view.isUserInteractionEnabled = false
        return view
    }()

    private var observation: NSKeyValueObservation?
    private var activeObserver: NSObjectProtocol?
    /// The volume we restore after each press, away from 0 and 1 so both buttons register.
    private var baseline: Float = 0.5
    private var isRestoring = false
    /// Set by start/stop; checked when an asynchronous activation finishes.
    private var wantsRunning = false

    /// Audio session calls can block, so they run here rather than on the main thread.
    private nonisolated static let audioQueue = DispatchQueue(label: "Gearbridge.audioSession")

    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        Self.setSessionActive(true) { [weak self] in self?.beginObserving() }
        // Other apps can deactivate our session; reclaim it when we come back.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Self.setSessionActive(true)
        }
    }

    func stop() {
        guard wantsRunning else { return }
        wantsRunning = false
        observation?.invalidate()
        observation = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        isRestoring = false
        Self.setSessionActive(false)
    }

    /// Runs once the session is active (outputVolume is only live then).
    private func beginObserving() {
        guard wantsRunning, observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        baseline = min(max(session.outputVolume, 0.1), 0.9)
        if baseline != session.outputVolume { setVolume(baseline) }

        observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            guard let new = change.newValue, let old = change.oldValue else { return }
            Task { @MainActor in self?.volumeChanged(from: old, to: new) }
        }
    }

    private nonisolated static func setSessionActive(
        _ active: Bool,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        audioQueue.async {
            let session = AVAudioSession.sharedInstance()
            if active {
                // Ambient + mix: doesn't interrupt music or podcasts. Set once,
                // since changing category while active is itself slow.
                if session.category != .ambient || session.categoryOptions != .mixWithOthers {
                    try? session.setCategory(.ambient, options: [.mixWithOthers])
                }
                try? session.setActive(true)
            } else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            if let completion {
                Task { @MainActor in completion() }
            }
        }
    }

    private func volumeChanged(from old: Float, to new: Float) {
        // Our own restore lands back on the baseline: not a press.
        if isRestoring, abs(new - baseline) < 0.001 {
            isRestoring = false
            return
        }
        guard abs(new - old) > 0.001 else { return }
        onShift?(new > old ? .up : .down)
        setVolume(baseline)
    }

    private func setVolume(_ value: Float) {
        guard let slider else { return }
        isRestoring = true
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }
}

/// Puts the shifter's volume view on screen (it must be in a window to work).
struct VolumeButtonHost: UIViewRepresentable {
    let shifter: VolumeButtonShifter

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isUserInteractionEnabled = false
        container.addSubview(shifter.volumeView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
