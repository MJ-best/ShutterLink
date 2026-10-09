import SwiftUI

@main
struct ShutterLinkApp: App {
    @State private var ble = BLEController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ble)
                .preferredColorScheme(.dark)
                .tint(Color.red)
        }
    }
}

enum Haptics {
    static func press() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func tick() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func confirmed() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
