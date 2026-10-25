import Foundation
import CryptoKit

struct PhotoStore {
    static let shared = PhotoStore()
    private let fm = FileManager.default

    private var directory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("walk_photos", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = url; try? mutable.setResourceValues(values)
        return url
    }

    func save(data: Data, routeID: Int64, ext: String = "jpg") throws -> String {
        guard data.count <= 10 * 1024 * 1024 else { throw AppError.message("写真は10MBまでです") }
        let safeExt = ["jpg", "jpeg", "png", "webp", "heic"].contains(ext.lowercased()) ? ext.lowercased() : "jpg"
        let url = directory.appendingPathComponent("\(routeID)-\(UUID().uuidString).\(safeExt)")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    func data(path: String?) -> Data? {
        guard let path, fm.fileExists(atPath: path) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    func hash(path: String?) -> String? {
        guard let data = data(path: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func remove(path: String?) {
        guard let path, fm.fileExists(atPath: path) else { return }
        try? fm.removeItem(atPath: path)
    }

    func fileURL(path: String?) -> URL? {
        guard let path, fm.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
