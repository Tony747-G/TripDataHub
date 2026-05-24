import SwiftUI

@main
struct TripDataHubWatchApp: App {
    @StateObject private var receiver = WatchSessionReceiver()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(receiver)
                .onAppear { receiver.activate() }
        }
    }
}
