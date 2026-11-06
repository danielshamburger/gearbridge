import Testing
@testable import TrainerCore

@Suite("Speed units")
struct SpeedUnitTests {
    @Test func conversions() {
        #expect(SpeedUnit.kilometers.fromKilometersPerHour(40) == 40)
        #expect(abs(SpeedUnit.miles.fromKilometersPerHour(1.609344) - 1) < 1e-12)
        #expect(abs(SpeedUnit.miles.fromKilometersPerHour(40) - 24.855) < 0.001)
        #expect(abs(SpeedUnit.kilometers.fromMetersPerSecond(10) - 36) < 1e-12)
        #expect(abs(SpeedUnit.miles.fromMetersPerSecond(10) - 22.369) < 0.001)
    }

    @Test func formatting() {
        #expect(SpeedUnit.kilometers.format(kilometersPerHour: 34.56) == "34.6 km/h")
        #expect(SpeedUnit.miles.format(kilometersPerHour: 34.56) == "21.5 mph")
    }
}
