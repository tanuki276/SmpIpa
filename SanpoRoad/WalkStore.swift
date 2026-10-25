import Foundation
import Combine

@MainActor
final class WalkStore: ObservableObject {
    @Published private(set) var records: [WalkRecord] = []
    private let storageKey = "sanporoad.walks.v1"

    init() {
        load()
    }

    func add(_ record: WalkRecord) {
        records.insert(record, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            records.remove(at: index)
        }
        save()
    }

    func toggleFavorite(_ record: WalkRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].favorite.toggle()
        save()
    }

    var totalDistanceMeters: Double {
        records.reduce(0) { $0 + $1.distanceMeters }
    }

    var totalDuration: TimeInterval {
        records.reduce(0) { $0 + $1.duration }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WalkRecord].self, from: data) else { return }
        records = decoded.sorted { $0.startedAt > $1.startedAt }
    }
}
