import Foundation
import CoreLocation

struct RouteMath {
    static func distance(_ a: LatLngPoint, _ b: LatLngPoint) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lng).distance(from: CLLocation(latitude: b.lat, longitude: b.lng))
    }

    static func filterHistory(_ routes: [SavedRoute], query: String, sort: HistorySort, filter: HistoryFilter) -> [SavedRoute] {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0 == "　" }).map { $0.lowercased() }
        let result = routes.filter { route in
            guard route.deletedAt == nil, route.startedAt >= filter.since, route.distanceMeters >= filter.minimumMeters else { return false }
            if filter.photosOnly && !route.hasPhoto { return false }
            if filter.favoritesOnly && !route.favorite { return false }
            return words.allSatisfy { word in
                route.name.lowercased().contains(word) || route.note.lowercased().contains(word) || route.tags.contains { $0.lowercased().contains(word) }
            }
        }
        return result.sorted { a, b in
            switch sort {
            case .newest: return a.startedAt == b.startedAt ? a.id > b.id : a.startedAt > b.startedAt
            case .longest:
                if a.distanceMeters != b.distanceMeters { return a.distanceMeters > b.distanceMeters }
                return a.startedAt == b.startedAt ? a.id > b.id : a.startedAt > b.startedAt
            case .duration:
                if a.durationMs != b.durationMs { return a.durationMs > b.durationMs }
                return a.startedAt == b.startedAt ? a.id > b.id : a.startedAt > b.startedAt
            }
        }
    }

    static func stats(_ records: [SavedRoute], now: Date = Date(), calendar: Calendar = .current) -> WalkStatsSnapshot {
        let routes = records.filter { !$0.imported && $0.deletedAt == nil }
        guard !routes.isEmpty else { return .init() }
        let totalDistance = routes.reduce(0) { $0 + $1.distanceMeters }
        let totalDuration = routes.reduce(Int64(0)) { $0 + $1.durationMs }
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        let thisWeekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart
        let thisWeek = routes.filter { $0.startedDate >= thisWeekStart && $0.startedDate < (calendar.date(byAdding: .day, value: 1, to: today) ?? now) }
        let lastWeek = routes.filter { $0.startedDate >= lastWeekStart && $0.startedDate < thisWeekStart }

        let uniqueDays = Set(routes.map { calendar.startOfDay(for: $0.startedDate) }).sorted(by: >)
        var expected: Date?
        if uniqueDays.first == today { expected = today }
        else if uniqueDays.first == calendar.date(byAdding: .day, value: -1, to: today) { expected = uniqueDays.first }
        var streak = 0
        if var current = expected {
            for day in uniqueDays {
                if day != current { break }
                streak += 1
                current = calendar.date(byAdding: .day, value: -1, to: current) ?? current
            }
        }

        return WalkStatsSnapshot(
            totalDistanceMeters: totalDistance,
            totalDurationMs: totalDuration,
            totalWalks: routes.count,
            currentStreakDays: streak,
            thisWeekDistanceMeters: thisWeek.reduce(0) { $0 + $1.distanceMeters },
            thisWeekWalks: thisWeek.count,
            lastWeekDistanceMeters: lastWeek.reduce(0) { $0 + $1.distanceMeters },
            longestDistanceMeters: routes.map(\.distanceMeters).max() ?? 0,
            longestDurationMs: routes.map(\.durationMs).max() ?? 0,
            averageDistanceMeters: totalDistance / Double(routes.count),
            averageDurationMs: totalDuration / Int64(routes.count)
        )
    }

    static func weeklyDistances(_ records: [SavedRoute], count: Int = 8, now: Date = Date(), calendar: Calendar = .current) -> [WeeklyDistance] {
        let routes = records.filter { !$0.imported && $0.deletedAt == nil }
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let thisMonday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        return (0..<count).reversed().map { offset in
            let start = calendar.date(byAdding: .day, value: -7 * offset, to: thisMonday) ?? thisMonday
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
            let matches = routes.filter { $0.startedDate >= start && $0.startedDate < end }
            return WeeklyDistance(weekStart: start, distanceMeters: matches.reduce(0) { $0 + $1.distanceMeters }, walks: matches.count)
        }
    }

    static func month(_ records: [SavedRoute], containing date: Date, calendar: Calendar = .current) -> [CalendarDaySummary] {
        guard let interval = calendar.dateInterval(of: .month, for: date), let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let routes = records.filter { !$0.imported && $0.deletedAt == nil && $0.startedDate >= interval.start && $0.startedDate < interval.end }
        return days.compactMap { day in
            var comps = calendar.dateComponents([.year, .month], from: date); comps.day = day
            guard let d = calendar.date(from: comps) else { return nil }
            let next = calendar.date(byAdding: .day, value: 1, to: d) ?? d
            let matching = routes.filter { $0.startedDate >= d && $0.startedDate < next }
            return CalendarDaySummary(date: d, distanceMeters: matching.reduce(0) { $0 + $1.distanceMeters }, walks: matching.count)
        }
    }

    static func sameCourse(_ a: SavedRoute, _ b: SavedRoute) -> Bool {
        guard let aStart = a.points.first, let aEnd = a.points.last, let bStart = b.points.first, let bEnd = b.points.last else { return false }
        guard distance(aStart, bStart) <= 80, distance(aEnd, bEnd) <= 80 else { return false }
        let maxDistance = max(a.distanceMeters, b.distanceMeters, 1)
        guard abs(a.distanceMeters - b.distanceMeters) / maxDistance <= 0.15 else { return false }
        return mutualCoverage(a.points, b.points, threshold: 50) >= 0.85
    }

    private static func mutualCoverage(_ a: [LatLngPoint], _ b: [LatLngPoint], threshold: Double) -> Double {
        min(coverage(a, by: b, threshold: threshold), coverage(b, by: a, threshold: threshold))
    }

    private static func coverage(_ source: [LatLngPoint], by target: [LatLngPoint], threshold: Double) -> Double {
        guard !source.isEmpty, !target.isEmpty else { return 0 }
        let strideValue = max(1, source.count / 128)
        let sampled = stride(from: 0, to: source.count, by: strideValue).map { source[$0] }
        let matched = sampled.filter { point in
            target.contains { other in point.segment == other.segment && distance(point, other) <= threshold }
        }.count
        return Double(matched) / Double(sampled.count)
    }

    static func compare(_ current: SavedRoute, _ previous: SavedRoute) -> [RouteMetric] {
        [
            RouteMetric(label: "距離", current: current.distanceMeters / 1000, previous: previous.distanceMeters / 1000, unit: "km"),
            RouteMetric(label: "経過時間", current: Double(current.elapsedMs) / 60_000, previous: Double(previous.elapsedMs) / 60_000, unit: "分", lowerIsBetter: true),
            RouteMetric(label: "歩行時間", current: Double(current.durationMs) / 60_000, previous: Double(previous.durationMs) / 60_000, unit: "分", lowerIsBetter: true),
            RouteMetric(label: "平均ペース", current: current.averagePaceMinutesPerKm, previous: previous.averagePaceMinutesPerKm, unit: "分/km", lowerIsBetter: true),
            RouteMetric(label: "休憩", current: Double(current.restDurationMs) / 60_000, previous: Double(previous.restDurationMs) / 60_000, unit: "分", lowerIsBetter: true),
            RouteMetric(label: "GPS推定誤差", current: current.gpsQuality?.medianAccuracyM, previous: previous.gpsQuality?.medianAccuracyM, unit: "m", lowerIsBetter: true)
        ]
    }

    static func maskForSharing(_ points: [LatLngPoint], radiusMeters: Double = 150) -> [LatLngPoint] {
        precondition(radiusMeters >= 100)
        guard let start = points.first, let end = points.last else { return [] }
        var result: [LatLngPoint] = []
        var newSegment = 0
        var hidden = true
        var originalSegment: Int?
        for var point in points {
            if distance(start, point) <= radiusMeters || distance(end, point) <= radiusMeters {
                hidden = true
                continue
            }
            if hidden || originalSegment != point.segment { newSegment += 1 }
            hidden = false; originalSegment = point.segment
            point.timeMs = 0; point.accuracyM = nil; point.segment = newSegment
            result.append(point)
        }
        return result
    }
}
