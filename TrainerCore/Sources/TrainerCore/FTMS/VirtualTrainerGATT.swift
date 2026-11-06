import Foundation

/// The values the virtual trainer serves when Zwift reads it, shared by every
/// way of reaching Zwift (Bluetooth, Wi-Fi) so they answer reads identically.
public struct VirtualTrainerGATT: Equatable, Sendable {
    public var feature: FitnessMachineFeature
    public var powerRange: SupportedPowerRange
    public var resistanceRange: SupportedResistanceLevelRange

    public init(
        feature: FitnessMachineFeature = BridgeCore.virtualFeature(copying: nil),
        powerRange: SupportedPowerRange = BridgeCore.defaultPowerRange,
        resistanceRange: SupportedResistanceLevelRange = BridgeCore.defaultResistanceRange
    ) {
        self.feature = feature
        self.powerRange = powerRange
        self.resistanceRange = resistanceRange
    }

    /// The bytes a read of the characteristic returns (short UUID, any case),
    /// or nil if it can't be read.
    public func readValue(forUUID uuid: String) -> [UInt8]? {
        switch uuid.uppercased() {
        case FTMSUUID.feature: feature.encoded()
        case FTMSUUID.supportedPowerRange: powerRange.encoded()
        case FTMSUUID.supportedResistanceLevelRange: resistanceRange.encoded()
        case FTMSUUID.trainingStatus: [0x00, 0x01] // no string, status "Idle"
        default: nil
        }
    }
}
