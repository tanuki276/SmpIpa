import SwiftUI
import PhotosUI

struct WalkScreen: View {
    @EnvironmentObject private var recorder: LocationRecorder
    @EnvironmentObject private var preferences: WalkPreferences
    @EnvironmentObject private var store: WalkStore
    @EnvironmentObject private var health: HealthKitManager
    @EnvironmentObject private var cloud: CloudService
    @State private var draft: SavedRoute?
    @State private var showDiscard = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    RouteMapView(points: recorder.points, reference: recorder.referenceRoute?.points ?? [], showsUserLocation: true, height: 390)
                    if let reference = recorder.referenceRoute {
                        HStack { Image(systemName: "arrow.triangle.2.circlepath"); Text("再歩行: \(reference.name)"); Spacer(); Button("解除") { recorder.clearRepeat() } }.font(.footnote).padding(.horizontal)
                        if let current = recorder.currentPoint, RouteMath.distanceToRoute(current, reference.points) > 60 { MessageBanner(text: "ガイドルートから60m以上離れています") }
                    }
                    if let recovery = recorder.recoveryError { MessageBanner(text: recovery) }
                    liveMetrics; controls
                    if let message { MessageBanner(text: message) }
                    if recorder.isRecording { Text("画面を閉じてもiOSのバックグラウンド位置情報で記録を続けます。青い位置情報表示が出ることがあります。").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                }.padding()
            }
            .navigationTitle("散歩")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { if recorder.isRecording { Button { preferences.highAccuracyGps.toggle(); recorder.applyHighAccuracy(preferences.highAccuracyGps) } label: { Label(preferences.highAccuracyGps ? "高精度" : "通常", systemImage: preferences.highAccuracyGps ? "location.fill" : "location") } } } }
            .sheet(item: $draft) { route in
                WalkResultEditor(route: route) { saved in
                    store.add(saved, accountId: preferences.activeAccountId); recorder.clearPending()
                    Task { await health.write(route: store.route(id: saved.id, ownerId: preferences.activeAccountId) ?? saved); if preferences.cloudSync { try? await cloud.sync(store: store, preferences: preferences) } }
                    draft = nil
                } onDiscard: { recorder.clearPending(); draft = nil }
            }
            .confirmationDialog("この散歩を破棄しますか？", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("破棄する", role: .destructive) { recorder.discard(); message = "記録を破棄しました" }; Button("キャンセル", role: .cancel) {}
            } message: { Text("現在のGPS軌跡は保存されません。") }
            .onReceive(NotificationCenter.default.publisher(for: .sanpoStopRequested)) { _ in finishWalk() }
            .onReceive(NotificationCenter.default.publisher(for: .sanpoPauseRequested)) { _ in recorder.pause() }
            .onReceive(NotificationCenter.default.publisher(for: .sanpoResumeRequested)) { _ in recorder.resume() }
            .onAppear { recorder.restoreGuideIfNeeded(from: store.records); if draft == nil, let pending = recorder.pendingRoute { draft = pending } }
            .onChange(of: recorder.pendingRoute?.id) { _, _ in if draft == nil, let pending = recorder.pendingRoute { draft = pending } }
        }
    }

    private var liveMetrics: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = recorder.startedAtMs.map { max(0, context.date.epochMilliseconds - $0) } ?? 0
            HStack(spacing: 8) { MetricPill(title: "距離", value: formatKm(recorder.distanceMeters)); MetricPill(title: "時間", value: formatDuration(elapsed)); MetricPill(title: "GPS", value: gpsStatus) }
        }
    }
    private var gpsStatus: String {
        if recorder.isPaused { return "一時停止" }
        guard let accuracy = recorder.latestAccuracy else { return "探索中" }
        if accuracy <= 10 { return String(format: "良好 ±%.0fm", accuracy) }
        if accuracy <= 20 { return String(format: "普通 ±%.0fm", accuracy) }
        return String(format: "不安定 ±%.0fm", accuracy)
    }

    @ViewBuilder private var controls: some View {
        if !recorder.isRecording {
            VStack(spacing: 10) {
                Button { recorder.start(highAccuracy: preferences.highAccuracyGps) } label: { Label(recorder.pendingRoute == nil ? "散歩を開始" : "保存待ち", systemImage: "figure.walk").font(.title3).frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).disabled(recorder.pendingRoute != nil)
                if recorder.authorizationStatus == .denied || recorder.authorizationStatus == .restricted { Text("位置情報が許可されていません。iPhoneの設定からサンポロードの位置情報を許可してください。").font(.caption).foregroundStyle(.red) }
            }
        } else {
            HStack(spacing: 10) {
                Button { recorder.isPaused ? recorder.resume() : recorder.pause() } label: { Label(recorder.isPaused ? "再開" : "休憩", systemImage: recorder.isPaused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                Button { finishWalk() } label: { Label("終了", systemImage: "stop.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            }
            Button("記録を破棄", role: .destructive) { showDiscard = true }.font(.footnote)
        }
    }

    private func finishWalk() {
        guard recorder.isRecording else { return }
        if let route = recorder.stop() { draft = route; if route.points.isEmpty { message = "GPS位置を取得できなかったため、この記録は保存できません。" } }
    }
}

private struct WalkResultEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var route: SavedRoute
    let onSave: (SavedRoute) -> Void
    let onDiscard: () -> Void
    @State private var name: String
    @State private var note: String
    @State private var tagsText: String
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var error: String?

    init(route: SavedRoute, onSave: @escaping (SavedRoute) -> Void, onDiscard: @escaping () -> Void) {
        _route = State(initialValue: route); _name = State(initialValue: route.name); _note = State(initialValue: route.note); _tagsText = State(initialValue: route.tags.joined(separator: ", ")); self.onSave = onSave; self.onDiscard = onDiscard
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("散歩の結果") {
                    HStack { MetricPill(title: "距離", value: formatKm(route.distanceMeters)); MetricPill(title: "歩行", value: formatDuration(route.durationMs)); MetricPill(title: "休憩", value: formatDuration(route.restDurationMs)) }
                    Text("GPS品質: \(route.gpsQuality?.confidence ?? "不明")"); if route.points.isEmpty { Text("GPS位置がないため保存できません").foregroundStyle(.red) }
                }
                Section("記録") {
                    TextField("名前", text: $name).textInputAutocapitalization(.never); TextField("メモ", text: $note, axis: .vertical).lineLimit(3...8); TextField("タグ（カンマ区切り）", text: $tagsText)
                    PhotosPicker(selection: $photoItem, matching: .images) { Label(photoData == nil ? "写真を追加" : "写真を選び直す", systemImage: "photo") }
                    if photoData != nil { Text("写真を選択済み").font(.caption).foregroundStyle(.secondary) }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("散歩を保存")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("破棄", role: .destructive) { onDiscard(); dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(route.points.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
            .onChange(of: photoItem) { _, item in guard let item else { return }; Task { do { photoData = try await item.loadTransferable(type: Data.self) } catch { self.error = error.localizedDescription } } }
        }
    }

    private func save() {
        do {
            route.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)); route.note = String(note.prefix(10_000))
            route.tags = tagsText.split(whereSeparator: { $0 == "," || $0 == "、" || $0.isNewline }).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)) }.filter { !$0.isEmpty }.prefix(20).map { $0 }
            if let photoData { route.photoPath = try PhotoStore.shared.save(data: photoData, routeID: route.id); route.photoHash = PhotoStore.shared.hash(path: route.photoPath); route.photoRemoved = false }
            onSave(route); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
