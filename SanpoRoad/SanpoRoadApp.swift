import SwiftUI
import UserNotifications
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        let stop = UNNotificationAction(identifier: "STOP_WALK", title: "散歩を終了", options: [.foreground])
        let category = UNNotificationCategory(identifier: "SANPO_RECORDING", actions: [stop], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == "STOP_WALK" { NotificationCenter.default.post(name: .sanpoStopRequested, object: nil) }
    }
}

@main
struct SanpoRoadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = WalkStore()
    @StateObject private var preferences = WalkPreferences()
    @StateObject private var recorder = LocationRecorder()
    @StateObject private var cloud = CloudService()
    @StateObject private var health = HealthKitManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(preferences)
                .environmentObject(recorder)
                .environmentObject(cloud)
                .environmentObject(health)
        }
    }
}
