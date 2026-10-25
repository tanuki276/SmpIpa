import Foundation
import Combine
import Supabase

@MainActor
final class CloudService: ObservableObject {
    static let supabaseURL = URL(string: "https://djkolanmyxvqmegqpvlp.supabase.co")!
    static let publishableKey = "sb_publishable_BkB1dj8UPD9cxgpfhJT5IA__tEsmfoe"
    static let shareAPIURL = URL(string: "https://sanpo-road-share.vercel.app/api/share")!
    private let photoBucket = "walk-photos"

    let client: SupabaseClient
    @Published private(set) var accountId: String?
    @Published private(set) var email: String?
    @Published private(set) var syncStatus = "クラウド同期はOFFです"
    @Published private(set) var busy = false

    init() {
        client = SupabaseClient(supabaseURL: Self.supabaseURL, supabaseKey: Self.publishableKey)
        Task { await refreshSession() }
    }

    func refreshSession() async {
        do {
            let session = try await client.auth.session
            apply(session)
        } catch {
            accountId = nil; email = nil
        }
    }

    @discardableResult
    func signInWithGoogle() async throws -> String {
        let session = try await client.auth.signInWithOAuth(provider: .google, redirectTo: URL(string: "sanporoad://auth")!)
        apply(session)
        return session.user.id.uuidString.lowercased()
    }

    func logout() async throws {
        try await client.auth.signOut()
        accountId = nil; email = nil
    }

    func sync(store: WalkStore, preferences: WalkPreferences) async throws {
        guard preferences.cloudSync else { syncStatus = "クラウド同期はOFFです"; return }
        guard !busy else { return }
        busy = true; defer { busy = false }
        let session = try await client.auth.session
        apply(session)
        let user = session.user.id.uuidString.lowercased()
        preferences.activeAccountId = user
        preferences.accountEmail = session.user.email
        syncStatus = "クラウドを確認中…"

        let remote = try await pullRoutes(user: user)
        store.adoptGuestRecords(accountId: user)
        store.mergeRemote(remote, accountId: user)

        var uploaded = 0
        for route in store.records where route.ownerId == user && route.syncState != "SYNCED" {
            var copy = route
            if route.deletedAt != nil || route.photoRemoved {
                try? await deleteRemotePhotos(route: route, user: user)
                copy.photoObjectPath = nil
            } else if preferences.photoSync, let path = route.photoPath, route.photoHash != route.syncedPhotoHash {
                let object = "\(user)/\(route.id).\(URL(fileURLWithPath: path).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: path).pathExtension)"
                try await uploadPhoto(localPath: path, objectPath: object)
                copy.photoObjectPath = object
            }
            try await pushRoute(copy, user: user, syncPhotos: preferences.photoSync)
            copy.syncState = "SYNCED"
            if preferences.photoSync { copy.syncedPhotoHash = copy.photoHash }
            store.replaceFromSync(copy)
            uploaded += 1
        }

        let latest = try await pullRoutes(user: user)
        store.mergeRemote(latest, accountId: user)
        if preferences.photoSync {
            for route in store.visibleRecords(accountId: user) where route.ownerId == user && route.photoPath == nil && route.photoObjectPath != nil {
                if let restored = try? await restorePhoto(for: route) { store.replaceFromSync(restored) }
            }
        }
        syncStatus = "同期済み（送信 \(uploaded)件 / クラウド \(latest.filter { $0.deletedAt == nil }.count)件）"
    }

