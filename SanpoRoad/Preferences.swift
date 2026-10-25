import Foundation
import Combine

@MainActor
final class WalkPreferences: ObservableObject {
    private enum Key {
        static let weeklyGoal = "weekly_goal_meters"
        static let cloudSync = "cloud_sync"
        static let photoSync = "photo_sync"
        static let shareLocation = "share_location"
        static let activeAccount = "active_account_id"
        static let accountEmail = "account_email"
        static let highAccuracy = "gps_high_accuracy"
    }
    private let defaults = UserDefaults.standard

    @Published var weeklyGoalMeters: Double { didSet { weeklyGoalMeters = min(max(weeklyGoalMeters, 500), 100_000); defaults.set(weeklyGoalMeters, forKey: Key.weeklyGoal) } }
    @Published var cloudSync: Bool { didSet { defaults.set(cloudSync, forKey: Key.cloudSync) } }
    @Published var photoSync: Bool { didSet { defaults.set(photoSync, forKey: Key.photoSync) } }
    @Published var shareLocation: Bool { didSet { defaults.set(shareLocation, forKey: Key.shareLocation) } }
    @Published var activeAccountId: String? { didSet { defaults.set(activeAccountId, forKey: Key.activeAccount) } }
    @Published var accountEmail: String? { didSet { defaults.set(accountEmail, forKey: Key.accountEmail) } }
    @Published var highAccuracyGps: Bool { didSet { defaults.set(highAccuracyGps, forKey: Key.highAccuracy) } }

    init() {
        let goal = defaults.double(forKey: Key.weeklyGoal)
        weeklyGoalMeters = goal == 0 ? 10_000 : min(max(goal, 500), 100_000)
        cloudSync = defaults.bool(forKey: Key.cloudSync)
        photoSync = defaults.bool(forKey: Key.photoSync)
        shareLocation = defaults.bool(forKey: Key.shareLocation)
        activeAccountId = defaults.string(forKey: Key.activeAccount)
        accountEmail = defaults.string(forKey: Key.accountEmail)
        highAccuracyGps = defaults.bool(forKey: Key.highAccuracy)
    }
}
