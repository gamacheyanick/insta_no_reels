import SwiftUI

@main
struct InstaNoReelsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.deepLinks)
        }
    }
}
