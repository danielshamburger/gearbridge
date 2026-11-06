import Foundation
import Testing
@testable import TrainerCore

extension RiderSetup {
    /// The rider many tests' numbers were worked out for.
    static let fiftySeventeen = RiderSetup(realChainring: 50, realCog: 17)
}

@Suite("Gear profiles")
struct GearProfileTests {
    @Test func oneByOrdersEasiestFirst() throws {
        let profile = try GearProfile.oneBy(name: "test", chainring: 40, cassette: [20, 10, 40])
        #expect(profile.ratios == [1, 2, 4])
        #expect(profile.startingGearIndex == nil)
        #expect(Gearbox(profile: profile).gearIndex == 1)   // no rider: middle gear
        #expect(profile.label(ofGear: 2) == "40×10")
    }

    @Test func defaultRealGearIs42x18() {
        let rider = RiderSetup()
        #expect(rider.realChainring == 42 && rider.realCog == 18)
        // 42×18 is itself a gear in the standard profile.
        #expect(GearProfile.standard.label(ofGear: GearProfile.standard.startingGear(for: rider)) == "42×18")
    }

    @Test func startsInRealGearUnlessChosen() throws {
        let rider = RiderSetup.fiftySeventeen   // 50×17 = 2.94, closest is 42×14 = 3.0 (index 9)
        #expect(GearProfile.standard.startingGear(for: rider) == 9)
        #expect(try GearProfile.standard.withStartingGear(3).startingGear(for: rider) == 3)
        #expect(ShiftingEngine.gradeOffset(profile: .standard, rider: rider).gearbox.gearIndex == 9)
        let fast = RiderSetup(realChainring: 50, realCog: 11)
        #expect(ShiftingEngine.gradeOffset(profile: .standard, rider: fast).gearbox.gearIndex == 11)  // 4.55 → 42×10
    }

    @Test func cassetteFromRange() {
        let cogs = Drivetrain.cassette(smallest: 10, largest: 52, count: 12)
        #expect(cogs.count == 12)
        #expect(cogs.first == 10)
        #expect(cogs.last == 52)
        #expect(zip(cogs, cogs.dropFirst()).allSatisfy { $0 < $1 })
        // Tight range: count is capped and every cog is used.
        #expect(Drivetrain.cassette(smallest: 11, largest: 14, count: 12) == [11, 12, 13, 14])
        #expect(Drivetrain.cassette(smallest: 11, largest: 13, count: 3) == [11, 12, 13])
        #expect(Drivetrain.cassette(smallest: 28, largest: 11, count: 2) == [11, 28])
        #expect(Drivetrain.cassette(smallest: 11, largest: 11, count: 5) == [11])
    }

    @Test func presetsAreValidAndDistinct() {
        #expect(GearProfile.presets.count == 5)
        #expect(Set(GearProfile.presets.map(\.id)).count == 5)
        #expect(GearProfile.presets.contains { $0.name == "1× 50T, 10–44" })
        #expect(GearProfile.presets.allSatisfy { $0.gearCount == 12 })   // all SRAM 12-speed
        #expect(GearProfile.presets.allSatisfy { $0.drivetrain != nil && $0.startingGearIndex == nil })
    }

    @Test func rejectsInvalidProfiles() {
        #expect(throws: GearProfileError.noGears) {
            try GearProfile(name: "x", ratios: [])
        }
        #expect(throws: GearProfileError.notStrictlyAscending(index: 1)) {
            try GearProfile.oneBy(name: "x", chainring: 40, cassette: [20, 10, 20])
        }
        #expect(throws: GearProfileError.nonPositiveRatio(-1)) {
            try GearProfile(name: "x", ratios: [-1, 2])
        }
        #expect(throws: GearProfileError.startingGearOutOfRange(5)) {
            try GearProfile(name: "x", ratios: [1, 2], startingGearIndex: 5)
        }
        #expect(throws: GearProfileError.nonPositiveWheelCircumference(0)) {
            try GearProfile(name: "x", ratios: [1, 2], wheelCircumference: 0)
        }
    }

    @Test func closestGear() {
        let profile = GearProfile.standard
        // 50×17 = 2.94 is nearest 42×14 = 3.0.
        let index = profile.closestGearIndex(toRatio: RiderSetup.fiftySeventeen.realRatio)
        #expect(profile.ratios[index] == 3.0)
    }

    @Test func codableRoundTripAndValidation() throws {
        let data = try JSONEncoder().encode(GearProfile.standard)
        #expect(try JSONDecoder().decode(GearProfile.self, from: data) == .standard)
        let chosen = try GearProfile.presets[2].withStartingGear(4)
        #expect(chosen.label(ofGear: 0) == "44×44")
        #expect(try JSONDecoder().decode(GearProfile.self, from: JSONEncoder().encode(chosen)) == chosen)

        // Saved before drivetrains existed.
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000002","name":"old","ratios":[1,2],"wheelCircumference":2.1,"startingGearIndex":0}"#.utf8)
        let decoded = try JSONDecoder().decode(GearProfile.self, from: old)
        #expect(decoded.startingGearIndex == 0)
        #expect(decoded.drivetrain == nil)

        let bad = Data(#"{"id":"00000000-0000-0000-0000-000000000002","name":"bad","ratios":[2,1],"wheelCircumference":2.1,"startingGearIndex":0}"#.utf8)
        #expect(throws: GearProfileError.self) {
            try JSONDecoder().decode(GearProfile.self, from: bad)
        }
    }
}

