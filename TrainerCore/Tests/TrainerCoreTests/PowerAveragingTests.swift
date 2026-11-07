import Testing
@testable import TrainerCore

@Suite("Power averaging")
struct PowerAveragingTests {
    @Test func instantIsLatest() {
        var average = RollingAverage()
        average.observe(100, at: 0)
        average.observe(300, at: 1)
        #expect(average.average(over: 0, at: 1) == 300)
    }

    @Test func threeSecondWindowDropsOlderReadings() {
        var average = RollingAverage()
        average.observe(1000, at: 0)
        average.observe(200, at: 2)
        average.observe(400, at: 4)
        #expect(average.average(over: 3, at: 4) == 300) // readings at 2 and 4
    }

    @Test func tenSecondWindowAveragesEverythingRecent() {
        var average = RollingAverage()
        for t in 0..<10 { average.observe(Double(t * 10), at: Double(t)) }
        #expect(average.average(over: 10, at: 9) == 45)
    }

    @Test func readingsOlderThanTenSecondsAreForgotten() {
        var average = RollingAverage()
        average.observe(500, at: 0)
        average.observe(100, at: 20)
        #expect(average.average(over: 10, at: 20) == 100)
    }

    @Test func emptyAndReset() {
        var average = RollingAverage()
        #expect(average.average(over: 3, at: 0) == nil)
        average.observe(5, at: 0)
        average.reset()
        #expect(average.average(over: 0, at: 0) == nil)
    }
}
