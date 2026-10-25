import SwiftUI

struct HistoryScreen: View {
    @EnvironmentObject private var store: WalkStore
    @EnvironmentObject private var preferences: WalkPreferences
    @EnvironmentObject private var recorder: LocationRecorder
    @Binding var selectedTab: Int
    @State private var query = ""
    @State private var sort: HistorySort = .newest
    @State private var recentOnly = false
    @State private var longOnly = false
    @State private var photosOnly = false
    @State private var favoritesOnly = false
    @State private var selectedRoute: SavedRoute?

    private var all: [SavedRoute] { store.visibleRecords(accountId: preferences.activeAccountId) }
    private var visible: [SavedRoute] {
        RouteMath.filterHistory(all, query: query, sort: sort, filter: HistoryFilter(
            since: recentOnly ? Date().addingTimeInterval(-30 * 86400).epochMilliseconds : 0,
            minimumMeters: longOnly ? 3000 : 0,
            photosOnly: photosOnly,
            favoritesOnly: favoritesOnly
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("名前・メモ・タグで検索", text: $query)
                    Picker("並び順", selection: $sort) { ForEach(HistorySort.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            FilterButton(title: "30日以内", active: $recentOnly)
                            FilterButton(title: "3km以上", active: $longOnly)
                            FilterButton(title: "写真あり", active: $photosOnly)
                            FilterButton(title: "お気に入り", active: $favoritesOnly)
                        }
                    }
                    Text("\(visible.count)件 / 全\(all.count)件").font(.caption).foregroundStyle(.secondary)
                }
                if all.isEmpty {
                    Section {
                        ContentUnavailableView("最初の一歩を残そう", systemImage: "figure.walk", description: Text("散歩を保存すると、歩いた道や写真、メモをここから振り返れます。"))
                        Button("散歩の画面へ") { selectedTab = 0 }
                    }
                } else if visible.isEmpty {
                    ContentUnavailableView("記録が見つかりません", systemImage: "magnifyingglass", description: Text("検索条件やフィルターを変更してください。"))
                } else {
                    ForEach(visible) { route in
                        Button { selectedRoute = route } label: { HistoryRow(route: route) }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("散歩の記録")
            .sheet(item: $selectedRoute) { route in
                RouteDetailView(routeID: route.id, ownerId: route.ownerId) {
                    recorder.prepareRepeat($0); selectedRoute = nil; selectedTab = 0
                }
            }
        }
    }
}

private struct FilterButton: View {
    let title: String
    @Binding var active: Bool
    var body: some View {
        Button { active.toggle() } label: {
            Text(title).font(.caption).padding(.horizontal, 11).padding(.vertical, 7)
                .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
        }.buttonStyle(.plain)
    }
}

private struct HistoryRow: View {
    let route: SavedRoute
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(route.startedDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if route.imported { Text("インポート").font(.caption2).padding(4).background(.secondary.opacity(0.12), in: Capsule()) }
                if route.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            }
            Text(route.name).font(.headline).lineLimit(2)
            if route.hasPhoto { RoutePhotoView(path: route.photoPath, height: 120) }
            HStack { Text(formatKm(route.distanceMeters)); Text("・"); Text(formatDuration(route.elapsedMs)); Spacer(); Text(formatPace(route.averagePaceMinutesPerKm)) }.font(.subheadline)
            if !route.tags.isEmpty { Text(route.tags.map { "#\($0)" }.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if !route.note.isEmpty { Text(route.note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(.vertical, 5)
    }
}
