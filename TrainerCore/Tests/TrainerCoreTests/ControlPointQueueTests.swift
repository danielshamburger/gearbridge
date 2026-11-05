import Testing
@testable import TrainerCore

@Suite("Control point queue")
struct ControlPointQueueTests {
    let simA = ControlPointRequest.setIndoorBikeSimulation(.init(grade: 0.01))
    let simB = ControlPointRequest.setIndoorBikeSimulation(.init(grade: 0.02))
    let simC = ControlPointRequest.setIndoorBikeSimulation(.init(grade: 0.03))

    @Test func oneInFlightAtATime() {
        var q = ControlPointQueue()
        let first = q.enqueue(.requestControl, at: 0)
        let second = q.enqueue(.startOrResume, at: 0)
        #expect(first == .requestControl)
        #expect(second == nil)
        let next = q.didReceive(.init(to: .requestControl, result: .success), at: 0.1)
        #expect(next == .startOrResume)
    }

    @Test func coalescesQueuedSetters() {
        var q = ControlPointQueue()
        _ = q.enqueue(.requestControl, at: 0)
        _ = q.enqueue(simA, at: 0)
        _ = q.enqueue(simB, at: 0)
        _ = q.enqueue(simC, at: 0)
        #expect(q.waiting == [simC])
    }

    @Test func doesNotCoalesceCommands() {
        var q = ControlPointQueue()
        _ = q.enqueue(simA, at: 0)
        _ = q.enqueue(.startOrResume, at: 0)
        _ = q.enqueue(.startOrResume, at: 0)
        #expect(q.waiting.count == 2)
    }

    @Test func ignoresMismatchedResponse() {
        var q = ControlPointQueue()
        _ = q.enqueue(simA, at: 0)
        _ = q.enqueue(.startOrResume, at: 0)
        let next = q.didReceive(.init(to: .requestControl, result: .success), at: 0.1)
        #expect(next == nil)
        #expect(q.inFlight?.request == simA)
    }

    @Test func timesOut() {
        var q = ControlPointQueue(timeout: 2)
        _ = q.enqueue(simA, at: 0)
        _ = q.enqueue(.startOrResume, at: 0)
        let early = q.checkTimeout(at: 1)
        let late = q.checkTimeout(at: 2)
        #expect(early == nil)
        #expect(late == .startOrResume)
    }
}
