import Foundation
import TrainerCore

/// Where a link to Zwift stands.
enum ZwiftLinkState: Equatable {
    case stopped
    case starting
    case unavailable(String)
    case advertising
    case failed(String)
}

/// A way of showing up in Zwift as a trainer: Bluetooth today, Wi-Fi next.
@MainActor
protocol ZwiftLink: AnyObject {
    var state: ZwiftLinkState { get }
    /// Clients listening to Indoor Bike Data, i.e. Zwift actually connected.
    var subscriberCount: Int { get }
    var feature: FitnessMachineFeature { get set }
    var powerRange: SupportedPowerRange { get set }
    var resistanceRange: SupportedResistanceLevelRange { get set }

    var onControlPointWrite: (@MainActor ([UInt8]) -> Void)? { get set }
    var onChange: (@MainActor () -> Void)? { get set }
    var onLog: (@MainActor (String) -> Void)? { get set }

    func start()
    func stop()
    func notify(_ data: IndoorBikeData)
    func notify(_ machineStatus: FitnessMachineStatus)
    func indicate(_ response: ControlPointResponse)
}
