import Foundation
import CoreLocation

struct LatLngPoint: Codable, Hashable, Identifiable {
    var lat: Double
    var lng: Double
    var timeMs: Int64
    var accuracyM: Double?
    var segment: Int = 0

    var id: String { "\(segment):\(timeMs):\(lat):\(lng)" }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }

    init(lat: Double, lng: Double, timeMs: Int64, accuracyM: Double? = nil, segment: Int = 0) {
        self.lat = lat; self.lng = lng; self.timeMs = timeMs; self.accuracyM = accuracyM; self.segment = segment
    }

    init(location: CLLocation, segment: Int) {
        lat = location.coordinate.latitude
        lng = location.coordinate.longitude
        timeMs = Int64(location.timestamp.timeIntervalSince1970 * 1000)
        accuracyM = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        self.segment = segment
    }
}

struct RestInterval: Codable, Hashable, Identifiable {
    var startMs: Int64
    var endMs: Int64
    var id: String { "\(startMs)-\(endMs)" }
    var durationMs: Int64 { max(0, endMs - startMs) }
}

struct GpsQualityReport: Codable, Hashable {
    var acceptedPoints: Int = 0
    var excludedPoints: Int = 0
    var medianAccuracyM: Double?
    var lowAccuracyDurationMs: Int64 = 0
    var observedDurationMs: Int64 = 0
    var rawDistanceMeters: Double = 0
    var filteredDistanceMeters: Double = 0

    var confidence: String {
        let total = acceptedPoints + excludedPoints
        guard total >= 10, let median = medianAccuracyM else { return "不安定" }
        let lowRatio = observedDurationMs > 0 ? Double(lowAccuracyDurationMs) / Double(observedDurationMs) : 0
        if median > 15 || lowRatio > 0.30 { return "不安定" }
        if median > 7 || lowRatio > 0.10 { return "普通" }
        return "良好"
    }
}

struct SavedRoute: Codable, Hashable, Identifiable {
    var id: Int64
    var name: String
    var startedAt: Int64
    var durationMs: Int64
    var distanceMeters: Double
    var points: [LatLngPoint]
    var note: String = ""
    var photoPath: String? = nil
    var photoObjectPath: String? = nil
    var ownerId: String? = nil
    var updatedAt: Int64 = 0
    var deletedAt: Int64? = nil
    var favorite: Bool = false
    var photoRemoved: Bool = false
    var syncState: String = "PENDING"
    var photoHash: String? = nil
    var syncedPhotoHash: String? = nil
    var sourceRouteId: Int64? = nil
    var restDurationMs: Int64 = 0
    var formatVersion: Int = 2
    var tags: [String] = []
    var imported: Bool = false
    var importKey: String? = nil
    var gpsQuality: GpsQualityReport? = nil
    var restIntervals: [RestInterval] = []

    var startedDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt) / 1000) }
    var endedDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt + durationMs + restDurationMs) / 1000) }
    var elapsedMs: Int64 { max(0, durationMs + restDurationMs) }
    var averagePaceMinutesPerKm: Double? {
        guard distanceMeters >= 1, durationMs > 0 else { return nil }
        return (Double(durationMs) / 60_000) / (distanceMeters / 1000)
    }
    var hasPhoto: Bool { photoPath != nil || photoObjectPath != nil }
    var isDeleted: Bool { deletedAt != nil }

    static func newID() -> Int64 {
        max(1, Int64(Date().timeIntervalSince1970 * 1000))
    }
}

struct WalkStatsSnapshot: Hashable {
    var totalDistanceMeters: Double = 0
    var totalDurationMs: Int64 = 0
    var totalWalks: Int = 0
    var currentStreakDays: Int = 0
    var thisWeekDistanceMeters: Double = 0
    var thisWeekWalks: Int = 0
    var lastWeekDistanceMeters: Double = 0
    var longestDistanceMeters: Double = 0
    var longestDurationMs: Int64 = 0
    var averageDistanceMeters: Double = 0
    var averageDurationMs: Int64 = 0
    var weekDeltaMeters: Double { thisWeekDistanceMeters - lastWeekDistanceMeters }
}

struct WeeklyDistance: Identifiable, Hashable {
    var weekStart: Date
    var distanceMeters: Double
    var walks: Int
    var id: Date { weekStart }
}

struct CalendarDaySummary: Identifiable, Hashable {
    var date: Date
    var distanceMeters: Double
    var walks: Int
    var id: Date { date }
}

struct RouteMetric: Identifiable, Hashable {
    var label: String
    var current: Double?
    var previous: Double?
    var unit: String
    var lowerIsBetter: Bool = false
    var id: String { label }
    var delta: Double? {
        guard let current, let previous else { return nil }
        return current - previous
    }
    var assessment: String {
        guard let delta else { return "比較なし" }
        if abs(delta) < 0.01 { return "ほぼ同じ" }
        let improved = lowerIsBetter ? delta < 0 : delta > 0
        return improved ? "改善" : "変化"
    }
}

struct HealthSummary: Hashable {
    var steps: Double?
    var averageHeartRate: Double?
    var activeCalories: Double?
}

struct ManagedShare: Codable, Hashable, Identifiable {
    var token: String
    var routeLocalId: Int64?
    var name: String
    var showMap: Bool
    var createdAt: String
    var expiresAt: String?
    var id: String { token }

    enum CodingKeys: String, CodingKey {
        case token, name
        case routeLocalId = "route_local_id"
        case showMap = "show_map"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

enum HistorySort: String, CaseIterable, Identifiable {
    case newest = "新しい順"
    case longest = "距離順"
    case duration = "時間順"
    var id: String { rawValue }
}

struct HistoryFilter: Hashable {
    var since: Int64 = 0
    var minimumMeters: Double = 0
    var photosOnly = false
    var favoritesOnly = false
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

extension Date {
    var epochMilliseconds: Int64 { Int64(timeIntervalSince1970 * 1000) }
}

func formatKm(_ meters: Double) -> String { String(format: "%.2f km", max(0, meters) / 1000) }
func formatDuration(_ ms: Int64) -> String {
    let total = max(0, ms) / 1000
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
func formatPace(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "--" }
    let min = Int(value), sec = Int((value - Double(min)) * 60)
    return String(format: "%d:%02d /km", min, sec)
}
