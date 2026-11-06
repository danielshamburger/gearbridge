import Foundation

public enum GearProfileError: Error, Equatable, Sendable {
    case noGears
    case nonPositiveRatio(Double)
    /// Ratios must rise strictly from easiest to hardest; `index` is the first offender.
    case notStrictlyAscending(index: Int)
    case startingGearOutOfRange(Int)
    case nonPositiveWheelCircumference(Double)
}

/// The chainring and cogs a profile was built from, kept so it can be edited
/// and each gear labelled (e.g. "42×14").
public struct Drivetrain: Equatable, Sendable, Codable {
    public var chainring: Int
    /// Smallest first.
    public var cogs: [Int]

    public init(chainring: Int, cogs: [Int]) {
        self.chainring = chainring
        self.cogs = cogs.sorted()
    }

    /// `count` cogs from `smallest` to `largest` teeth, evenly spaced as ratios
    /// (each step the same percentage), rounded to whole teeth, smallest first.
    /// `count` is limited to the cogs that fit between the two.
    public static func cassette(smallest: Int, largest: Int, count: Int) -> [Int] {
        let lo = min(smallest, largest), hi = max(smallest, largest)
        let n = min(max(count, 1), hi - lo + 1)
        guard n > 1 else { return [lo] }
        var cogs: [Int] = []
        for i in 0..<n {
            let ideal = Int((Double(lo) * pow(Double(hi) / Double(lo), Double(i) / Double(n - 1))).rounded())
            // Keep teeth strictly increasing and leave room for the cogs still to come.
            let floor = (cogs.last ?? lo - 1) + 1
            let ceiling = hi - (n - 1 - i)
            cogs.append(min(max(ideal, floor), ceiling))
        }
        return cogs
    }

}

