import Testing
@testable import TrainerCore

/// Behaviour found while testing with Zwift: gear edits apply mid-ride, and
/// Zwift's side of the bridge survives ending and starting a ride.
@Suite("Ride lifecycle")
struct RideLifecycleTests {
    let road = SimulationParameters(windSpeed: 0, grade: 0.04, crr: 0.004, cw: 0.51)
    let data = IndoorBikeData(instantaneousSpeed: 28.8, instantaneousCadence: 85, instantaneousPower: 200)

    /// A riding bridge: trainer controlled, Zwift in control and on a 4 % road.
    func riding(_ engine: ShiftingEngine) -> BridgeCore {
        var b = BridgeCore(engine: engine)
        _ = b.trainerDidConnect()
        _ = b.handleTrainerResponse(.init(to: .requestControl, result: .success), at: 0)
        _ = b.handleZwift(.requestControl, at: 0)
        _ = b.handleZwift(.setIndoorBikeSimulation(road), at: 0)
        _ = b.handleTrainerData(data, at: 1)
        return b
    }

    func grades(_ outputs: [BridgeCore.Output]) -> [Double] {
        outputs.compactMap {
            if case .sendToTrainer(.setIndoorBikeSimulation(let p)) = $0 { p.grade } else { nil }
        }
    }

    // MARK: Custom gears

    @Test func customProfileFollowsItsInputs() throws {
        let a = try GearProfile.custom(chainring: 42, smallestCog: 10, largestCog: 52, cogCount: 12)
        let b = try GearProfile.custom(chainring: 50, smallestCog: 10, largestCog: 52, cogCount: 12)
        #expect(a.id == GearProfile.customID && b.id == GearProfile.customID)
        #expect(a.name == "1× 42T, 10–52")
        #expect(b.name == "1× 50T, 10–52")
        #expect(a != b)   // a different chainring is a change the bridge must apply
        #expect(b.label(ofGear: b.gearCount - 1) == "50×10")
        #expect(zip(a.ratios, b.ratios).allSatisfy { abs($1 / $0 - 50.0 / 42) < 1e-9 })
    }

    @Test func customProfileClampsCogCountToRange() throws {
        let p = try GearProfile.custom(chainring: 42, smallestCog: 11, largestCog: 14, cogCount: 12)
        #expect(p.gearCount == 4)
        #expect(p.drivetrain?.cogs == [11, 12, 13, 14])
    }

    // MARK: Changing gears mid-ride

    @Test func newProfileMidRideTakesEffectImmediately() throws {
        let rider = RiderSetup()
        var b = riding(.gradeOffset(profile: .standard, rider: rider))
        let custom = try GearProfile.custom(chainring: 50, smallestCog: 11, largestCog: 34, cogCount: 11)

        let out = b.setEngine(.gradeOffset(profile: custom, rider: rider), at: 2)

        // What the ride screen reads comes straight from the new engine.
        let engine = try #require(b.engine)
        #expect(engine.gearbox.profile == custom)
        #expect(custom.label(ofGear: engine.gearbox.gearIndex)?.hasPrefix("50×") == true)
        #expect(engine.gearbox.gearIndex == custom.startingGear(for: rider))
        // And the trainer gets a command for it without waiting for data.
        #expect(grades(out).count == 1)
    }

    @Test func newRealChainringMidRideMovesTheStartingGear() throws {
        let profile = GearProfile.standard
        var b = riding(.gradeOffset(profile: profile, rider: RiderSetup(realChainring: 34, realCog: 18)))
        let before = try #require(b.engine).gearbox.gearIndex

        _ = b.setEngine(.gradeOffset(profile: profile, rider: RiderSetup(realChainring: 52, realCog: 18)), at: 2)

        let after = try #require(b.engine).gearbox.gearIndex
        #expect(after > before)   // a bigger real chainring matches a harder virtual gear
    }

    // MARK: Ending and starting a ride

    /// End ride disconnects the trainer but keeps Zwift's state (the app no
    /// longer resets the bridge), so the next Start ride needs no re-pairing.
    @Test func zwiftKeepsControlAcrossRides() {
        var b = riding(.gradeOffset(profile: .standard, rider: RiderSetup()))

        b.trainerDidDisconnect()                                          // End ride
        _ = b.setEngine(.gradeOffset(profile: .standard, rider: RiderSetup()), at: 100)  // Start ride
        #expect(b.zwiftHasControl)
        #expect(b.zwiftMode == .simulation(road))

        // Zwift keeps sending while the trainer is away: accepted, nothing sent.
        var steeper = road
        steeper.grade = 0.07
        let reply = b.handleZwift(.setIndoorBikeSimulation(steeper), at: 101)
        #expect(reply.first == .respondToZwift(.init(to: .setIndoorBikeSimulation(steeper), result: .success)))
        #expect(grades(reply).isEmpty)

        // The trainer reconnects: the bridge takes control and replays Zwift's latest road.
        #expect(b.trainerDidConnect() == [.sendToTrainer(.requestControl)])
        let replay = b.handleTrainerResponse(.init(to: .requestControl, result: .success), at: 102)
        #expect(replay.first == .sendToTrainer(.startOrResume))
        #expect(grades(replay).count == 1)
        #expect(b.lastEngineCommand != nil)
    }

    @Test func freshBridgeWouldRefuseZwift() {
        // Why the app keeps the bridge between rides: a reset one has forgotten
        // Zwift's requestControl, and Zwift doesn't ask again on its own.
        var b = BridgeCore(engine: .gradeOffset(profile: .standard, rider: RiderSetup()))
        let reply = b.handleZwift(.setIndoorBikeSimulation(road), at: 0)
        #expect(reply == [.respondToZwift(.init(to: .setIndoorBikeSimulation(road), result: .controlNotPermitted))])
    }
}
