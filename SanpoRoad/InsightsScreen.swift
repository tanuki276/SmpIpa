import SwiftUI
import Charts

struct InsightsScreen: View {
    @EnvironmentObject private var store: WalkStore
    @EnvironmentObject private var preferences: WalkPreferences
    @State private var month = Date()
    @State private var showGoal = false
    @State private var goalText = ""
    @State private var shareRoute: SavedRoute?

    private var routes: [SavedRoute] { store.visibleRecords(accountId: preferences.activeAccountId) }
    private var stats: WalkStatsSnapshot { RouteMath.stats(routes) }
    private var weeks: [WeeklyDistance] { RouteMath.weeklyDistances(routes) }
    private var days: [CalendarDaySummary] { RouteMath.month(routes, containing: month) }
    private var monthInterval: DateInterval? { Calendar.current.dateInterval(of: .month, for: month) }
    private var monthTags: [(String, Double)] {
        guard let interval = monthInterval else { return [] }
        var totals: [String: Double] = [:]
        for r in routes where !r.imported && r.deletedAt == nil && r.startedDate >= interval.start && r.startedDate < interval.end {
            for tag in Set(r.tags) { totals[tag, default: 0] += r.distanceMeters }
        }
        return totals.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("歩いた記録を、ちょっと気持ちよく振り返る場所。").foregroundStyle(.secondary)
                    goalCard
                    if let latest = routes.first { latestCard(latest) }
                    weeklyChart
                    if !monthTags.isEmpty {
                        GroupBox("月別タグ集計（インポート記録を除く）") {
                            VStack(alignment: .leading) { ForEach(Array(monthTags.enumerated()), id: \.offset) { _, item in HStack { Text("#\(item.0)"); Spacer(); Text(formatKm(item.1)) } } }
                        }
                    }
                    monthCalendar
                    lifetimeCard
                }.padding()
            }
            .navigationTitle("振り返り")
            .sheet(isPresented: $showGoal) { goalEditor }
            .sheet(item: $shareRoute) { ShareRouteView(route: $0) }
        }
    }

    private var goalCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack { VStack(alignment: .leading) { Text("今週").font(.caption).foregroundStyle(.tint); Text("\(formatKm(stats.thisWeekDistanceMeters)) / \(formatKm(preferences.weeklyGoalMeters))").font(.title3.bold()) }; Spacer(); Button("目安を変更") { goalText = String(format: "%.1f", preferences.weeklyGoalMeters / 1000); showGoal = true } }
                ProgressView(value: min(stats.thisWeekDistanceMeters / max(preferences.weeklyGoalMeters, 1), 1))
                let remaining = max(0, preferences.weeklyGoalMeters - stats.thisWeekDistanceMeters)
                Text(remaining == 0 ? "今週の目安を達成しました。いい感じ。" : "あと \(formatKm(remaining))。気が向いた日に少しずつ。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func latestCard(_ route: SavedRoute) -> some View {
        GroupBox("最新の散歩") {
            VStack(alignment: .leading, spacing: 8) {
                Text(route.name).font(.headline); HStack { Text(formatKm(route.distanceMeters)); Text(formatDuration(route.elapsedMs)); Spacer() }
                Button { shareRoute = route } label: { Label("この散歩を共有", systemImage: "square.and.arrow.up") }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var weeklyChart: some View {
        GroupBox("直近8週間") {
            Chart(weeks) { week in
                BarMark(x: .value("週", week.weekStart, unit: .weekOfYear), y: .value("距離", week.distanceMeters / 1000))
                    .annotation(position: .top) { if week.distanceMeters > 0 { Text(String(format: "%.1f", week.distanceMeters / 1000)).font(.caption2) } }
            }
            .frame(height: 180)
            .chartYAxisLabel("km")
        }
    }

    private var monthCalendar: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack { Button { month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left") }; Spacer(); Text(month.formatted(.dateTime.year().month(.wide))).font(.headline); Spacer(); Button { month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right") } }
                let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(["月","火","水","木","金","土","日"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    ForEach(0..<leadingBlankCount, id: \.self) { _ in Color.clear.frame(height: 45) }
                    ForEach(days) { day in
                        VStack(spacing: 2) {
                            Text(String(Calendar.current.component(.day, from: day.date))).font(.caption)
                            if day.walks > 0 { Text(String(format: "%.1f", day.distanceMeters / 1000)).font(.caption2); Circle().frame(width: 5, height: 5).foregroundStyle(.tint) }
                        }.frame(maxWidth: .infinity, minHeight: 45).background(day.walks > 0 ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        } label: { Text("月間カレンダー") }
    }

    private var leadingBlankCount: Int {
        guard let first = Calendar.current.dateInterval(of: .month, for: month)?.start else { return 0 }
        let weekday = Calendar.current.component(.weekday, from: first)
        return (weekday + 5) % 7
    }

    private var lifetimeCard: some View {
        GroupBox("これまでの積み上がり") {
            VStack(spacing: 8) {
                HStack { MetricPill(title: "累計", value: formatKm(stats.totalDistanceMeters)); MetricPill(title: "散歩", value: "\(stats.totalWalks)回") }
                HStack { MetricPill(title: "最長", value: formatKm(stats.longestDistanceMeters)); MetricPill(title: "平均", value: formatKm(stats.averageDistanceMeters)) }
                Text(stats.currentStreakDays > 0 ? "現在 \(stats.currentStreakDays)日連続で散歩中" : "次の一歩から、また記録が始まります。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if stats.weekDeltaMeters != 0 { Text("先週比 \(stats.weekDeltaMeters >= 0 ? "+" : "")\(formatKm(stats.weekDeltaMeters))").font(.caption) }
            }
        }
    }

    private var goalEditor: some View {
        NavigationStack {
            Form { Section { Text("ノルマではなく、今週どれくらい歩けたら嬉しいかの目安です。"); TextField("距離 (km)", text: $goalText).keyboardType(.decimalPad) } }
                .navigationTitle("今週の目安")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { showGoal = false } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { if let km = Double(goalText.replacingOccurrences(of: ",", with: ".")), (0.5...100).contains(km) { preferences.weeklyGoalMeters = km * 1000; showGoal = false } } } }
        }
    }
}
