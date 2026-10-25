import Foundation
import CryptoKit

struct BackupPhoto: Codable {
    var routeId: Int64
    var base64: String
}

struct SanpoBackup: Codable {
    var kind = "SANPO-ROAD"
    var version = 1
    var routes: [SavedRoute]
    var photos: [BackupPhoto] = []
}

enum BackupExport {
    static let maxBytes = 50 * 1024 * 1024

    static func encodeBackup(routes: [SavedRoute]) throws -> Data {
        let visible = routes.filter { $0.deletedAt == nil }
        var photos: [BackupPhoto] = []
        var cleaned: [SavedRoute] = []
        for route in visible {
            let localPhoto = PhotoStore.shared.data(path: route.photoPath)
            if route.photoObjectPath != nil && localPhoto == nil {
                throw AppError.message("端末にない写真があります。写真を端末に復元してからバックアップしてください")
            }
            if let localPhoto {
                guard localPhoto.count <= 10 * 1024 * 1024 else { throw AppError.message("写真が大きすぎます") }
                photos.append(BackupPhoto(routeId: route.id, base64: localPhoto.base64EncodedString()))
            }
            var copy = route
            copy.ownerId = nil; copy.photoPath = nil; copy.photoObjectPath = nil
            copy.syncState = "PENDING"; copy.syncedPhotoHash = nil
            cleaned.append(copy)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SanpoBackup(routes: cleaned, photos: photos))
        guard data.count <= maxBytes else { throw AppError.message("バックアップが50MBを超えます") }
        return data
    }

    static func decodeBackup(_ data: Data) throws -> (routes: [SavedRoute], photos: [String: Data]) {
        guard data.count <= maxBytes else { throw AppError.message("JSONは50MBまでです") }
        let decoder = JSONDecoder()
        let backup: SanpoBackup
        if let first = String(data: data.prefix(64), encoding: .utf8)?.drop(while: { $0.isWhitespace }).first, first == "[" {
            backup = SanpoBackup(routes: try decoder.decode([SavedRoute].self, from: data))
        } else {
            backup = try decoder.decode(SanpoBackup.self, from: data)
        }
        guard backup.kind == "SANPO-ROAD", backup.version == 1 else { throw AppError.message("未対応のSANPOバックアップです") }
        guard backup.routes.count <= 10_000, backup.routes.reduce(Int64(0), { $0 + Int64($1.points.count) }) <= 500_000 else { throw AppError.message("記録数が多すぎます") }
        guard Set(backup.routes.map(\.id)).count == backup.routes.count else { throw AppError.message("記録IDが重複しています") }
        for route in backup.routes {
            guard route.id > 0, route.startedAt > 0, route.formatVersion <= 2,
                  (0...604_800_000).contains(route.durationMs), (0...604_800_000).contains(route.restDurationMs),
                  route.distanceMeters.isFinite, (0...1_000_000).contains(route.distanceMeters),
                  route.name.count <= 1000, route.note.count <= 10_000,
                  route.tags.count <= 20, route.tags.allSatisfy({ $0.count <= 30 }) else { throw AppError.message("不正な記録です") }
            guard route.points.allSatisfy({ p in
                p.lat.isFinite && p.lng.isFinite && (-90...90).contains(p.lat) && (-180...180).contains(p.lng) && p.timeMs >= 0 && (p.accuracyM == nil || (p.accuracyM!.isFinite && p.accuracyM! > 0))
            }) else { throw AppError.message("不正なGPS座標です") }
        }
        guard Set(backup.photos.map(\.routeId)).count == backup.photos.count,
              backup.photos.allSatisfy({ photo in backup.routes.contains(where: { $0.id == photo.routeId }) }) else { throw AppError.message("写真情報が不正です") }
        var photos: [String: Data] = [:]
        for photo in backup.photos {
            guard let bytes = Data(base64Encoded: photo.base64), bytes.count <= 10 * 1024 * 1024 else { throw AppError.message("写真が大きすぎるか破損しています") }
            photos[String(photo.routeId)] = bytes
        }
        var routes = backup.routes
        for i in routes.indices {
            routes[i].importKey = importFingerprint(routes[i])
            routes[i].ownerId = nil; routes[i].photoPath = nil; routes[i].photoObjectPath = nil
            routes[i].photoHash = nil; routes[i].syncedPhotoHash = nil; routes[i].updatedAt = 0
            routes[i].deletedAt = nil; routes[i].syncState = "PENDING"; routes[i].sourceRouteId = nil; routes[i].imported = true
        }
        return (routes, photos)
    }

    static func importFingerprint(_ route: SavedRoute) -> String {
        if let key = route.importKey, key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil { return key }
        return SHA256.hash(data: Data("SANPO:\(route.id):\(route.startedAt)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func gpx(routes: [SavedRoute]) -> Data {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let iso = ISO8601DateFormatter()
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"SANPO-ROAD iOS\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        for route in routes where route.deletedAt == nil {
            out += "<trk><name>\(esc(route.name))</name><desc>\(esc(route.note))</desc>"
            for group in Dictionary(grouping: route.points, by: \.segment).sorted(by: { $0.key < $1.key }) {
                out += "<trkseg>"
                for point in group.value {
                    out += "<trkpt lat=\"\(point.lat)\" lon=\"\(point.lng)\">"
                    if point.timeMs > 0 { out += "<time>\(iso.string(from: Date(timeIntervalSince1970: TimeInterval(point.timeMs)/1000)))</time>" }
                    out += "</trkpt>"
                }
                out += "</trkseg>"
            }
            out += "</trk>\n"
        }
        out += "</gpx>"
        return Data(out.utf8)
    }

    static func csv(routes: [SavedRoute]) -> Data {
        func safe(_ value: String) -> String {
            var v = value
            if let first = v.first, ["=", "+", "-", "@"].contains(first) { v = "'" + v }
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["id,name,started_at,duration_ms,distance_meters,note,favorite"]
        let iso = ISO8601DateFormatter()
        for r in routes where r.deletedAt == nil {
            lines.append([String(r.id), safe(r.name), safe(iso.string(from: r.startedDate)), String(r.durationMs), String(format: "%.3f", r.distanceMeters), safe(r.note), String(r.favorite)].joined(separator: ","))
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data(lines.joined(separator: "\r\n").utf8)
    }

    static func temporaryFile(data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SanpoRoadExports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
