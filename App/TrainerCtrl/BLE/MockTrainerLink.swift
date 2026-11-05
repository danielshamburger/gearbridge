import Foundation
import TrainerCore

/// Drives `MockTrainer` on a timer so the app and Zwift pairing work without the bike.
@MainActor
final class MockTrainerLink: TrainerLink {
    var onEvent: (@MainActor (TrainerLinkEvent) -> Void)?

    var cadence: Double {
        get { trainer.rider.cadence }
        set { trainer.rider.cadence = newValue }
    }

    /// The mock rider's chain position; keep it the same as the app's real gear.
    var realGear: (chainring: Int, cog: Int) {
        get { (trainer.rider.chainring, trainer.rider.cog) }
        set {
            trainer.rider.chainring = newValue.chainring
            trainer.rider.cog = newValue.cog
        }
    }

    private var trainer = MockTrainer(seed: UInt64.random(in: 1...UInt64.max))
    private var task: Task<Void, Never>?
    private let interval: TimeInterval = 0.5
    private let name = "Mock trainer"

    func start() {
        guard task == nil else { return }
        onEvent?(.state(.connected(name)))
        let feature = MockTrainer.feature
        onEvent?(.feature(feature, raw: feature.encoded()))
        let range = MockTrainer.powerRange
        onEvent?(.powerRange(range, raw: range.encoded()))
        onEvent?(.ready)

        task = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                self?.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        onEvent?(.state(.idle))
    }

    func send(_ request: ControlPointRequest) {
        let raw = request.encoded()
        onEvent?(.sent(request, raw: raw))
        // Answer asynchronously, like a real trainer, so callers never re-enter.
        Task { [weak self] in
            guard let self, self.task != nil else { return }
            let decoded = (try? ControlPointRequest(bytes: raw)) ?? request
            let response = self.trainer.handle(decoded)
            self.onEvent?(.response(response, raw: response.encoded()))
        }
    }

    private func tick() {
        let data = trainer.step(dt: interval)
        onEvent?(.data(data, raw: data.encoded()))
    }
}