    func createShare(route: SavedRoute, showMap: Bool, includeNote: Bool, expiryDays: Int?) async throws -> URL {
        let session = try await client.auth.session
        apply(session)
        let user = session.user.id.uuidString.lowercased()
        guard route.ownerId == nil || route.ownerId == user else { throw AppError.message("別のアカウントの記録は共有できません") }
        let points = showMap ? RouteMath.maskForSharing(route.points) : []
        let expiry: String? = expiryDays.flatMap { days in ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(days) * 86400)) }
        let params = ShareRPC(
            pRouteLocalId: route.id,
            pName: route.name,
            pStartedAt: ISO8601DateFormatter().string(from: route.startedDate),
            pDurationMs: route.durationMs,
            pDistanceMeters: route.distanceMeters,
            pPoints: points,
            pNote: includeNote ? route.note : "",
            pShareMap: showMap,
            pExpiresAt: expiry
        )
        let data = try await request(path: "/rest/v1/rpc/create_sanpo_share_v2", method: "POST", body: try JSONEncoder().encode(params))
        let token = try JSONDecoder().decode(String.self, from: data)
        return shareURL(token: token)
    }

    func listShares() async throws -> [ManagedShare] {
        let session = try await client.auth.session
        apply(session)
        let user = session.user.id.uuidString.lowercased()
        var all: [ManagedShare] = []
        var offset = 0
        while true {
            let query = [
                URLQueryItem(name: "owner_id", value: "eq.\(user)"),
                URLQueryItem(name: "order", value: "token.asc"),
                URLQueryItem(name: "limit", value: "500"),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            let data = try await request(path: "/rest/v1/sanpo_shares", query: query)
            let page = try JSONDecoder().decode([ManagedShare].self, from: data)
            all += page
            if page.count < 500 { break }
            offset += page.count
        }
        return all.sorted { $0.createdAt > $1.createdAt }
    }

    func revokeShare(token: String) async throws {
        let session = try await client.auth.session
        let user = session.user.id.uuidString.lowercased()
        _ = try await request(path: "/rest/v1/sanpo_shares", method: "DELETE", query: [
            URLQueryItem(name: "owner_id", value: "eq.\(user)"), URLQueryItem(name: "token", value: "eq.\(token)")
        ], preferRepresentation: false)
    }

    func deleteAccount() async throws {
        do {
            _ = try await request(path: "/functions/v1/sanpo-delete-account", method: "POST", body: Data("{\"confirm\":\"DELETE\"}".utf8))
            try? await client.auth.signOut()
            accountId = nil; email = nil
        } catch let error as HTTPServiceError where error.statusCode == 409 {
            throw AppError.message("同じ認証アカウントが別サービスでも使われています。運営者に削除を依頼してください。")
        }
    }

    func shareURL(token: String) -> URL {
        URL(string: "https://sanpo-road-share.vercel.app/s/\(token)")!
    }

    private func apply(_ session: Session) {
        accountId = session.user.id.uuidString.lowercased()
        email = session.user.email
    }

    private func pullRoutes(user: String) async throws -> [SavedRoute] {
        var all: [RemoteRoute] = []
        var offset = 0
        while true {
            let data = try await request(path: "/rest/v1/sanpo_routes", query: [
                URLQueryItem(name: "user_id", value: "eq.\(user)"),
                URLQueryItem(name: "order", value: "local_id.asc"),
                URLQueryItem(name: "limit", value: "500"),
                URLQueryItem(name: "offset", value: String(offset))
            ])
            let page = try JSONDecoder().decode([RemoteRoute].self, from: data)
            all += page
            if page.count < 500 { break }
            offset += page.count
        }
        return all.map { $0.local }
    }

    private func pushRoute(_ route: SavedRoute, user: String, syncPhotos: Bool) async throws {
        let remote = RemoteRoute(local: route, user: user, photoObjectPath: route.photoObjectPath, photoHash: syncPhotos ? route.photoHash : route.syncedPhotoHash)
        let wrapper = RouteRPC(pRoute: remote)
        _ = try await request(path: "/rest/v1/rpc/upsert_sanpo_route_v3", method: "POST", body: try JSONEncoder().encode(wrapper), preferRepresentation: false)
    }

    private func uploadPhoto(localPath: String, objectPath: String) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
        let ext = URL(fileURLWithPath: localPath).pathExtension.lowercased()
        let contentType = ext == "png" ? "image/png" : ext == "webp" ? "image/webp" : "image/jpeg"
        let encoded = objectPath.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        _ = try await request(path: "/storage/v1/object/\(photoBucket)/\(encoded)", method: "POST", body: data, extraHeaders: ["Content-Type": contentType, "x-upsert": "true"], preferRepresentation: false)
    }

    private func deleteRemotePhotos(route: SavedRoute, user: String) async throws {
        var paths = ["\(user)/\(route.id).jpg", "\(user)/\(route.id).png", "\(user)/\(route.id).webp"]
        if let p = route.photoObjectPath { paths.append(p) }
        let body = try JSONSerialization.data(withJSONObject: ["prefixes": Array(Set(paths))])
        _ = try await request(path: "/storage/v1/object/\(photoBucket)", method: "DELETE", body: body, preferRepresentation: false)
    }

    private func restorePhoto(for route: SavedRoute) async throws -> SavedRoute? {
        guard let object = route.photoObjectPath, route.photoPath == nil else { return nil }
        let encoded = object.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let data = try await request(path: "/storage/v1/object/authenticated/\(photoBucket)/\(encoded)")
        var copy = route
        copy.photoPath = try PhotoStore.shared.save(data: data, routeID: route.id, ext: URL(fileURLWithPath: object).pathExtension)
        copy.photoHash = PhotoStore.shared.hash(path: copy.photoPath)
        copy.syncedPhotoHash = copy.photoHash
        copy.syncState = "SYNCED"
        return copy
    }

    private func request(path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [], extraHeaders: [String: String] = [:], preferRepresentation: Bool = true) async throws -> Data {
        let session = try await client.auth.session
        let base = Self.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: base + "/" + cleanPath)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil && extraHeaders["Content-Type"] == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if preferRepresentation && method != "GET" { request.setValue("return=representation", forHTTPHeaderField: "Prefer") }
        extraHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw HTTPServiceError(statusCode: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

struct HTTPServiceError: LocalizedError {
    let statusCode: Int
    let body: String
    var errorDescription: String? { "通信エラー (\(statusCode)): \(body)" }
}

private struct RouteRPC: Encodable {
    let pRoute: RemoteRoute
    enum CodingKeys: String, CodingKey { case pRoute = "p_route" }
}

private struct ShareRPC: Encodable {
    let pRouteLocalId: Int64
    let pName: String
    let pStartedAt: String
    let pDurationMs: Int64
    let pDistanceMeters: Double
    let pPoints: [LatLngPoint]
    let pNote: String
    let pShareMap: Bool
    let pExpiresAt: String?
    enum CodingKeys: String, CodingKey {
        case pRouteLocalId = "p_route_local_id", pName = "p_name", pStartedAt = "p_started_at"
        case pDurationMs = "p_duration_ms", pDistanceMeters = "p_distance_meters", pPoints = "p_points"
        case pNote = "p_note", pShareMap = "p_share_map", pExpiresAt = "p_expires_at"
    }
}

private struct RemoteRoute: Codable {
    var userId: String
    var localId: Int64
    var name: String
    var startedAt: String
    var durationMs: Int64
    var distanceMeters: Double
    var points: [LatLngPoint]
    var note: String
    var photoObjectPath: String?
    var updatedAt: Int64
    var deletedAt: Int64?
    var favorite: Bool
    var photoHash: String?
    var sourceRouteId: Int64?
    var restDurationMs: Int64
    var tags: [String]
    var imported: Bool
    var importKey: String?
    var gpsQuality: GpsQualityReport?
    var restIntervals: [RestInterval]

    enum CodingKeys: String, CodingKey {
        case userId = "user_id", localId = "local_id", name, startedAt = "started_at"
        case durationMs = "duration_ms", distanceMeters = "distance_meters", points, note
        case photoObjectPath = "photo_object_path", updatedAt = "client_updated_at", deletedAt = "deleted_at", favorite
        case photoHash = "photo_hash", sourceRouteId = "source_route_id", restDurationMs = "rest_duration_ms"
        case tags, imported, importKey = "import_key", gpsQuality = "gps_quality", restIntervals = "rest_intervals"
    }

    init(local: SavedRoute, user: String, photoObjectPath: String?, photoHash: String?) {
        userId = user; localId = local.id; name = local.name
        startedAt = ISO8601DateFormatter().string(from: local.startedDate)
        durationMs = local.durationMs; distanceMeters = local.distanceMeters; points = local.points; note = local.note
        self.photoObjectPath = photoObjectPath; updatedAt = local.updatedAt; deletedAt = local.deletedAt; favorite = local.favorite
        self.photoHash = photoHash; sourceRouteId = local.sourceRouteId; restDurationMs = local.restDurationMs; tags = local.tags
        imported = local.imported; importKey = local.importKey; gpsQuality = local.gpsQuality; restIntervals = local.restIntervals
    }

    var local: SavedRoute {
        let date = ISO8601DateFormatter().date(from: startedAt) ?? Date(timeIntervalSince1970: 0)
        return SavedRoute(id: localId, name: name, startedAt: date.epochMilliseconds, durationMs: durationMs,
                          distanceMeters: distanceMeters, points: points, note: note, photoPath: nil,
                          photoObjectPath: photoObjectPath, ownerId: userId, updatedAt: updatedAt, deletedAt: deletedAt,
                          favorite: favorite, syncState: "SYNCED", photoHash: photoHash, syncedPhotoHash: photoHash,
                          sourceRouteId: sourceRouteId, restDurationMs: restDurationMs, tags: tags, imported: imported,
                          importKey: importKey, gpsQuality: gpsQuality, restIntervals: restIntervals)
    }
}
