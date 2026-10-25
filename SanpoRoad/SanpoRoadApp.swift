import SwiftUI
import UserNotifications
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        let stop = UNNotificationAction(identifier: "STOP_WALK", title: "散歩を終了", options: [.foreground])
        let pause = UNNotificationAction(identifier: "PAUSE_WALK", title: "一時停止", options: [.foreground])
        let resume = UNNotificationAction(identifier: "RESUME_WALK", title: "再開", options: [.foreground])
        let active = UNNotificationCategory(identifier: "SANPO_RECORDING_ACTIVE", actions: [pause, stop], intentIdentifiers: [])
        let paused = UNNotificationCategory(identifier: "SANPO_RECORDING_PAUSED", actions: [resume, stop], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([active, paused]); UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case "STOP_WALK": NotificationCenter.default.post(name: .sanpoStopRequested, object: nil)
        case "PAUSE_WALK": NotificationCenter.default.post(name: .sanpoPauseRequested, object: nil)
        case "RESUME_WALK": NotificationCenter.default.post(name: .sanpoResumeRequested, object: nil)
        default: break
        }
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
        WindowGroup { ContentView().environmentObject(store).environmentObject(preferences).environmentObject(recorder).environmentObject(cloud).environmentObject(health) }
    }
}
