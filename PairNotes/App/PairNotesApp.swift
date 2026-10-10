import SwiftUI

@main
struct PairNotesApp: App {
    @UIApplicationDelegateAdaptor(PairNotesApplicationDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-pairnotes-chat-interaction-fixture") {
                ChatInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-pairnotes-wishes-interaction-fixture") {
                WishInteractionFixture()
            } else { RootView() }
            #else
            RootView()
            #endif
        }
    }
}
