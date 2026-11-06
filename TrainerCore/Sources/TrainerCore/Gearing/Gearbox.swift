import Foundation

/// The current virtual gear. Shifts can ramp the effective ratio linearly over
/// `rampDuration`; the default is no ramp, so the command sent at the moment of
/// a shift already uses the new gear (the trainer's brake smooths the step).
///
/// Time is a caller-supplied monotonic clock in seconds, which keeps this testable.
public struct Gearbox: Sendable {
    public enum Direction: Sendable {
        /// Harder gear (higher ratio).
        case up
        /// Easier gear (lower ratio).
        case down
    }

    public enum ShiftResult: Equatable, Sendable {
        case shifted(toIndex: Int)
        /// Already in the hardest (up) or easiest (down) gear; nothing changed.
        case atLimit
    }

    public private(set) var profile: GearProfile
    public private(set) var gearIndex: Int
    public var rampDuration: TimeInterval

    private var rampFromRatio: Double
    private var rampStart: TimeInterval?

    /// Starts in `startingGearIndex`, else the profile's starting gear, else the middle gear.
    public init(profile: GearProfile, startingGearIndex: Int? = nil, rampDuration: TimeInterval = 0) {
        let start = Self.clampedStart(startingGearIndex ?? profile.startingGearIndex, in: profile)
        self.profile = profile
        self.gearIndex = start
        self.rampDuration = rampDuration
        self.rampFromRatio = profile.ratios[start]
    }

    private static func clampedStart(_ index: Int?, in profile: GearProfile) -> Int {
        min(max(index ?? profile.gearCount / 2, 0), profile.gearCount - 1)
    }

    /// The ratio of the selected gear, ignoring any ramp in progress.
    public var targetRatio: Double { profile.ratios[gearIndex] }

    /// 1-based gear number for display.
    public var gearNumber: Int { gearIndex + 1 }

    public var isInEasiestGear: Bool { gearIndex == 0 }
    public var isInHardestGear: Bool { gearIndex == profile.gearCount - 1 }

    /// The effective ratio at `time`, part-way between gears during a ramp.
    public func ratio(at time: TimeInterval) -> Double {
        guard let start = rampStart, rampDuration > 0 else { return targetRatio }
        let progress = (time - start) / rampDuration
        if progress >= 1 { return targetRatio }
        if progress <= 0 { return rampFromRatio }
        return rampFromRatio + (targetRatio - rampFromRatio) * progress
    }

    public func isRamping(at time: TimeInterval) -> Bool {
        guard let start = rampStart else { return false }
        return time - start < rampDuration
    }

    @discardableResult
    public mutating func shift(_ direction: Direction, at time: TimeInterval) -> ShiftResult {
        let newIndex = gearIndex + (direction == .up ? 1 : -1)
        guard profile.ratios.indices.contains(newIndex) else { return .atLimit }
        // Start from wherever a previous ramp had reached, so quick double shifts stay smooth.
        rampFromRatio = ratio(at: time)
        rampStart = time
        gearIndex = newIndex
        return .shifted(toIndex: newIndex)
    }

    /// Switches profile and jumps to its starting gear without a ramp.
    public mutating func setProfile(_ newProfile: GearProfile, startingGearIndex: Int? = nil) {
        profile = newProfile
        gearIndex = Self.clampedStart(startingGearIndex ?? newProfile.startingGearIndex, in: newProfile)
        rampStart = nil
        rampFromRatio = targetRatio
    }
}
