import SwiftUI
import PhotosUI
import UIKit

struct RouteDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WalkStore
    @EnvironmentObject private var preferences: WalkPreferences
    @EnvironmentObject private var health: HealthKitManager
    let routeID: Int64
    let ownerId: String?
    let onRepeat: (SavedRoute) -> Void
    @State private var showEdit = false
    @State private var showShare = false
    @State private var showCompare = false
    @State private var exportFile: ShareFile?
    @State private var healthSummary: HealthSummary?

    private var route: SavedRoute? { store.records.first { $0.id == routeID && $0.ownerId == ownerId } }

    var body: some View {
        NavigationStack {
            Group {
                if let route {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            RouteMapView(points: route.points, height: 340)
                            RoutePhotoView(path: route.photoPath)
                            HStack { MetricPill(title: "距離", value: formatKm(route.distanceMeters)); MetricPill(title: "歩行", value: formatDuration(route.durationMs)); MetricPill(title: "休憩", value: formatDuration(route.restDurationMs)) }
                            HStack { MetricPill(title: "経過", value: formatDuration(route.elapsedMs)); MetricPill(title: "ペース", value: formatPace(route.averagePaceMinutesPerKm)); MetricPill(title: "GPS", value: route.gpsQuality?.confidence ?? "--") }
                            if !route.tags.isEmpty { Text(route.tags.map { "#\($0)" }.joined(separator: "  ")).font(.subheadline).foregroundStyle(.secondary) }
                            if route.imported { MessageBanner(text: "インポート記録です。週間目標や自己記録の集計からは除外されます。") }
                            if let source = route.sourceRouteId { MessageBanner(text: "再歩行元 #\(source)") }
                            if !route.note.isEmpty { GroupBox("メモ") { Text(route.note).frame(maxWidth: .infinity, alignment: .leading) } }
                            if let quality = route.gpsQuality {
                                GroupBox("GPS品質") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("判定: \(quality.confidence)")
                                        Text("採用 \(quality.acceptedPoints)点 / 除外 \(quality.excludedPoints)点")
                                        Text("精度中央値: \(quality.medianAccuracyM.map { String(format: "%.1fm", $0) } ?? "--")")
                                        Text("生距離 \(formatKm(quality.rawDistanceMeters)) → 採用距離 \(formatKm(quality.filteredDistanceMeters))")
                                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            HealthRoutePanel(summary: healthSummary)
                            actionGrid(route)
                        }.padding()
                    }
                    .task { healthSummary = await health.summary(route: route) }
                } else { ContentUnavailableView("記録が見つかりません", systemImage: "exclamationmark.triangle") }
            }
            .navigationTitle(route?.name ?? "散歩")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .sheet(isPresented: $showEdit) { if let route { RouteEditorView(route: route) } }
            .sheet(isPresented: $showShare) { if let route { ShareRouteView(route: route) } }
            .sheet(isPresented: $showCompare) { if let route { RouteCompareView(route: route) } }
            .sheet(item: $exportFile) { item in ActivityView(items: [item.url]) }
        }
    }

    @ViewBuilder private func actionGrid(_ route: SavedRoute) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button { onRepeat(route) } label: { Label("もう一度歩く", systemImage: "figure.walk") }.frame(maxWidth: .infinity)
                Button { showCompare = true } label: { Label("比較", systemImage: "arrow.left.arrow.right") }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
            HStack {
                Button { showShare = true } label: { Label("共有", systemImage: "square.and.arrow.up") }.frame(maxWidth: .infinity)
                Button { store.toggleFavorite(route) } label: { Label(route.favorite ? "お気に入り解除" : "お気に入り", systemImage: route.favorite ? "heart.fill" : "heart") }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
            HStack {
                Button { showEdit = true } label: { Label("編集・削除", systemImage: "pencil") }.frame(maxWidth: .infinity)
                Button { do { exportFile = ShareFile(url: try BackupExport.temporaryFile(data: BackupExport.gpx(routes: [route]), name: "sanpo-\(route.id).gpx")) } catch {} } label: { Label("GPX", systemImage: "map") }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
        }
    }
}

