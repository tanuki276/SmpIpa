import XCTest
@testable import SanpoRoad

final class BackupCompatibilityTests: XCTestCase {
    private let legacyRoute = #"{"id":1,"name":"朝の散歩","startedAt":1700000000000,"durationMs":60000,"distanceMeters":70,"points":[{"lat":35,"lng":139,"timeMs":1700000000000}]}"#

    func testLegacyArrayDefaultsAndLongWhitespacePrefix() throws {
        let data = Data((String(repeating: " \n", count: 100) + "[" + legacyRoute + "]").utf8)
        let result = try BackupExport.decodeBackup(data)
        let route = try XCTUnwrap(result.routes.first)
        XCTAssertEqual(route.points.first?.segment, 0)
        XCTAssertNil(route.points.first?.accuracyM)
        XCTAssertEqual(route.note, "")
        XCTAssertEqual(route.tags, [])
        XCTAssertFalse(route.favorite)
        XCTAssertEqual(route.restDurationMs, 0)
        XCTAssertTrue(route.imported)
        XCTAssertEqual(route.importKey?.count, 64)
    }

    func testEnvelopeWithoutOptionalFields() throws {
        let result = try BackupExport.decodeBackup(Data(("{\"routes\":[" + legacyRoute + "]}").utf8))
        XCTAssertEqual(result.routes.count, 1)
        XCTAssertTrue(result.photos.isEmpty)
    }

    func testRequiredFieldsAndWrongTypesStillFail() {
        XCTAssertThrowsError(try BackupExport.decodeBackup(Data("[{\"id\":1}]".utf8)))
        let invalid = legacyRoute.replacingOccurrences(of: "\"name\":\"朝の散歩\"", with: "\"name\":false")
        XCTAssertThrowsError(try BackupExport.decodeBackup(Data(("[" + invalid + "]").utf8)))
    }

    func testInvalidVersionAndOverflowingEndDateFail() {
        let future = "{\"version\":99,\"routes\":[" + legacyRoute + "]}"
        XCTAssertThrowsError(try BackupExport.decodeBackup(Data(future.utf8)))
        let overflow = legacyRoute.replacingOccurrences(of: "1700000000000", with: String(Int64.max))
        XCTAssertThrowsError(try BackupExport.decodeBackup(Data(("[" + overflow + "]").utf8)))
    }

    func testCurrentRouteRoundTripPreservesMetadata() throws {
        var route = SavedRoute(id: 1, name: "散歩", startedAt: 1_700_000_000_000,
                               durationMs: 60_000, distanceMeters: 100, points: [])
        route.tags = ["朝", "公園"]
        route.favorite = true
        route.restIntervals = [RestInterval(startMs: route.startedAt, endMs: route.startedAt + 1000)]
        route.gpsQuality = GpsQualityReport(acceptedPoints: 10, medianAccuracyM: 5)
        let data = try JSONEncoder().encode(route)
        XCTAssertEqual(try JSONDecoder().decode(SavedRoute.self, from: data), route)
    }

    func testPartialQualityReportUsesDefaults() throws {
        let report = try JSONDecoder().decode(GpsQualityReport.self, from: Data("{\"acceptedPoints\":12,\"medianAccuracyM\":4}".utf8))
        XCTAssertEqual(report.acceptedPoints, 12)
        XCTAssertEqual(report.excludedPoints, 0)
        XCTAssertEqual(report.confidence, "良好")
    }
}

