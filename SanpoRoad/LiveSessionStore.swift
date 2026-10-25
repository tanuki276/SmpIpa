import Foundation

struct LiveSessionSnapshot: Codable {
    var startedAtMs: Int64
    var isPaused: Bool
    var pauseStartedMs: Int64?
    var segment: Int
    var points: [LatLngPoint]
    var distanceMeters: Double
    var restIntervals: [RestInterval]
    var excludedPoints: Int
    var rawDistanceMeters: Double
    var observedDurationMs: Int64
    var lowAccuracyDurationMs: Int64
    var latestAccuracy: Double?
    var sourceRouteId: Int64?
    var highAccuracy: Bool? = nil
}

struct LiveSessionStore {
    static let shared = LiveSessionStore()
    private let fm = FileManager.default
    private let directoryOverride: URL?

    init(directory: URL? = nil) { directoryOverride = directory }

    private var directory: URL {
        if let directoryOverride { return directoryOverride }
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SanpoRoad", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = dir; try? mutable.setResourceValues(values)
        return dir
    }

    private var liveURL: URL { directory.appendingPathComponent("live-session.json") }
    private var pendingURL: URL { directory.appendingPathComponent("pending-route.json") }
    private var corruptURL: URL { directory.appendingPathComponent("tracking-corrupt.json") }

    func loadLive() throws -> LiveSessionSnapshot? {
        guard fm.fileExists(atPath: liveURL.path) else { return nil }
        do { return try JSONDecoder().decode(LiveSessionSnapshot.self, from: Data(contentsOf: liveURL)) }
        catch {
            if !fm.fileExists(atPath: corruptURL.path), let data = try? Data(contentsOf: liveURL) { try? data.write(to: corruptURL, options: .atomic) }
            throw AppError.message("記録を読み込めません。復旧用データを保持しています。")
        }
    }

    func saveLive(_ snapshot: LiveSessionSnapshot) throws { try JSONEncoder().encode(snapshot).write(to: liveURL, options: .atomic) }
    func clearLive() { try? fm.removeItem(at: liveURL) }

    func loadPending() throws -> SavedRoute? {
        guard fm.fileExists(atPath: pendingURL.path) else { return nil }
        do { return try JSONDecoder().decode(SavedRoute.self, from: Data(contentsOf: pendingURL)) }
        catch {
            if !fm.fileExists(atPath: corruptURL.path), let data = try? Data(contentsOf: pendingURL) { try? data.write(to: corruptURL, options: .atomic) }
            throw AppError.message("保存待ちの散歩を読み込めません。復旧用データを保持しています。")
        }
    }

    func savePending(_ route: SavedRoute) throws { try JSONEncoder().encode(route).write(to: pendingURL, options: .atomic) }
    func clearPending() { try? fm.removeItem(at: pendingURL) }
}
