import SwiftUI

@main
struct TrainerCtrlApp: App {
    /// Exactly one bridge per launch: it publishes the Bluetooth service Zwift
    /// talks to, and a second instance would publish a second copy.
    @MainActor private static let sharedBridge = BridgeController()
    @State private var bridge = TrainerCtrlApp.sharedBridge
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if bridge.isRiding {
                    RideView(bridge: bridge)
                } else {
                    HomeView(bridge: bridge)
                }
            }
            // Quick: the screen change is the only feedback for Start and End ride.
            .animation(.easeOut(duration: 0.2), value: bridge.isRiding)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: bridge.appEnteredBackground()
            case .active: bridge.appBecameActive()
            default: break
            }
        }
    }
}
