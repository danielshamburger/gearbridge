import Testing
@testable import TrainerCore

@Suite struct BackgroundRideGuardTests {
    let riding = IndoorBikeData(instantaneousCadence: 85, instantaneousPower: 200)
    let stopped = IndoorBikeData(instantaneousCadence: 0, instantaneousPower: 0)

    @Test func neverEndsInTheForeground() {
        var guardrail = BackgroundRideGuard(idleLimit: 600)
        guardrail.rideStarted(at: 0)
        #expect(!guardrail.shouldEndRide(at: 10_000))
    }

    @Test func endsAfterTheLimitInTheBackgroundWithoutPedalling() {
        var guardrail = BackgroundRideGuard(idleLimit: 600)
        guardrail.rideStarted(at: 0)
        guardrail.enteredBackground(at: 100)
        guardrail.observe(stopped, at: 300)
        #expect(!guardrail.shouldEndRide(at: 699))
        #expect(guardrail.shouldEndRide(at: 700))
    }

    @Test func pedallingInTheBackgroundKeepsTheRideGoing() {
        var guardrail = BackgroundRideGuard(idleLimit: 600)
        guardrail.rideStarted(at: 0)
        guardrail.enteredBackground(at: 0)
        guardrail.observe(riding, at: 3_000)          // locked, still racing
        #expect(!guardrail.shouldEndRide(at: 3_500))
        #expect(guardrail.shouldEndRide(at: 3_600))
    }

    @Test func eitherCadenceOrPowerCountsAsPedalling() {
        var guardrail = BackgroundRideGuard(idleLimit: 600)
        guardrail.enteredBackground(at: 0)
        guardrail.observe(IndoorBikeData(instantaneousCadence: 0, instantaneousPower: 150), at: 500)
        guardrail.observe(IndoorBikeData(instantaneousCadence: 40), at: 900)
        #expect(!guardrail.shouldEndRide(at: 1_400))
        #expect(guardrail.shouldEndRide(at: 1_500))
    }

    @Test func theClockStartsWhenTheAppLeavesTheForeground() {
        // Stopped for a while on screen, then locked: the full limit still applies.
        var guardrail = BackgroundRideGuard(idleLimit: 600)
        guardrail.rideStarted(at: 0)
        guardrail.enteredBackground(at: 590)
        #expect(!guardrail.shouldEndRide(at: 1_000))
        #expect(guardrail.shouldEndRide(at: 1_190))
    }

    @Test func comingBackRestartsTheClock() {
        var guardrail = BackgroundRideGuard(idleLimit: 600)
        guardrail.enteredBackground(at: 0)
        guardrail.becameActive(at: 500)
        guardrail.enteredBackground(at: 510)
        #expect(!guardrail.shouldEndRide(at: 1_000))
        #expect(guardrail.shouldEndRide(at: 1_110))
    }
}
