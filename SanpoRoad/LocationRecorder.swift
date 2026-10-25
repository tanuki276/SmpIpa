import Foundation
import CoreLocation
import Combine
import UserNotifications

@MainActor
final class LocationRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var points: [LatLngPoint] = []
    @Published private(set) var distanceMeters: Double = 0
    @Published private(set) var startedAtMs: Int64?
    @Published private(set) var latestAccuracy: Double?
    @Published private(set) var currentPoint: LatLngPoint?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var pendingRoute: SavedRoute?
    @Published private(set) var recoveryError: String?
    @Published var referenceRoute: SavedRoute?

    private let manager = CLLocationManager()
    private let sessionStore: LiveSessionStore
    private var segment = 0
    private var restIntervals: [RestInterval] = []
    private var pauseStartedMs: Int64?
    private var acceptedAccuracies: [Double] = []
    private var excludedPoints = 0
    private var rawDistanceMeters: Double = 0
    private var previousRawLocation: CLLocation?
    private var lastObservationMs: Int64?
    private var observedDurationMs: Int64 = 0
    private var lowAccuracyDurationMs: Int64 = 0
    private var highAccuracy = false
    private var pendingHighAccuracy: Bool?
    private var restoredSourceRouteId: Int64?

    override convenience init() { self.init(sessionStore: .shared) }

    init(sessionStore: LiveSessionStore) {
        self.sessionStore = sessionStore
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
        applyHighAccuracy(false)
        restorePendingAndLiveSession()
    }

    func requestPermission() { manager.requestWhenInUseAuthorization() }
    func requestBackgroundPermission() {
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        else if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func applyHighAccuracy(_ enabled: Bool) {
        highAccuracy = enabled
        manager.desiredAccuracy = enabled ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        manager.distanceFilter = enabled ? 2 : 4
    }

    func prepareRepeat(_ route: SavedRoute) { referenceRoute = route; restoredSourceRouteId = route.id; persistLiveIfNeeded() }
    func clearRepeat() { referenceRoute = nil; restoredSourceRouteId = nil; persistLiveIfNeeded() }
    func restoreGuideIfNeeded(from records: [SavedRoute]) {
        guard referenceRoute == nil, let id = restoredSourceRouteId else { return }
        referenceRoute = records.first { $0.id == id && $0.deletedAt == nil }
    }

    func start(highAccuracy: Bool) {
        guard !isRecording, pendingRoute == nil else { return }
        applyHighAccuracy(highAccuracy)
        if authorizationStatus == .notDetermined { pendingHighAccuracy = highAccuracy; requestPermission(); return }
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else { return }
        points = []; distanceMeters = 0; rawDistanceMeters = 0; previousRawLocation = nil
        acceptedAccuracies = []; excludedPoints = 0; restIntervals = []; pauseStartedMs = nil
        observedDurationMs = 0; lowAccuracyDurationMs = 0; lastObservationMs = nil; segment = 0
        startedAtMs = Date().epochMilliseconds; isRecording = true; isPaused = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        requestBackgroundPermission()
        persistLiveIfNeeded(); updateRecordingNotification()
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true; pauseStartedMs = Date().epochMilliseconds
        manager.stopUpdatingLocation(); persistLiveIfNeeded(); updateRecordingNotification()
    }

    func resume() {
        guard isRecording, isPaused else { return }
        let now = Date().epochMilliseconds
        if let pauseStartedMs { restIntervals.append(RestInterval(startMs: pauseStartedMs, endMs: now)) }
        self.pauseStartedMs = nil; isPaused = false; segment += 1
        previousRawLocation = nil
        lastObservationMs = nil
        manager.startUpdatingLocation(); persistLiveIfNeeded(); updateRecordingNotification()
    }

    func discard() { stopUpdatesOnly(); sessionStore.clearLive(); resetSession() }
    func clearPending() { pendingRoute = nil; sessionStore.clearPending() }

    func stop(name: String = "散歩", note: String = "", tags: [String] = [], sourceRouteId: Int64? = nil) -> SavedRoute? {
        guard isRecording, let startedAtMs else { return pendingRoute }
        let now = Date().epochMilliseconds
        var completedRests = restIntervals
        if let pauseStartedMs { completedRests.append(RestInterval(startMs: pauseStartedMs, endMs: now)) }
        let rest = completedRests.reduce(Int64(0)) { $0 + $1.durationMs }
        let active = max(0, now - startedAtMs - rest)
        let sortedAccuracy = acceptedAccuracies.sorted()
        let median: Double? = sortedAccuracy.isEmpty ? nil : sortedAccuracy[sortedAccuracy.count / 2]
        let quality = GpsQualityReport(acceptedPoints: points.count, excludedPoints: excludedPoints, medianAccuracyM: median,
            lowAccuracyDurationMs: lowAccuracyDurationMs, observedDurationMs: observedDurationMs,
            rawDistanceMeters: rawDistanceMeters, filteredDistanceMeters: distanceMeters)
        let route = SavedRoute(id: max(1, startedAtMs), name: name.isEmpty ? "散歩" : name, startedAt: startedAtMs,
            durationMs: active, distanceMeters: distanceMeters, points: points, note: note,
            sourceRouteId: sourceRouteId ?? referenceRoute?.id ?? restoredSourceRouteId, restDurationMs: rest, tags: tags,
            gpsQuality: quality, restIntervals: completedRests)
        do { try sessionStore.savePending(route); pendingRoute = route; recoveryError = nil }
        catch {
            // Keep both the live checkpoint and in-memory track until a retry succeeds.
            pause()
            recoveryError = "保存待ちの散歩を保持できませんでした。記録は一時停止しています。空き容量を確認して、もう一度終了してください。"
            return nil
        }
        stopUpdatesOnly(); sessionStore.clearLive(); resetSession(keepReference: false)
        return route
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways, let pending = pendingHighAccuracy {
            pendingHighAccuracy = nil; start(highAccuracy: pending)
        } else if authorizationStatus == .denied || authorizationStatus == .restricted { pendingHighAccuracy = nil }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording, !isPaused else { return }
        for location in locations { process(location) }
        persistLiveIfNeeded(); updateRecordingNotification()
    }

    private func process(_ location: CLLocation) {
        let accuracy = location.horizontalAccuracy
        let now = Int64(location.timestamp.timeIntervalSince1970 * 1000)
        latestAccuracy = accuracy >= 0 ? accuracy : nil
        if let lastObservationMs, now > lastObservationMs {
            let delta = min(Int64(15_000), now - lastObservationMs)
            observedDurationMs += delta
            if accuracy > 15 { lowAccuracyDurationMs += delta }
        }
        lastObservationMs = now
        let coordinateValid = location.coordinate.latitude.isFinite && location.coordinate.longitude.isFinite &&
            (-90...90).contains(location.coordinate.latitude) && (-180...180).contains(location.coordinate.longitude)
        if coordinateValid, accuracy > 0, accuracy <= 25 {
            if let previousRawLocation { rawDistanceMeters += location.distance(from: previousRawLocation) }
            previousRawLocation = location; currentPoint = LatLngPoint(location: location, segment: segment)
        }
        let candidate = LatLngPoint(location: location, segment: segment)
        guard let delta = acceptedSegment(previous: points.last, candidate: candidate, reportedSpeed: location.speed >= 0 ? location.speed : nil) else { excludedPoints += 1; return }
        distanceMeters += delta; points.append(candidate)
        if let accuracy = candidate.accuracyM { acceptedAccuracies.append(accuracy) }
    }

    private func acceptedSegment(previous: LatLngPoint?, candidate: LatLngPoint, reportedSpeed: Double?) -> Double? {
        guard candidate.lat.isFinite, (-90...90).contains(candidate.lat), candidate.lng.isFinite, (-180...180).contains(candidate.lng),
              let accuracy = candidate.accuracyM, accuracy.isFinite, accuracy > 0, accuracy <= 25 else { return nil }
        if let reportedSpeed, (!reportedSpeed.isFinite || reportedSpeed < 0 || reportedSpeed > 6) { return nil }
        guard let previous else { return 0 }
        guard candidate.timeMs > previous.timeMs else { return nil }
        if previous.segment != candidate.segment { return 0 }
        let seconds = Double(candidate.timeMs - previous.timeMs) / 1000
        let meters = RouteMath.distance(previous, candidate)
        let previousAccuracy = (previous.accuracyM ?? accuracy) > 0 ? (previous.accuracyM ?? accuracy) : accuracy
        let noise = max(highAccuracy ? 2.0 : 4.0, max(previousAccuracy, accuracy) * 0.65)
        if meters < noise || meters / seconds > 5.5 { return nil }
        return meters
    }

    private func restorePendingAndLiveSession() {
        do { pendingRoute = try sessionStore.loadPending() } catch { recoveryError = error.localizedDescription }
        do {
            guard pendingRoute == nil, let snap = try sessionStore.loadLive() else { return }
            applyHighAccuracy(snap.highAccuracy ?? false)
            startedAtMs = snap.startedAtMs; isRecording = true; isPaused = snap.isPaused; pauseStartedMs = snap.pauseStartedMs
            segment = snap.segment; points = snap.points; distanceMeters = snap.distanceMeters; restIntervals = snap.restIntervals
            excludedPoints = snap.excludedPoints; rawDistanceMeters = snap.rawDistanceMeters; observedDurationMs = snap.observedDurationMs
            lowAccuracyDurationMs = snap.lowAccuracyDurationMs; latestAccuracy = snap.latestAccuracy; restoredSourceRouteId = snap.sourceRouteId
            acceptedAccuracies = points.compactMap(\.accuracyM)
            if let last = points.last { currentPoint = last }
            previousRawLocation = nil
            lastObservationMs = nil
            if !isPaused, authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
                manager.allowsBackgroundLocationUpdates = true; manager.showsBackgroundLocationIndicator = true; manager.startUpdatingLocation()
            }
            updateRecordingNotification()
        } catch { recoveryError = error.localizedDescription }
    }

    private func persistLiveIfNeeded() {
        guard isRecording, let startedAtMs else { return }
        let snapshot = LiveSessionSnapshot(startedAtMs: startedAtMs, isPaused: isPaused, pauseStartedMs: pauseStartedMs,
            segment: segment, points: points, distanceMeters: distanceMeters, restIntervals: restIntervals,
            excludedPoints: excludedPoints, rawDistanceMeters: rawDistanceMeters, observedDurationMs: observedDurationMs,
            lowAccuracyDurationMs: lowAccuracyDurationMs, latestAccuracy: latestAccuracy,
            sourceRouteId: referenceRoute?.id ?? restoredSourceRouteId, highAccuracy: highAccuracy)
        do { try sessionStore.saveLive(snapshot); recoveryError = nil }
        catch { recoveryError = "GPS記録の保存に失敗しました。空き容量を確認してください。"; isPaused = true; pauseStartedMs = pauseStartedMs ?? Date().epochMilliseconds; manager.stopUpdatingLocation(); updateRecordingNotification() }
    }

    private func stopUpdatesOnly() {
        manager.stopUpdatingLocation(); manager.allowsBackgroundLocationUpdates = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["sanpo-recording"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["sanpo-recording"])
    }

    private func resetSession(keepReference: Bool = true) {
        isRecording = false; isPaused = false; startedAtMs = nil; pauseStartedMs = nil; currentPoint = nil
        if !keepReference { referenceRoute = nil; restoredSourceRouteId = nil }
    }

    private func updateRecordingNotification() {
        guard isRecording else { return }
        let center = UNUserNotificationCenter.current(); center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent(); content.title = "サンポロード"
        if isPaused { content.body = "\(formatKm(distanceMeters)) ・ 一時停止中"; content.categoryIdentifier = "SANPO_RECORDING_PAUSED" }
        else {
            let gps = latestAccuracy.map { " / GPS ±\(Int($0.rounded()))m" } ?? " / 現在地取得中"
            content.body = "\(formatKm(distanceMeters)) ・ 散歩を記録中\(gps)"; content.categoryIdentifier = "SANPO_RECORDING_ACTIVE"
        }
        center.add(UNNotificationRequest(identifier: "sanpo-recording", content: content, trigger: nil), withCompletionHandler: nil)
    }
}

extension Notification.Name {
    static let sanpoStopRequested = Notification.Name("sanpo.stop.requested")
    static let sanpoPauseRequested = Notification.Name("sanpo.pause.requested")
    static let sanpoResumeRequested = Notification.Name("sanpo.resume.requested")
}
