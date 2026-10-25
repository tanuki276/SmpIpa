import Foundation

extension RouteMath {
    static func distanceToRoute(_ point: LatLngPoint, _ route: [LatLngPoint]) -> Double {
        guard !route.isEmpty else { return .infinity }
        var best = route.map { distance(point, $0) }.min() ?? .infinity
        let earth = 6_371_000.0
        let cosLat = cos(point.lat * .pi / 180)
        func xy(_ p: LatLngPoint) -> (Double, Double) {
            ((p.lng - point.lng) * .pi / 180 * earth * cosLat, (p.lat - point.lat) * .pi / 180 * earth)
        }
        for (a, b) in zip(route, route.dropFirst()) where a.segment == b.segment {
            let (ax, ay) = xy(a), (bx, by) = xy(b)
            let dx = bx - ax, dy = by - ay
            let denom = dx * dx + dy * dy
            let t = denom == 0 ? 0 : min(1, max(0, (-ax * dx - ay * dy) / denom))
            best = min(best, hypot(ax + t * dx, ay + t * dy))
        }
        return best
    }
}
