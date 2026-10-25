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
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var referenceRoute: SavedRoute?

    private let manager = CLLocationManager()
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

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
        applyHighAccuracy(false)
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func requestBackgroundPermission() {
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        else if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func applyHighAccuracy(_ enabled: Bool) {
        highAccuracy = enabled
        manager.desiredAccuracy = enabled ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        manager.distanceFilter = enabled ? 2 : 4
    }

    func prepareRepeat(_ route: SavedRoute) { referenceRoute = route }
    func clearRepeat() { referenceRoute = nil }

    func start(highAccuracy: Bool) {
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
        postRecordingNotification()
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true; pauseStartedMs = Date().epochMilliseconds
        manager.stopUpdatingLocation()
    }

    func resume() {
        guard isRecording, isPaused else { return }
        let now = Date().epochMilliseconds
        if let pauseStartedMs { restIntervals.append(RestInterval(startMs: pauseStartedMs, endMs: now)) }
        self.pauseStartedMs = nil; isPaused = false; segment += 1
        previousRawLocation = nil; manager.startUpdatingLocation()
    }

    func discard() {
        stopUpdatesOnly()
        resetSession()
    }

    func stop(name: String = "散歩", note: String = "", tags: [String] = [], sourceRouteId: Int64? = nil) -> SavedRoute? {
        guard isRecording, let startedAtMs else { return nil }
        let now = Date().epochMilliseconds
        if let pauseStartedMs { restIntervals.append(RestInterval(startMs: pauseStartedMs, endMs: now)) }
        let rest = restIntervals.reduce(Int64(0)) { $0 + $1.durationMs }
        let active = max(0, now - startedAtMs - rest)
        let sortedAccuracy = acceptedAccuracies.sorted()
        let median: Double? = sortedAccuracy.isEmpty ? nil : sortedAccuracy[sortedAccuracy.count / 2]
        let quality = GpsQualityReport(
            acceptedPoints: points.count,
            excludedPoints: excludedPoints,
            medianAccuracyM: median,
            lowAccuracyDurationMs: lowAccuracyDurationMs,
            observedDurationMs: observedDurationMs,
            rawDistanceMeters: rawDistanceMeters,
            filteredDistanceMeters: distanceMeters
        )
        stopUpdatesOnly()
        let route = SavedRoute(
            id: SavedRoute.newID(), name: name.isEmpty ? "散歩" : name, startedAt: startedAtMs,
            durationMs: active, distanceMeters: distanceMeters, points: points, note: note,
            sourceRouteId: sourceRouteId ?? referenceRoute?.id, restDurationMs: rest, tags: tags,
            gpsQuality: quality, restIntervals: restIntervals
        )
        resetSession(keepReference: false)
        return route
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways, let pending = pendingHighAccuracy {
            pendingHighAccuracy = nil
            start(highAccuracy: pending)
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            pendingHighAccuracy = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording, !isPaused else { return }
        for location in locations { process(location) }
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

        if let previousRawLocation { rawDistanceMeters += location.distance(from: previousRawLocation) }
        if location.coordinate.latitude.isFinite, location.coordinate.longitude.isFinite,
           (-90...90).contains(location.coordinate.latitude), (-180...180).contains(location.coordinate.longitude),
           accuracy > 0, accuracy <= 25 {
            previousRawLocation = location
        }

        let candidate = LatLngPoint(location: location, segment: segment)
        guard let delta = acceptedSegment(previous: points.last, candidate: candidate, reportedSpeed: location.speed >= 0 ? location.speed : nil) else {
            excludedPoints += 1; return
        }
        distanceMeters += delta
        points.append(candidate)
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
        let minimumMovement = highAccuracy ? 2.0 : 4.0
        let noise = max(minimumMovement, max(previousAccuracy, accuracy) * 0.65)
        if meters < noise { return nil }
        if meters / seconds > 5.5 { return nil }
        return meters
    }

    private func stopUpdatesOnly() {
        guard isRecording else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["sanpo-recording"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["sanpo-recording"])
    }

    private func resetSession(keepReference: Bool = true) {
        isRecording = false; isPaused = false; startedAtMs = nil; pauseStartedMs = nil
        if !keepReference { referenceRoute = nil }
    }

    private func postRecordingNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "サンポロード"
        content.body = "散歩を記録中です。タップして記録画面へ戻れます。"
        content.categoryIdentifier = "SANPO_RECORDING"
        let request = UNNotificationRequest(identifier: "sanpo-recording", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        center.add(request, withCompletionHandler: nil)
    }
}

extension Notification.Name {
    static let sanpoStopRequested = Notification.Name("sanpo.stop.requested")
}
