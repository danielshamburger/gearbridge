import Testing
@testable import TrainerCore

@Suite("Cadence slider scale")
struct CadenceScaleTests {
    let scale = CadenceScale()

    @Test func endsAndBreakpoints() {
        #expect(scale.cadence(at: 0) == 0)
        #expect(scale.cadence(at: 0.15) == 60)
        #expect(scale.cadence(at: 0.85) == 100)
        #expect(scale.cadence(at: 1) == 120)
        #expect(scale.cadence(at: -1) == 0)
        #expect(scale.cadence(at: 2) == 120)
        #expect(scale.position(for: 200) == 1)
    }

    @Test func ridingRangeGetsMostOfTheTrack() {
        #expect(abs(scale.position(for: 100) - scale.position(for: 60) - 0.70) < 1e-9)
        // Finer than either end: more track per rpm in 60–100 than in 0–60 or 100–120.
        let perRpm = { (lo: Double, hi: Double) in (scale.position(for: hi) - scale.position(for: lo)) / (hi - lo) }
        #expect(perRpm(60, 100) > 2 * perRpm(0, 60))
        #expect(perRpm(60, 100) > 2 * perRpm(100, 120))
    }

    @Test func positionAndCadenceRoundTrip() {
        for rpm in stride(from: 0.0, through: 120, by: 1) {
            #expect(scale.cadence(at: scale.position(for: rpm)) == rpm)
        }
    }

    @Test func monotonic() {
        var last = -1.0
        for i in 0...1000 {
            let c = scale.cadence(at: Double(i) / 1000)
            #expect(c >= last)
            last = c
        }
    }
}
