import SwiftUI

@main
struct PairNotesApp: App {
    @UIApplicationDelegateAdaptor(PairNotesApplicationDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { RootView() }
    }
}
