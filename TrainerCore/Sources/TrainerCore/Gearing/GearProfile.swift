import Foundation

public enum GearProfileError: Error, Equatable, Sendable {
    case noGears
    case nonPositiveRatio(Double)
    /// Ratios must rise strictly from easiest to hardest; `index` is the first offender.
    case notStrictlyAscending(index: Int)
    case startingGearOutOfRange(Int)
    case nonPositiveWheelCircumference(Double)
}

/// A user-defined virtual drivetrain: one sequential list of gears, easiest first.
public struct GearProfile: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Gear ratios (chainring ÷ cog), strictly ascending: index 0 is the easiest gear.
    public let ratios: [Double]
    /// Metres. Used to show virtual speed and expected cadence.
    public let wheelCircumference: Double
    public let startingGearIndex: Int

    public init(
        id: UUID = UUID(),
        name: String,
        ratios: [Double],
        wheelCircumference: Double = 2.1,
        startingGearIndex: Int? = nil
    ) throws {
        guard !ratios.isEmpty else { throw GearProfileError.noGears }
        for (i, r) in ratios.enumerated() {
            guard r > 0, r.isFinite else { throw GearProfileError.nonPositiveRatio(r) }
            if i > 0, r <= ratios[i - 1] { throw GearProfileError.notStrictlyAscending(index: i) }
        }
        guard wheelCircumference > 0, wheelCircumference.isFinite else {
            throw GearProfileError.nonPositiveWheelCircumference(wheelCircumference)
        }
        let start = startingGearIndex ?? ratios.count / 2
        guard ratios.indices.contains(start) else { throw GearProfileError.startingGearOutOfRange(start) }

        self.id = id
        self.name = name
        self.ratios = ratios
        self.wheelCircumference = wheelCircumference
        self.startingGearIndex = start
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
            startingGearIndex: startingGearIndex
        )
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
}

extension GearProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, ratios, wheelCircumference, startingGearIndex
    }

    /// Decoding runs the same validation as `init`, so a corrupt saved profile throws.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            ratios: try c.decode([Double].self, forKey: .ratios),
            wheelCircumference: try c.decode(Double.self, forKey: .wheelCircumference),
            startingGearIndex: try c.decode(Int.self, forKey: .startingGearIndex)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(ratios, forKey: .ratios)
        try c.encode(wheelCircumference, forKey: .wheelCircumference)
        try c.encode(startingGearIndex, forKey: .startingGearIndex)
    }
}

/// The real bike on the trainer. The chain stays on one cog for the whole ride.
public struct RiderSetup: Equatable, Sendable, Codable {
    /// Rider plus bike, kg.
    public var systemMass: Double
    public var realChainring: Int
    public var realCog: Int

    public init(systemMass: Double = 80, realChainring: Int = 50, realCog: Int = 17) {
        self.systemMass = systemMass
        self.realChainring = realChainring
        self.realCog = realCog
    }

    public var realRatio: Double { Double(realChainring) / Double(realCog) }
}
