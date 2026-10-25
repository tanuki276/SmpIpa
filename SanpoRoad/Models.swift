import Foundation
import CoreLocation

struct TrackPoint: Codable, Identifiable, Hashable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let accuracy: Double

    init(location: CLLocation) {
        id = UUID()
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        timestamp = location.timestamp
        accuracy = location.horizontalAccuracy
    }

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}

struct WalkRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let startedAt: Date
    let endedAt: Date
    let duration: TimeInterval
    let distanceMeters: Double
    let points: [TrackPoint]
    var note: String
    var favorite: Bool

    var averagePaceMinutesPerKm: Double? {
        guard distanceMeters >= 1 else { return nil }
        return (duration / 60) / (distanceMeters / 1000)
    }
}
