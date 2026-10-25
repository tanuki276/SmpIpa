import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsScreen: View {
    @EnvironmentObject private var preferences: WalkPreferences
    @EnvironmentObject private var recorder: LocationRecorder
    @EnvironmentObject private var store: WalkStore
    @EnvironmentObject private var cloud: CloudService
    @EnvironmentObject private var health: HealthKitManager
    @State private var showEnableCloud = false
    @State private var showEnablePhotos = false
    @State private var showLogout = false
    @State private var showDeleteAccount = false
    @State private var showDeleteAll = false
    @State private var showImporter = false
    @State private var activityFile: ShareFile?
    @State private var message: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                gpsSection
                cloudSection
                healthSection
                dataSection
                privacySection
                if let message { Section { Text(message).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("設定")
            .onChange(of: preferences.highAccuracyGps) { _, value in recorder.applyHighAccuracy(value) }
            .confirmationDialog("クラウド同期をONにしますか？", isPresented: $showEnableCloud) {
                Button("ONにする") { preferences.cloudSync = true; syncNow() }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("散歩の記録をログイン中のSupabaseアカウントへ同期します。ログインだけでは同期は開始しません。") }
            .confirmationDialog("写真も同期しますか？", isPresented: $showEnablePhotos) {
                Button("写真同期をON") { preferences.photoSync = true; if preferences.cloudSync { syncNow() } }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("写真は非公開Storageへアップロードされます。") }
            .confirmationDialog("ログアウトしますか？", isPresented: $showLogout) {
                Button("ログアウト", role: .destructive) { logout() }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("クラウド同期をOFFにし、このアカウントの記録を端末上で非表示にします。端末データ自体は削除しません。") }
            .confirmationDialog("アカウントを完全に削除しますか？", isPresented: $showDeleteAccount) {
                Button("アカウントとクラウドデータを削除", role: .destructive) { deleteAccount() }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("Supabase上の散歩・写真・共有リンクを削除し、端末上のこのアカウントの記録も削除します。この操作は取り消せません。") }
            .confirmationDialog("表示中の記録をすべて削除しますか？", isPresented: $showDeleteAll) {
                Button("すべて削除", role: .destructive) { store.deleteAllVisible(accountId: preferences.activeAccountId); message = "記録を削除しました" }
                Button("キャンセル", role: .cancel) {}
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .data], allowsMultipleSelection: false) { result in importBackup(result) }
            .sheet(item: $activityFile) { ActivityView(items: [$0.url]) }
        }
    }

    private var gpsSection: some View {
        Section("GPS記録") {
            Toggle("高精度GPS", isOn: $preferences.highAccuracyGps)
            Text(preferences.highAccuracyGps ? "約2m以上の移動を拾いやすくします。バッテリー消費は増えます。" : "通常モード。約4m以上を目安にGPSノイズを抑えます。")
                .font(.caption).foregroundStyle(.secondary)
            if recorder.isRecording { Text("記録中でも精度モードを切り替えられます。").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var cloudSection: some View {
        Section("アカウントとクラウド") {
            if let email = preferences.accountEmail ?? cloud.email {
                LabeledContent("Googleアカウント", value: email)
                Button("ログアウト", role: .destructive) { guard !recorder.isRecording else { blockedByRecording(); return }; showLogout = true }
            } else {
                Button { login() } label: { Label("Googleでログイン", systemImage: "person.crop.circle.badge.plus") }.disabled(recorder.isRecording || busy)
                Text("ログインしただけではクラウド同期はONになりません。").font(.caption).foregroundStyle(.secondary)
            }

            Toggle("クラウド同期", isOn: Binding(get: { preferences.cloudSync }, set: { value in
                guard !recorder.isRecording else { blockedByRecording(); return }
                if value {
                    guard preferences.activeAccountId != nil || cloud.accountId != nil else { error = "先にGoogleでログインしてください"; return }
                    showEnableCloud = true
                } else { preferences.cloudSync = false }
            }))
            Toggle("写真も同期", isOn: Binding(get: { preferences.photoSync }, set: { value in
                guard !recorder.isRecording else { blockedByRecording(); return }
                if value { guard preferences.cloudSync else { error = "先にクラウド同期をONにしてください"; return }; showEnablePhotos = true }
                else { preferences.photoSync = false }
            })).disabled(!preferences.cloudSync)
            Toggle("共有リンクの地図を標準でON", isOn: $preferences.shareLocation)
            Button { syncNow() } label: { Label(busy ? "同期中…" : "今すぐ再同期", systemImage: "arrow.triangle.2.circlepath") }.disabled(!preferences.cloudSync || busy || recorder.isRecording)
            Text(cloud.syncStatus).font(.caption).foregroundStyle(.secondary)
            NavigationLink("作成済み共有リンクを管理") { ShareManagementView() }.disabled(preferences.activeAccountId == nil && cloud.accountId == nil)
            if preferences.activeAccountId != nil || cloud.accountId != nil {
                Button("アカウントを削除", role: .destructive) { guard !recorder.isRecording else { blockedByRecording(); return }; showDeleteAccount = true }.disabled(busy)
            }
        }
    }

    private var healthSection: some View {
        Section("ヘルスケア") {
            Button { Task { do { try await health.requestAuthorization(); message = "HealthKitを利用できるようにしました" } catch { self.error = error.localizedDescription } } } label: { Label("HealthKitのアクセスを設定", systemImage: "heart.text.square") }
            Text(health.authorizationMessage).font(.caption).foregroundStyle(.secondary)
            Text("保存した散歩をウォーキングとしてHealthKitへ書き込み、記録の時間帯にある歩数・平均心拍・アクティブエネルギーを端末内で表示します。これらのHealthKit値はクラウド同期・共有・バックアップには含めません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dataSection: some View {
        Section("データ") {
            Button { exportBackup() } label: { Label("SANPOバックアップ(JSON)", systemImage: "archivebox") }.disabled(recorder.isRecording)
            Button { exportGPX() } label: { Label("GPXを書き出す", systemImage: "map") }.disabled(recorder.isRecording)
            Button { exportCSV() } label: { Label("CSVを書き出す", systemImage: "tablecells") }.disabled(recorder.isRecording)
            Button { guard !recorder.isRecording else { blockedByRecording(); return }; showImporter = true } label: { Label("SANPOバックアップを読み込む", systemImage: "square.and.arrow.down") }
            Text("バックアップは写真をBase64で含めるため最大50MBです。Android版SANPO-ROADのバックアップ形式と互換です。インポートした記録は週間目標・自己記録の集計から除外します。")
                .font(.caption).foregroundStyle(.secondary)
            Button("表示中の記録をすべて削除", role: .destructive) { guard !recorder.isRecording else { blockedByRecording(); return }; showDeleteAll = true }
        }
    }

    private var privacySection: some View {
        Section("情報") {
            NavigationLink("プライバシーポリシー") { LegalTextView(resource: "privacy", title: "プライバシーポリシー") }
            NavigationLink("利用規約") { LegalTextView(resource: "terms", title: "利用規約") }
            DisclosureGroup("クラウドへ送るデータ") {
                Text("クラウド同期をONにした場合、散歩ID、名前、開始時刻、時間、距離、GPS点、メモ、タグ、お気に入り、GPS品質、休憩情報、更新・削除状態をSupabaseへ送ります。写真同期がONの場合のみ写真も非公開Storageへ送ります。")
                Text("共有リンクは別操作です。地図共有をONにした場合でも開始・終了地点の周囲150mは除外し、共有用GPS点から時刻と精度を外します。")
            }.font(.caption)
            LabeledContent("アプリ", value: "サンポロード for iPhone")
        }
    }

    private func blockedByRecording() { error = "散歩を記録中はアカウント変更・インポート・一括削除を行えません" }

    private func login() {
        guard !recorder.isRecording else { blockedByRecording(); return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let account = try await cloud.signInWithGoogle()
                preferences.activeAccountId = account; preferences.accountEmail = cloud.email
                message = "ログインしました。クラウド同期は必要な場合だけONにしてください。"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func logout() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await cloud.logout()
                preferences.cloudSync = false; preferences.photoSync = false
                preferences.activeAccountId = nil; preferences.accountEmail = nil
                message = "ログアウトしました"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func syncNow() {
        guard !recorder.isRecording else { blockedByRecording(); return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await cloud.sync(store: store, preferences: preferences); message = cloud.syncStatus }
            catch { self.error = error.localizedDescription }
        }
    }

    private func deleteAccount() {
        guard let account = preferences.activeAccountId ?? cloud.accountId else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await cloud.deleteAccount(); store.eraseLocalAccount(account)
                preferences.cloudSync = false; preferences.photoSync = false; preferences.activeAccountId = nil; preferences.accountEmail = nil
                message = "アカウントと関連データを削除しました"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func exportBackup() {
        do {
            let routes = store.visibleRecords(accountId: preferences.activeAccountId)
            let data = try BackupExport.encodeBackup(routes: routes)
            activityFile = ShareFile(url: try BackupExport.temporaryFile(data: data, name: "sanpo-road-backup.json"))
        } catch { self.error = error.localizedDescription }
    }
    private func exportGPX() {
        do { activityFile = ShareFile(url: try BackupExport.temporaryFile(data: BackupExport.gpx(routes: store.visibleRecords(accountId: preferences.activeAccountId)), name: "sanpo-road.gpx")) }
        catch { self.error = error.localizedDescription }
    }
    private func exportCSV() {
        do { activityFile = ShareFile(url: try BackupExport.temporaryFile(data: BackupExport.csv(routes: store.visibleRecords(accountId: preferences.activeAccountId)), name: "sanpo-road.csv")) }
        catch { self.error = error.localizedDescription }
    }

    private func importBackup(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else { throw AppError.message("ファイルを開けませんでした") }
            defer { url.stopAccessingSecurityScopedResource() }
            let decoded = try BackupExport.decodeBackup(Data(contentsOf: url))
            let count = try store.importRoutes(decoded.routes, photos: decoded.photos, accountId: preferences.activeAccountId)
            message = "\(count)件をインポートしました"
        } catch { self.error = error.localizedDescription }
    }
}

private struct ShareManagementView: View {
    @EnvironmentObject private var cloud: CloudService
    @State private var shares: [ManagedShare] = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        List {
            if busy { ProgressView() }
            ForEach(shares) { share in
                VStack(alignment: .leading, spacing: 6) {
                    Text(share.name).font(.headline)
                    Text("作成: \(share.createdAt)").font(.caption).foregroundStyle(.secondary)
                    Text(share.expiresAt.map { "期限: \($0)" } ?? "期限なし").font(.caption).foregroundStyle(.secondary)
                    Text(share.showMap ? "地図あり" : "地図なし").font(.caption)
                    HStack {
                        ShareLink(item: cloud.shareURL(token: share.token)) { Label("共有", systemImage: "square.and.arrow.up") }
                        Button("コピー") { UIPasteboard.general.string = cloud.shareURL(token: share.token).absoluteString }
                        Spacer()
                        Button("無効化", role: .destructive) { revoke(share) }
                    }.font(.caption)
                }.padding(.vertical, 4)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("共有リンク").task { await load() }.refreshable { await load() }
    }

    private func load() async {
        busy = true; defer { busy = false }
        do { shares = try await cloud.listShares() } catch { self.error = error.localizedDescription }
    }
    private func revoke(_ share: ManagedShare) {
        Task { do { try await cloud.revokeShare(token: share.token); await load() } catch { self.error = error.localizedDescription } }
    }
}

private struct LegalTextView: View {
    let resource: String
    let title: String
    var body: some View {
        ScrollView { Text(load()).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private func load() -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "文書を読み込めませんでした。" }
        return text
    }
}