final class PersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func route(_ id: Int64 = 1) -> SavedRoute {
        SavedRoute(id: id, name: "散歩", startedAt: 1_700_000_000_000, durationMs: 60_000,
                   distanceMeters: 100, points: [LatLngPoint(lat: 35, lng: 139, timeMs: 1_700_000_000_000)])
    }

    @MainActor func testFailedAddRollsBackThenRetrySavesOnce() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("routes.json")
        let store = WalkStore(storageURL: url)
        // An existing directory at the file destination deterministically simulates a write failure.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.add(route(), accountId: nil))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.lastError)
        try FileManager.default.removeItem(at: url)
        let saved = try store.add(route(), accountId: nil)
        XCTAssertEqual(store.records, [saved])
        XCTAssertEqual(WalkStore(storageURL: url).records, [saved])
        XCTAssertNil(store.lastError)
    }

    @MainActor func testCorruptHistoryIsNeverOverwritten() throws {
        let url = try directory().appendingPathComponent("routes.json")
        let corrupt = Data("broken history".utf8)
        try corrupt.write(to: url)
        let store = WalkStore(storageURL: url)
        XCTAssertNotNil(store.lastError)
        XCTAssertThrowsError(try store.add(route(), accountId: nil))
        XCTAssertThrowsError(try store.importRoutes([route()], photos: [:], accountId: nil))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    @MainActor func testFailedDeletionKeepsRecordAndPhoto() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("routes.json")
        let photo = dir.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: photo)
        var original = route()
        original.photoPath = photo.path
        let store = WalkStore(storageURL: url)
        let saved = try store.add(original, accountId: nil)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        store.delete(saved)
        XCTAssertEqual(store.records, [saved])
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertNotNil(store.lastError)
    }

    @MainActor func testDuplicateIDReturnsActualStoredRoute() throws {
        let store = WalkStore(storageURL: try directory().appendingPathComponent("routes.json"))
        let first = try store.add(route(), accountId: "account-a")
        let second = try store.add(route(), accountId: "account-a")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.route(id: second.id, ownerId: "account-a"), second)
    }

    @MainActor func testImportIsIdempotentAndScopedToAccount() throws {
        let url = try directory().appendingPathComponent("routes.json")
        let store = WalkStore(storageURL: url)
        let original = route()
        _ = try store.add(original, accountId: "account-a")
        XCTAssertEqual(try store.importRoutes([original], photos: [:], accountId: "account-a"), 0)
        XCTAssertEqual(try store.importRoutes([original], photos: [:], accountId: "account-b"), 1)
        XCTAssertEqual(try store.importRoutes([original], photos: [:], accountId: "account-b"), 0)
        XCTAssertEqual(WalkStore(storageURL: url).records.count, 2)
    }

    @MainActor func testImportPhotoFailureRollsBackWholeBatch() throws {
        let url = try directory().appendingPathComponent("routes.json")
        let store = WalkStore(storageURL: url)
        let existing = try store.add(route(3), accountId: nil)
        let tooLarge = Data(repeating: 0, count: 10 * 1024 * 1024 + 1)
        XCTAssertThrowsError(try store.importRoutes([route(1), route(2)], photos: ["2": tooLarge], accountId: nil))
        XCTAssertEqual(store.records, [existing])
        XCTAssertEqual(WalkStore(storageURL: url).records, [existing])
    }

    @MainActor func testImportDiskFailureDoesNotReportSuccess() throws {
        let url = try directory().appendingPathComponent("routes.json")
        let store = WalkStore(storageURL: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.importRoutes([route()], photos: [:], accountId: nil))
        XCTAssertTrue(store.records.isEmpty)
    }

    @MainActor func testStopFailureKeepsLiveTrackAndRetryDoesNotDoubleCountRest() throws {
        let dir = try directory()
        let sessions = LiveSessionStore(directory: dir)
        let now = Date().epochMilliseconds
        let snapshot = LiveSessionSnapshot(startedAtMs: now - 60_000, isPaused: true,
            pauseStartedMs: now - 10_000, segment: 0, points: route().points,
            distanceMeters: 100, restIntervals: [], excludedPoints: 0, rawDistanceMeters: 100,
            observedDurationMs: 50_000, lowAccuracyDurationMs: 0, latestAccuracy: 5, sourceRouteId: nil)
        try sessions.saveLive(snapshot)
        let recorder = LocationRecorder(sessionStore: sessions)
        let pendingURL = dir.appendingPathComponent("pending-route.json")
        try FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: false)
        XCTAssertNil(recorder.stop())
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(recorder.isPaused)
        XCTAssertEqual(recorder.points, snapshot.points)
        XCTAssertNotNil(try sessions.loadLive())
        XCTAssertNotNil(recorder.recoveryError)
        XCTAssertNil(recorder.stop())
        try FileManager.default.removeItem(at: pendingURL)
        let saved = try XCTUnwrap(recorder.stop())
        XCTAssertEqual(saved.restIntervals.count, 1)
        XCTAssertEqual(saved.durationMs, 50_000)
        XCTAssertEqual(try sessions.loadPending(), saved)
        XCTAssertNil(try sessions.loadLive())
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.recoveryError)
    }

    @MainActor func testStartingAgainDoesNotResetRecoveredSession() throws {
        let dir = try directory()
        let sessions = LiveSessionStore(directory: dir)
        let now = Date().epochMilliseconds
        try sessions.saveLive(LiveSessionSnapshot(startedAtMs: now - 60_000, isPaused: true,
            pauseStartedMs: now - 10_000, segment: 1, points: route().points, distanceMeters: 100,
            restIntervals: [], excludedPoints: 0, rawDistanceMeters: 100, observedDurationMs: 50_000,
            lowAccuracyDurationMs: 0, latestAccuracy: 5, sourceRouteId: nil))
        let recorder = LocationRecorder(sessionStore: sessions)
        recorder.start(highAccuracy: true)
        XCTAssertEqual(recorder.startedAtMs, now - 60_000)
        XCTAssertEqual(recorder.distanceMeters, 100)
        XCTAssertTrue(recorder.isPaused)
        recorder.discard()
    }
}
