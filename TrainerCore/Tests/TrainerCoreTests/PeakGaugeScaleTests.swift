import Testing
@testable import TrainerCore

@Suite("Peak gauge scale")
struct PeakGaugeScaleTests {
    @Test func startsAtFloor() {
        #expect(PeakGaugeScale.power.upperBound == 300)
        #expect(PeakGaugeScale.speed.upperBound == 40)
    }

    @Test func growsToHeldPeakRoundedUp() {
        var s = PeakGaugeScale.power
        for w in [200.0, 380, 512, 530, 300] { s.observe(w) }
        #expect(s.peak == 512)          // 512 then 530: 512 was held
        #expect(s.upperBound == 550)

        var v = PeakGaugeScale.speed
        for kmh in [30.0, 61.3, 62.0, 40] { v.observe(kmh) }
        #expect(v.upperBound == 65)
    }

    @Test func singleSpikeIsIgnored() {
        var s = PeakGaugeScale.power
        for w in [250.0, 2000, 260, 255] { s.observe(w) }
        #expect(s.peak == 260)          // 2000 never repeated; 260 was held (2000 then 260)
        #expect(s.upperBound == 300)
    }

    @Test func holdsForTheRideThenResets() {
        var s = PeakGaugeScale.power
        for w in [700.0, 720, 100, 120] { s.observe(w) }
        #expect(s.upperBound == 700)    // doesn't shrink mid-ride
        s.reset()                       // next ride
        #expect(s.upperBound == 300)
        s.observe(900)                  // a single reading right after reset doesn't count
        #expect(s.upperBound == 300)
    }
}