@Suite("Gearbox")
struct GearboxTests {
    let profile = try! GearProfile(name: "t", ratios: [1, 2, 3], startingGearIndex: 1)

    @Test func shiftsAndStopsAtEnds() {
        var box = Gearbox(profile: profile)
        #expect(box.gearNumber == 2)
        do { let r = box.shift(.up, at: 0); #expect(r == .shifted(toIndex: 2)) }
        #expect(box.isInHardestGear)
        do { let r = box.shift(.up, at: 1); #expect(r == .atLimit) }
        do { let r = box.shift(.down, at: 2); #expect(r == .shifted(toIndex: 1)) }
        do { let r = box.shift(.down, at: 3); #expect(r == .shifted(toIndex: 0)) }
        do { let r = box.shift(.down, at: 4); #expect(r == .atLimit) }
        #expect(box.isInEasiestGear)
    }

    @Test func rampsLinearly() {
        var box = Gearbox(profile: profile, rampDuration: 0.25)
        #expect(box.ratio(at: 0) == 2)
        box.shift(.up, at: 10)
        #expect(box.ratio(at: 10) == 2)
        #expect(box.ratio(at: 10.125) == 2.5)
        #expect(box.isRamping(at: 10.2))
        #expect(box.ratio(at: 10.25) == 3)
        #expect(!box.isRamping(at: 10.25))
    }

    @Test func shiftMidRampStartsFromCurrentRatio() {
        var box = Gearbox(profile: profile, rampDuration: 0.25)
        box.shift(.up, at: 0)          // 2 → 3
        box.shift(.down, at: 0.125)    // at 2.5, now heading to 2
        #expect(box.ratio(at: 0.125) == 2.5)
        #expect(box.ratio(at: 0.25) == 2.25)
        #expect(box.ratio(at: 0.375) == 2)
    }

    @Test func setProfileJumpsToStartingGear() {
        var box = Gearbox(profile: profile)
        box.shift(.up, at: 0)
        box.setProfile(.standard)
        #expect(box.gearIndex == GearProfile.standard.gearCount / 2)
        box.setProfile(.standard, startingGearIndex: 9)
        #expect(box.gearIndex == 9)
        #expect(!box.isRamping(at: 0))
    }
}

@Suite("Control loop helpers")
struct ControlLoopHelperTests {
    @Test func smootherFollowsExponentially() {
        var s = ExponentialSmoother(timeConstant: 1)
        do { let r = s.update(10, at: 0); #expect(r == 10) }
        let v = s.update(20, at: 1)
        #expect(abs(v - (10 + 10 * (1 - exp(-1.0)))) < 1e-12)
    }

    @Test func smootherResetsAfterGap() {
        var s = ExponentialSmoother(timeConstant: 1, resetAfterGap: 3)
        s.update(10, at: 0)
        do { let r = s.update(30, at: 5); #expect(r == 30) }
    }

    @Test func throttleRateLimitsAndSkipsUnchanged() {
        var t = CommandThrottle(minimumInterval: 0.25, gradeThreshold: 0.001)
        let a = SimulationParameters(grade: 0.05)
        do { let r = t.shouldSend(a, at: 0); #expect(r) }
        do { let r = t.shouldSend(SimulationParameters(grade: 0.06), at: 0.1); #expect(!r) }  // too soon
        do { let r = t.shouldSend(a, at: 0.5); #expect(!r) }                                   // unchanged
        do { let r = t.shouldSend(SimulationParameters(grade: 0.0505), at: 0.6); #expect(!r) } // below threshold
        do { let r = t.shouldSend(SimulationParameters(grade: 0.06), at: 0.7); #expect(r) }
    }

    @Test func throttleSmallDriftAccumulates() {
        var t = CommandThrottle(minimumInterval: 0, gradeThreshold: 0.001)
        do { let r = t.shouldSend(SimulationParameters(grade: 0.0500), at: 0); #expect(r) }
        do { let r = t.shouldSend(SimulationParameters(grade: 0.0506), at: 1); #expect(!r) }
        do { let r = t.shouldSend(SimulationParameters(grade: 0.0512), at: 2); #expect(r) }
    }

    @Test func forcedSendWaitsForIntervalButIsNotDropped() {
        var t = CommandThrottle(minimumInterval: 0.25)
        let a = SimulationParameters(grade: 0.05)
        do { let r = t.shouldSend(a, at: 0); #expect(r) }
        do { let r = t.shouldSend(a, at: 0.1, force: true); #expect(!r) }
        do { let r = t.shouldSend(a, at: 0.3); #expect(r) }   // pending shift goes out even though unchanged
        do { let r = t.shouldSend(a, at: 0.6); #expect(!r) }
    }
}
