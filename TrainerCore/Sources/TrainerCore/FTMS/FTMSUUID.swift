/// 16-bit Bluetooth SIG UUIDs for the Fitness Machine Service.
///
/// Plain strings so this package stays free of CoreBluetooth; the BLE layer
/// wraps them in `CBUUID(string:)`.
public enum FTMSUUID {
    public static let service = "1826"
    public static let feature = "2ACC"
    public static let indoorBikeData = "2AD2"
    public static let trainingStatus = "2AD3"
    public static let supportedResistanceLevelRange = "2AD6"
    public static let supportedPowerRange = "2AD8"
    public static let controlPoint = "2AD9"
    public static let status = "2ADA"
}
