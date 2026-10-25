import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            WalkScreen().tag(0).tabItem { Label("散歩", systemImage: "figure.walk") }
            HistoryScreen(selectedTab: $selectedTab).tag(1).tabItem { Label("記録", systemImage: "clock.arrow.circlepath") }
            InsightsScreen().tag(2).tabItem { Label("振り返り", systemImage: "chart.bar.xaxis") }
            SettingsScreen().tag(3).tabItem { Label("設定", systemImage: "gearshape") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sanpoStopRequested)) { _ in selectedTab = 0 }
    }
}
