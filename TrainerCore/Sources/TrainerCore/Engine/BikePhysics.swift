import Foundation

public enum BikePhysics {
    public static let gravity = 9.81

    /// Force (N) resisting a bike at `speed` (m/s): slope + rolling + aerodynamic.
    ///
    /// Air speed is `speed + windSpeed`. The aero term keeps its sign, so a
    /// tailwind faster than the rider pushes instead of adding drag.
    public static func resistiveForce(
        mass: Double,
        speed: Double,
        parameters p: SimulationParameters
    ) -> Double {
        let theta = atan(p.grade)
        let slopeAndRolling = mass * gravity * (sin(theta) + p.crr * cos(theta))
        let airSpeed = speed + p.windSpeed
        return slopeAndRolling + p.cw * airSpeed * abs(airSpeed)
    }

    /// Road speed (m/s) for a cadence (rpm) in a gear.
    public static func speed(cadence: Double, ratio: Double, wheelCircumference: Double) -> Double {
        cadence / 60 * ratio * wheelCircumference
    }

    /// Cadence (rpm) for a road speed (m/s) in a gear.
    public static func cadence(speed: Double, ratio: Double, wheelCircumference: Double) -> Double {
        guard ratio > 0, wheelCircumference > 0 else { return 0 }
        return speed / (ratio * wheelCircumference) * 60
    }
}