private struct HealthRoutePanel: View {
    let summary: HealthSummary?
    var body: some View {
        GroupBox("ヘルスケア（端末内のみ）") {
            if let summary {
                HStack {
                    MetricPill(title: "歩数", value: summary.steps.map { String(format: "%.0f", $0) } ?? "--")
                    MetricPill(title: "平均心拍", value: summary.averageHeartRate.map { String(format: "%.0f bpm", $0) } ?? "--")
                    MetricPill(title: "消費", value: summary.activeCalories.map { String(format: "%.0f kcal", $0) } ?? "--")
                }
            } else { Text("HealthKitの許可状況に応じて歩数・平均心拍・アクティブエネルギーを表示します。").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct RouteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WalkStore
    @State var route: SavedRoute
    @State private var name: String
    @State private var note: String
    @State private var tags: String
    @State private var photoItem: PhotosPickerItem?
    @State private var newPhoto: Data?
    @State private var removePhoto = false
    @State private var deleteConfirm = false
    @State private var error: String?

    init(route: SavedRoute) {
        _route = State(initialValue: route); _name = State(initialValue: route.name); _note = State(initialValue: route.note); _tags = State(initialValue: route.tags.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("記録") {
                    TextField("名前", text: $name)
                    TextField("メモ", text: $note, axis: .vertical).lineLimit(3...8)
                    TextField("タグ（カンマ区切り）", text: $tags)
                }
                Section("写真") {
                    RoutePhotoView(path: removePhoto ? nil : route.photoPath, height: 120)
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("写真を選ぶ", systemImage: "photo") }
                    if route.hasPhoto && !removePhoto { Button("写真を外す", role: .destructive) { removePhoto = true; newPhoto = nil } }
                }
                Section { Button("この記録を削除", role: .destructive) { deleteConfirm = true } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("編集")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } } }
            .confirmationDialog("記録を削除しますか？", isPresented: $deleteConfirm) {
                Button("削除", role: .destructive) { store.delete(route); dismiss() }
            } message: { Text("クラウド同期がONなら削除情報も同期されます。") }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { do { newPhoto = try await item.loadTransferable(type: Data.self); removePhoto = false } catch { self.error = error.localizedDescription } }
            }
        }
    }

    private func save() {
        do {
            route.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)); route.note = String(note.prefix(10_000))
            route.tags = tags.split(whereSeparator: { $0 == "," || $0 == "、" || $0.isNewline }).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)) }.filter { !$0.isEmpty }.prefix(20).map { $0 }
            if removePhoto { PhotoStore.shared.remove(path: route.photoPath); route.photoPath = nil; route.photoHash = nil; route.photoRemoved = true }
            if let newPhoto { PhotoStore.shared.remove(path: route.photoPath); route.photoPath = try PhotoStore.shared.save(data: newPhoto, routeID: route.id); route.photoHash = PhotoStore.shared.hash(path: route.photoPath); route.photoRemoved = false }
            store.update(route); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct RouteCompareView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WalkStore
    @EnvironmentObject private var preferences: WalkPreferences
    let route: SavedRoute
    @State private var selectedID: Int64?
    private var candidates: [SavedRoute] { store.visibleRecords(accountId: preferences.activeAccountId).filter { $0.id != route.id && $0.ownerId == route.ownerId } }
    private var selected: SavedRoute? { candidates.first { $0.id == selectedID } ?? candidates.first { $0.id == route.sourceRouteId } ?? candidates.first }

    var body: some View {
        NavigationStack {
            List {
                Section { Text("ペースは速さの比較です。無理のない散歩を心がけてください。").font(.caption) }
                if let selected {
                    Section("比較先: \(selected.name)") {
                        Text(RouteMath.sameCourse(route, selected) ? "同一コースの目安に一致" : "異なるコース・判定条件外")
                        ForEach(RouteMath.compare(route, selected)) { metric in
                            VStack(alignment: .leading) {
                                Text(metric.label).font(.headline)
                                Text("今回 \(metric.current.map { String(format: "%.1f", $0) } ?? "--") / 過去 \(metric.previous.map { String(format: "%.1f", $0) } ?? "--") \(metric.unit)")
                                Text("\(metric.assessment) \(metric.delta.map { String(format: "%+.1f", $0) } ?? "--")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("比較する記録") {
                    ForEach(candidates) { c in Button { selectedID = c.id } label: { HStack { Text(c.name); Spacer(); if RouteMath.sameCourse(route, c) { Text("同じコース").font(.caption).foregroundStyle(.secondary) } } } }
                }
            }.navigationTitle("過去記録と比較").toolbar { Button("閉じる") { dismiss() } }
        }
    }
}

struct ShareRouteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloud: CloudService
    @EnvironmentObject private var store: WalkStore
    @EnvironmentObject private var preferences: WalkPreferences
    let route: SavedRoute
    @State private var showMap: Bool
    @State private var includeNote = false
    @State private var expiryChoice = 7
    @State private var noExpiry = false
    @State private var url: URL?
    @State private var error: String?
    @State private var busy = false

    init(route: SavedRoute) { self.route = route; _showMap = State(initialValue: UserDefaults.standard.bool(forKey: "share_location")) }

    var body: some View {
        NavigationStack {
            Form {
                Section("共有する内容") {
                    Toggle("地図を共有", isOn: $showMap)
                    if showMap { Text("開始地点と終了地点から150m以内のGPS点は、途中で再び通った場合も含めて共有データから除外します。").font(.caption).foregroundStyle(.secondary) }
                    Toggle("メモを共有", isOn: $includeNote)
                }
                Section("有効期限") {
                    Toggle("期限なし", isOn: $noExpiry)
                    if !noExpiry { Picker("日数", selection: $expiryChoice) { Text("1日").tag(1); Text("7日").tag(7); Text("30日").tag(30); Text("90日").tag(90) } }
                }
                if let url {
                    Section("共有リンク") {
                        Text(url.absoluteString).font(.footnote).textSelection(.enabled)
                        ShareLink(item: url) { Label("リンクを共有", systemImage: "square.and.arrow.up") }
                        Button("コピー") { UIPasteboard.general.string = url.absoluteString }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("散歩を共有")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { if url == nil { Button(busy ? "作成中…" : "リンク作成") { create() }.disabled(busy) } } }
        }
    }

    private func create() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                await cloud.refreshSession()
                guard let account = cloud.accountId ?? preferences.activeAccountId else { throw AppError.message("設定からGoogleでログインしてください") }
                preferences.activeAccountId = account; preferences.accountEmail = cloud.email
                let owned = try store.claimForShare(route, accountId: account)
                url = try await cloud.createShare(route: owned, showMap: showMap, includeNote: includeNote, expiryDays: noExpiry ? nil : expiryChoice)
            } catch { self.error = error.localizedDescription }
        }
    }
}
