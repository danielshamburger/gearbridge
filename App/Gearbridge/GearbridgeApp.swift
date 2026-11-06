import SwiftUI

@main
struct GearbridgeApp: App {
    /// Exactly one bridge per launch: it publishes the Bluetooth service Zwift
    /// talks to, and a second instance would publish a second copy.
    @MainActor private static let sharedBridge = BridgeController()
    @State private var bridge = GearbridgeApp.sharedBridge
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
            .animation(.default, value: bridge.isRiding)
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
