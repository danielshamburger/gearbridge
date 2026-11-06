import ActivityKit
import Foundation

/// The Live Activity shown during a ride: on the lock screen and in the
/// Dynamic Island. Compiled into both the app and the widget extension.
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 1-based gear number, or nil with virtual shifting off.
        var gear: Int?
        var gearCount: Int
        /// Teeth per cog, easiest (biggest) first, for the cassette strip.
        var cogSizes: [Double]
        /// e.g. "42×18".
        var label: String?
    }
}
