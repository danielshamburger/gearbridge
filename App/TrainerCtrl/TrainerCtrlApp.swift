import SwiftUI

@main
struct TrainerCtrlApp: App {
    /// Exactly one bridge per launch: it publishes the Bluetooth service Zwift
    /// talks to, and a second instance would publish a second copy.
    @MainActor private static let sharedBridge = BridgeController()
    @State private var bridge = TrainerCtrlApp.sharedBridge

    var body: some Scene {
        WindowGroup {
            Group {
                if bridge.isRiding {
                    RideView(bridge: bridge)
                } else {
                    HomeView(bridge: bridge)
                }
            }
            .animation(.default, value: bridge.isRiding)
        }
    }
}
