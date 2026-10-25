import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject private var store: WalkStore
    @StateObject private var recorder = LocationRecorder()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            WalkScreen(recorder: recorder)
                .tabItem { Label("散歩", systemImage: "figure.walk") }
                .tag(0)

            HistoryScreen()
                .tabItem { Label("記録", systemImage: "clock.arrow.circlepath") }
                .tag(1)

            InsightsScreen()
                .tabItem { Label("振り返り", systemImage: "chart.bar") }
                .tag(2)
        }
    }
}

private struct WalkScreen: View {
    @EnvironmentObject private var store: WalkStore
    @ObservedObject var recorder: LocationRecorder
    @State private var name = ""
    @State private var note = ""
    @State private var showSave = false
    @State private var pendingRecord: WalkRecord?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Map {
                    if recorder.points.count > 1 {
                        MapPolyline(coordinates: recorder.points.map(\.coordinate))
                            .stroke(.blue, lineWidth: 5)
                    }
                    if let last = recorder.points.last {
                        Marker("現在地", coordinate: last.coordinate)
                    }
                }
                .mapControls { MapCompass(); MapScaleView() }
                .frame(maxHeight: .infinity)

                HStack {
                    metric("距離", String(format: "%.2f km", recorder.distanceMeters / 1000))
                    metric("GPS", "\(recorder.points.count)点")
                }

                if recorder.authorizationStatus == .denied || recorder.authorizationStatus == .restricted {
                    Text("位置情報が許可されていません。iPhoneの設定からサンポロードの位置情報を許可してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                Button {
                    if recorder.isRecording {
                        pendingRecord = recorder.stop()
                        showSave = pendingRecord != nil
                    } else {
                        recorder.start()
                    }
                } label: {
                    Label(recorder.isRecording ? "散歩を終了" : "散歩を開始",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "play.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .padding(.bottom)
            .navigationTitle("サンポロード")
            .sheet(isPresented: $showSave) {
                NavigationStack {
                    Form {
                        TextField("散歩の名前", text: $name)
                        TextField("メモ", text: $note, axis: .vertical)
                    }
                    .navigationTitle("散歩を保存")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("破棄") { pendingRecord = nil; showSave = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                guard var record = pendingRecord else { return }
                                record.name = name.isEmpty ? "散歩" : name
                                record.note = note
                                store.add(record)
                                pendingRecord = nil
                                name = ""; note = ""
                                showSave = false
                            }
                        }
                    }
                }
            }
            .onAppear { if recorder.authorizationStatus == .notDetermined { recorder.requestPermission() } }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack { Text(value).font(.title3.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }
}

private struct HistoryScreen: View {
    @EnvironmentObject private var store: WalkStore

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.records) { record in
                    NavigationLink {
                        WalkDetail(record: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name).font(.headline)
                            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.2f km ・ %@", record.distanceMeters / 1000, formatDuration(record.duration)))
                        }
                    }
                }
                .onDelete(perform: store.delete)
            }
            .overlay { if store.records.isEmpty { ContentUnavailableView("記録はまだありません", systemImage: "figure.walk") } }
            .navigationTitle("記録")
        }
    }
}

private struct WalkDetail: View {
    let record: WalkRecord

    var body: some View {
        List {
            Map {
                if record.points.count > 1 {
                    MapPolyline(coordinates: record.points.map(\.coordinate)).stroke(.blue, lineWidth: 5)
                }
            }
            .frame(height: 280)
            .listRowInsets(EdgeInsets())

            LabeledContent("距離", value: String(format: "%.2f km", record.distanceMeters / 1000))
            LabeledContent("時間", value: formatDuration(record.duration))
            if let pace = record.averagePaceMinutesPerKm {
                LabeledContent("平均ペース", value: String(format: "%.1f 分/km", pace))
            }
            if !record.note.isEmpty { Text(record.note) }
        }
        .navigationTitle(record.name)
    }
}

private struct InsightsScreen: View {
    @EnvironmentObject private var store: WalkStore

    var body: some View {
        NavigationStack {
            List {
                Section("合計") {
                    LabeledContent("散歩回数", value: "\(store.records.count) 回")
                    LabeledContent("距離", value: String(format: "%.2f km", store.totalDistanceMeters / 1000))
                    LabeledContent("時間", value: formatDuration(store.totalDuration))
                }
                Section("最近") {
                    ForEach(store.records.prefix(5)) { record in
                        HStack {
                            Text(record.name)
                            Spacer()
                            Text(String(format: "%.2f km", record.distanceMeters / 1000)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("振り返り")
        }
    }
}

private func formatDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
}