/// A user-defined virtual drivetrain: one sequential list of gears, easiest first.
public struct GearProfile: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Gear ratios (chainring ÷ cog), strictly ascending: index 0 is the easiest gear.
    public let ratios: [Double]
    /// Metres. Used to show virtual speed and expected cadence.
    public let wheelCircumference: Double
    /// The gear a ride starts in; nil starts in the gear closest to the real one
    /// (see `startingGear(for:)`).
    public let startingGearIndex: Int?
    /// The teeth the ratios came from, if the profile was built from them.
    public let drivetrain: Drivetrain?

    public init(
        id: UUID = UUID(),
        name: String,
        ratios: [Double],
        wheelCircumference: Double = 2.1,
        startingGearIndex: Int? = nil,
        drivetrain: Drivetrain? = nil
    ) throws {
        guard !ratios.isEmpty else { throw GearProfileError.noGears }
        for (i, r) in ratios.enumerated() {
            guard r > 0, r.isFinite else { throw GearProfileError.nonPositiveRatio(r) }
            if i > 0, r <= ratios[i - 1] { throw GearProfileError.notStrictlyAscending(index: i) }
        }
        guard wheelCircumference > 0, wheelCircumference.isFinite else {
            throw GearProfileError.nonPositiveWheelCircumference(wheelCircumference)
        }
        if let start = startingGearIndex, !ratios.indices.contains(start) {
            throw GearProfileError.startingGearOutOfRange(start)
        }

        self.id = id
        self.name = name
        self.ratios = ratios
        self.wheelCircumference = wheelCircumference
        self.startingGearIndex = startingGearIndex
        self.drivetrain = drivetrain
    }

    /// Builds a profile from a single chainring and a cassette (cogs in any order).
    public static func oneBy(
        id: UUID = UUID(),
        name: String,
        chainring: Int,
        cassette: [Int],
        wheelCircumference: Double = 2.1,
        startingGearIndex: Int? = nil
    ) throws -> GearProfile {
        let ratios = cassette.sorted(by: >).map { Double(chainring) / Double($0) }
        return try GearProfile(
            id: id,
            name: name,
            ratios: ratios,
            wheelCircumference: wheelCircumference,
            startingGearIndex: startingGearIndex,
            drivetrain: Drivetrain(chainring: chainring, cogs: cassette)
        )
    }

    /// A copy with a different starting gear (nil: match the real gear).
    public func withStartingGear(_ index: Int?) throws -> GearProfile {
        try GearProfile(id: id, name: name, ratios: ratios, wheelCircumference: wheelCircumference,
                        startingGearIndex: index, drivetrain: drivetrain)
    }

    /// The gear a ride starts in for this rider.
    public func startingGear(for rider: RiderSetup) -> Int {
        startingGearIndex ?? closestGearIndex(toRatio: rider.realRatio)
    }

    /// "42×14" for a profile built from teeth; nil otherwise.
    public func label(ofGear index: Int) -> String? {
        guard let drivetrain, drivetrain.cogs.count == ratios.count, ratios.indices.contains(index) else { return nil }
        return "\(drivetrain.chainring)×\(drivetrain.cogs[drivetrain.cogs.count - 1 - index])"
    }

    public var gearCount: Int { ratios.count }

    /// The gear whose ratio is nearest `ratio`; ties go to the easier gear.
    public func closestGearIndex(toRatio ratio: Double) -> Int {
        ratios.indices.min { abs(ratios[$0] - ratio) < abs(ratios[$1] - ratio) }!
    }

    /// Default profile: 1× 42T with a 10–52 12-speed cassette (ratios 0.81–4.2).
    public static let standard: GearProfile = try! .oneBy(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "1× 42T, 10–52",
        chainring: 42,
        cassette: [10, 12, 14, 16, 18, 21, 24, 28, 32, 36, 42, 52]
    )

    /// Id shared by every custom profile, so editing replaces the previous one.
    public static let customID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!

    /// The custom 1× profile built from the Gears screen: one chainring and a
    /// cassette of `cogCount` cogs spaced evenly from `smallestCog` to `largestCog`.
    public static func custom(
        chainring: Int,
        smallestCog: Int,
        largestCog: Int,
        cogCount: Int,
        wheelCircumference: Double = 2.1
    ) throws -> GearProfile {
        let cogs = Drivetrain.cassette(smallest: smallestCog, largest: largestCog, count: cogCount)
        return try .oneBy(
            id: customID,
            name: "1× \(chainring)T, \(cogs.first!)–\(cogs.last!)",
            chainring: chainring,
            cassette: cogs,
            wheelCircumference: wheelCircumference
        )
    }

    /// Ready-made profiles. Fixed ids so a saved choice still matches after an update.
    public static let presets: [GearProfile] = [
        standard,
        try! .oneBy(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "1× 40T, 11–42",
            chainring: 40,
            cassette: [11, 13, 15, 17, 19, 21, 24, 28, 32, 36, 42]
        ),
        try! .oneBy(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "1× 44T, 10–44",
            chainring: 44,
            cassette: [10, 11, 13, 15, 17, 19, 21, 24, 28, 32, 38, 44]
        ),
        try! .oneBy(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            name: "1× 46T, 10–36",
            chainring: 46,
            cassette: [10, 11, 12, 13, 15, 17, 19, 21, 24, 28, 32, 36]
        ),
        try! .oneBy(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            name: "1× 50T, 10–42",
            chainring: 50,
            cassette: [10, 12, 14, 16, 18, 21, 24, 28, 32, 36, 42]
        ),
    ]
}

extension GearProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, ratios, wheelCircumference, startingGearIndex, drivetrain
    }

    /// Decoding runs the same validation as `init`, so a corrupt saved profile throws.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            ratios: try c.decode([Double].self, forKey: .ratios),
            wheelCircumference: try c.decode(Double.self, forKey: .wheelCircumference),
            startingGearIndex: try c.decodeIfPresent(Int.self, forKey: .startingGearIndex),
            drivetrain: try c.decodeIfPresent(Drivetrain.self, forKey: .drivetrain)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(ratios, forKey: .ratios)
        try c.encode(wheelCircumference, forKey: .wheelCircumference)
        try c.encodeIfPresent(startingGearIndex, forKey: .startingGearIndex)
        try c.encodeIfPresent(drivetrain, forKey: .drivetrain)
    }
}

/// The real bike on the trainer. The chain stays on one cog for the whole ride.
public struct RiderSetup: Equatable, Sendable, Codable {
    /// Rider plus bike, kg.
    public var systemMass: Double
    public var realChainring: Int
    public var realCog: Int

    public init(systemMass: Double = 80, realChainring: Int = 42, realCog: Int = 18) {
        self.systemMass = systemMass
        self.realChainring = realChainring
        self.realCog = realCog
    }

    public var realRatio: Double { Double(realChainring) / Double(realCog) }
}
