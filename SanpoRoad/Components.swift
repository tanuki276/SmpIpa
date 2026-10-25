import SwiftUI
import MapKit
import UIKit

struct RouteMapView: View {
    var points: [LatLngPoint]
    var reference: [LatLngPoint] = []
    var showsUserLocation = false
    var height: CGFloat = 320
    @State private var position: MapCameraPosition = .automatic

    private var segments: [[CLLocationCoordinate2D]] {
        Dictionary(grouping: points, by: \.segment).sorted { $0.key < $1.key }.map { $0.value.map(\.coordinate) }
    }
    private var referenceSegments: [[CLLocationCoordinate2D]] {
        Dictionary(grouping: reference, by: \.segment).sorted { $0.key < $1.key }.map { $0.value.map(\.coordinate) }
    }

    var body: some View {
        Map(position: $position) {
            if showsUserLocation { UserAnnotation() }
            ForEach(Array(referenceSegments.enumerated()), id: \.offset) { _, coords in
                if coords.count >= 2 { MapPolyline(coordinates: coords).stroke(.orange.opacity(0.7), style: StrokeStyle(lineWidth: 4, dash: [8, 5])) }
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, coords in
                if coords.count >= 2 { MapPolyline(coordinates: coords).stroke(.blue, lineWidth: 5) }
            }
            if let first = points.first { Annotation("開始", coordinate: first.coordinate) { Image(systemName: "figure.walk.circle.fill").font(.title2).foregroundStyle(.green) } }
            if let last = points.last, points.count > 1 { Annotation("終了", coordinate: last.coordinate) { Image(systemName: "flag.checkered.circle.fill").font(.title2).foregroundStyle(.red) } }
        }
        .mapControls { MapCompass(); MapScaleView(); if showsUserLocation { MapUserLocationButton() } }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { fit() }
        .onChange(of: points.count) { _, _ in fit() }
        .onChange(of: reference.count) { _, _ in fit() }
    }

    private func fit() {
        let coords = (points + reference).map(\.coordinate)
        guard let first = coords.first else { return }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in coords { minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude); minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude) }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.005, (maxLat - minLat) * 1.5), longitudeDelta: max(0.005, (maxLon - minLon) * 1.5))
        position = .region(MKCoordinateRegion(center: center, span: span))
    }
}

struct RoutePhotoView: View {
    let path: String?
    var height: CGFloat = 160
    var body: some View {
        Group {
            if let path, let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack { Rectangle().fill(.secondary.opacity(0.08)); Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity).frame(height: height).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct MetricPill: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline).monospacedDigit() }
            .frame(maxWidth: .infinity).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct MessageBanner: View {
    let text: String
    var body: some View { Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)) }
}

struct ShareFile: Identifiable { let url: URL; var id: String { url.absoluteString } }
