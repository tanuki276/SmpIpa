import Foundation
import Combine
import CoreLocation

@MainActor
final class LocationRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var distanceMeters: Double = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        if authorizationStatus == .notDetermined {
            requestPermission()
        }
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else { return }
        points = []
        distanceMeters = 0
        startedAt = Date()
        isRecording = true
        manager.startUpdatingLocation()
    }

    func stop(name: String = "散歩", note: String = "") -> WalkRecord? {
        guard isRecording, let startedAt else { return nil }
        manager.stopUpdatingLocation()
        isRecording = false
        let endedAt = Date()
        return WalkRecord(
            id: UUID(),
            name: name.isEmpty ? "散歩" : name,
            startedAt: startedAt,
            endedAt: endedAt,
            duration: endedAt.timeIntervalSince(startedAt),
            distanceMeters: distanceMeters,
            points: points,
            note: note,
            favorite: false
        )
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording else { return }
        for location in locations where location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 50 {
            if let last = points.last {
                let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
                let delta = location.distance(from: previous)
                if delta < 200 { distanceMeters += delta }
            }
            points.append(TrackPoint(location: location))
        }
    }
}
