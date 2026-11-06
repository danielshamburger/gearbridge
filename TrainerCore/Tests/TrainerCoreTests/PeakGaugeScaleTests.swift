import Testing
@testable import TrainerCore

@Suite("Peak gauge scale")
struct PeakGaugeScaleTests {
    /// Readings 0.25 s apart, as from the trainer.
    func feed(_ s: inout PeakGaugeScale, _ values: [Double]) {
        for (i, v) in values.enumerated() { s.observe(v, at: Double(i) * 0.25) }
    }

    @Test func startsAtFloor() {
        #expect(PeakGaugeScale.power.upperBound == 300)
        #expect(PeakGaugeScale.speed.upperBound == 40)
    }

    @Test func countsEachPlausibleReadingAtOnce() {
        var s = PeakGaugeScale.power
        feed(&s, [200, 380, 512, 300])
        #expect(s.peak == 512)          // one reading is enough
        #expect(s.upperBound == 550)
    }

    @Test func realSprintJumpCounts() {
        var s = PeakGaugeScale.power
        feed(&s, [300, 1150, 1240])     // a big jump between readings is real
        #expect(s.peak == 1240)
    }

    @Test func impossiblePowerIgnored() {
        var s = PeakGaugeScale.power
        feed(&s, [250, 6553, 260])      // e.g. a corrupt packet
        #expect(s.peak == 260)
        #expect(s.upperBound == 300)
    }

    @Test func speedRisingTooFastIgnored() {
        var s = PeakGaugeScale.speed
        feed(&s, [30, 31, 75, 32])      // +44 km/h in 0.25 s: no bike does that
        #expect(s.peak == 32)
    }

    @Test func realSpeedRiseCounts() {
        var s = PeakGaugeScale.speed
        // Sprint: +2.5 km/h per 0.25 s reading (10 km/h per s), slightly noisy.
        feed(&s, [40, 42.5, 45.2, 47.4, 50.1, 52.4])
        #expect(s.peak == 52.4)
        #expect(s.upperBound == 55)
    }

    @Test func speedAfterGapJudgedOverTheGap() {
        var s = PeakGaugeScale.speed
        s.observe(20, at: 0)
        s.observe(45, at: 5)            // 25 km/h over 5 s (e.g. after a reconnect): fine
        #expect(s.peak == 45)
    }

    @Test func overMaximumIgnored() {
        var s = PeakGaugeScale.speed
        s.observe(150, at: 100)         // no previous reading, but over 100 km/h
        #expect(s.peak == 0)
    }

    @Test func holdsForTheRideThenResets() {
        var s = PeakGaugeScale.power
        feed(&s, [700, 100, 120])
        #expect(s.upperBound == 700)    // doesn't shrink mid-ride
        s.reset()                       // next ride
        #expect(s.upperBound == 300)
    }
}
