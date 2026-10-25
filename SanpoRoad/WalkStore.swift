import Foundation
import Combine

@MainActor
final class WalkStore: ObservableObject {
    @Published private(set) var records: [SavedRoute] = []
    @Published var lastError: String?
    private let fm = FileManager.default

    private var storageURL: URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SanpoRoad", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = dir; try? mutable.setResourceValues(values)
        return dir.appendingPathComponent("routes.json")
    }

    init() { load() }

    func visibleRecords(accountId: String?) -> [SavedRoute] {
        records.filter { $0.deletedAt == nil && ($0.ownerId == nil || $0.ownerId == accountId) }.sorted { $0.startedAt > $1.startedAt }
    }

    func route(id: Int64, ownerId: String? = nil) -> SavedRoute? {
        records.first { $0.id == id && (ownerId == nil || $0.ownerId == ownerId) }
    }

    func add(_ record: SavedRoute, accountId: String?) {
        var route = record
        route.ownerId = route.ownerId ?? accountId
        route.updatedAt = nextStamp(after: route.updatedAt)
        route.syncState = "PENDING"
        route.photoHash = PhotoStore.shared.hash(path: route.photoPath)
        if records.contains(where: { $0.id == route.id && $0.ownerId == route.ownerId }) { route.id = uniqueID() }
        records.append(route)
        persist()
    }

    func update(_ record: SavedRoute) {
        guard let index = records.firstIndex(where: { $0.id == record.id && $0.ownerId == record.ownerId }) else { return }
        var copy = record
        copy.updatedAt = nextStamp(after: max(records[index].updatedAt, record.updatedAt))
        copy.syncState = "PENDING"
        copy.photoHash = PhotoStore.shared.hash(path: copy.photoPath)
        records[index] = copy
        persist()
    }

    func toggleFavorite(_ record: SavedRoute) {
        var copy = record; copy.favorite.toggle(); update(copy)
    }

    func claimForShare(_ record: SavedRoute, accountId: String) throws -> SavedRoute {
        guard record.deletedAt == nil else { throw AppError.message("削除した散歩は共有できません") }
        guard record.ownerId == nil || record.ownerId == accountId else { throw AppError.message("別のアカウントの記録は共有できません") }
        guard let index = records.firstIndex(where: { $0.id == record.id && $0.ownerId == record.ownerId }) else { throw AppError.message("記録が見つかりません") }
        records[index].ownerId = accountId
        records[index].updatedAt = nextStamp(after: records[index].updatedAt)
        records[index].syncState = "PENDING"
        let owned = records[index]
        persist()
        return owned
    }

    func delete(_ record: SavedRoute) {
        guard let index = records.firstIndex(where: { $0.id == record.id && $0.ownerId == record.ownerId }) else { return }
        let oldPhoto = records[index].photoPath
        let stamp = nextStamp(after: records[index].updatedAt)
        records[index] = SavedRoute(
            id: record.id, name: "削除済み", startedAt: record.startedAt, durationMs: 0, distanceMeters: 0,
            points: [], note: "", photoPath: nil, photoObjectPath: record.photoObjectPath, ownerId: record.ownerId,
            updatedAt: stamp, deletedAt: stamp, favorite: false, photoRemoved: true, syncState: "PENDING",
            photoHash: nil, syncedPhotoHash: record.syncedPhotoHash, sourceRouteId: nil, restDurationMs: 0,
            formatVersion: max(2, record.formatVersion), tags: [], imported: record.imported, importKey: record.importKey,
            gpsQuality: nil, restIntervals: []
        )
        persist()
        PhotoStore.shared.remove(path: oldPhoto)
    }

    func deleteAllVisible(accountId: String?) {
        for route in visibleRecords(accountId: accountId) { delete(route) }
    }

    func eraseLocalAccount(_ accountId: String) {
        let doomed = records.filter { $0.ownerId == accountId }
        doomed.forEach { PhotoStore.shared.remove(path: $0.photoPath) }
        records.removeAll { $0.ownerId == accountId }
        persist()
    }

    func adoptGuestRecords(accountId: String) {
        var used = Set(records.filter { $0.ownerId == accountId }.map(\.id))
        for index in records.indices where records[index].ownerId == nil {
            var route = records[index]
            if used.contains(route.id) { route.id = uniqueID(excluding: used) }
            used.insert(route.id)
            route.ownerId = accountId
            route.updatedAt = nextStamp(after: route.updatedAt)
            route.syncState = "PENDING"
            records[index] = route
        }
        persist()
    }

    func mergeRemote(_ remote: [SavedRoute], accountId: String) {
        var map: [String: SavedRoute] = [:]
        for local in records { map[key(local)] = local }
        for incoming in remote where incoming.ownerId == accountId {
            let k = key(incoming)
            guard let local = map[k] else { map[k] = incoming; continue }
            let winner: SavedRoute
            if incoming.deletedAt != nil && incoming.updatedAt >= local.updatedAt { winner = sanitizedTombstone(incoming) }
            else if local.deletedAt != nil && local.updatedAt >= incoming.updatedAt { winner = sanitizedTombstone(local) }
            else if incoming.updatedAt > local.updatedAt {
                var copy = incoming
                if copy.photoPath == nil, !copy.photoRemoved { copy.photoPath = local.photoPath }
                winner = copy
            } else { winner = local }
            map[k] = winner
        }
        records = Array(map.values)
        persist()
    }

    func replaceFromSync(_ route: SavedRoute) {
        if let index = records.firstIndex(where: { $0.id == route.id && $0.ownerId == route.ownerId }) { records[index] = route }
        else { records.append(route) }
        persist()
    }

    func markSynced(_ route: SavedRoute) {
        guard let i = records.firstIndex(where: { $0.id == route.id && $0.ownerId == route.ownerId }) else { return }
        records[i].syncState = "SYNCED"
        records[i].syncedPhotoHash = records[i].photoHash
        persist()
    }

    func importRoutes(_ routes: [SavedRoute], photos: [String: Data], accountId: String?) -> Int {
        var count = 0
        let existingKeys = Set(records.compactMap(\.importKey))
        var seen = existingKeys
        for original in routes where original.deletedAt == nil {
            var route = original
            let key = route.importKey ?? BackupExport.importFingerprint(route)
            if seen.contains(key) { continue }
            seen.insert(key)
            route.id = uniqueID()
            route.ownerId = accountId
            route.photoObjectPath = nil
            route.updatedAt = Date().epochMilliseconds
            route.deletedAt = nil
            route.syncState = "PENDING"
            route.syncedPhotoHash = nil
            route.sourceRouteId = nil
            route.imported = true
            route.importKey = key
            route.photoPath = nil
            if let photo = photos[String(original.id)] {
                route.photoPath = try? PhotoStore.shared.save(data: photo, routeID: route.id)
                route.photoHash = PhotoStore.shared.hash(path: route.photoPath)
            }
            records.append(route); count += 1
        }
        persist(); return count
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do { records = try JSONDecoder().decode([SavedRoute].self, from: data) }
        catch { lastError = "保存済み記録を読み込めませんでした: \(error.localizedDescription)" }
    }

    func persist() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: storageURL, options: .atomic)
        } catch { lastError = "記録を保存できませんでした: \(error.localizedDescription)" }
    }

    private func key(_ route: SavedRoute) -> String { "\(route.ownerId ?? "guest"):\(route.id)" }
    private func nextStamp(after value: Int64) -> Int64 { max(Date().epochMilliseconds, value + 1) }
    private func uniqueID(excluding extra: Set<Int64> = []) -> Int64 {
        var id = SavedRoute.newID()
        let used = Set(records.map(\.id)).union(extra)
        while used.contains(id) { id += Int64.random(in: 1...999) }
        return id
    }
    private func sanitizedTombstone(_ route: SavedRoute) -> SavedRoute {
        var copy = route
        copy.name = "削除済み"; copy.note = ""; copy.points = []; copy.distanceMeters = 0; copy.durationMs = 0
        copy.restDurationMs = 0; copy.tags = []; copy.favorite = false; copy.photoPath = nil; copy.photoHash = nil; copy.photoRemoved = true
        copy.gpsQuality = nil; copy.restIntervals = []
        return copy
    }
}
