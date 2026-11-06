import Foundation

/// How speeds are shown. Everything inside the bridge stays in km/h and m/s.
public enum SpeedUnit: String, CaseIterable, Identifiable, Sendable {
    case kilometers
    case miles

    public var id: Self { self }

    /// "km/h" or "mph".
    public var label: String {
        switch self {
        case .kilometers: "km/h"
        case .miles: "mph"
        }
    }

    /// Name for the settings picker.
    public var name: String {
        switch self {
        case .kilometers: "Kilometres"
        case .miles: "Miles"
        }
    }

    public static let kilometersPerMile = 1.609344

    /// A km/h value in this unit.
    public func fromKilometersPerHour(_ kmh: Double) -> Double {
        switch self {
        case .kilometers: kmh
        case .miles: kmh / Self.kilometersPerMile
        }
    }

    /// A m/s value in this unit.
    public func fromMetersPerSecond(_ mps: Double) -> Double {
        fromKilometersPerHour(mps * 3.6)
    }

    /// "34.6 km/h" / "21.5 mph", one decimal.
    public func format(kilometersPerHour kmh: Double) -> String {
        String(format: "%.1f %@", fromKilometersPerHour(kmh), label)
    }

    /// The device's preference: miles where the locale uses them.
    public static var localeDefault: SpeedUnit {
        Locale.current.measurementSystem == .us || Locale.current.measurementSystem == .uk ? .miles : .kilometers
    }
}
