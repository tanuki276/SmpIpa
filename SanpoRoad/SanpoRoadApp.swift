import SwiftUI

@main
struct SanpoRoadApp: App {
    @StateObject private var store = WalkStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
