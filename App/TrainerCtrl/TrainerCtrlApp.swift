import SwiftUI

@main
struct TrainerCtrlApp: App {
    @State private var bridge = BridgeController()

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
