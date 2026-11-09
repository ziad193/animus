import Charts
import SwiftUI
import StudyCore

/// Your study history: today's numbers, a year-long heatmap of daily
/// reviews, what your collection is made of, and what's coming up.
struct StatsPage: View {
    @Environment(Library.self) private var library
    @State private var stats: Stats?
    #if os(macOS)
    @State private var plusStore = PlusStore.shared
    #endif
    @State private var error: String?
    /// Limit the whole page to one deck (nil = every deck).
    @State private var scopeDeck: Int64?

    private var decks: [Deck] { library.deckList }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stats").font(.largeTitle.weight(.semibold))
            Text("How your studying is going.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var deckChoice: some View {
        HStack(spacing: 8) {
            Text("For").foregroundStyle(.secondary)
            DeckPickerButton(decks: decks, selection: $scopeDeck, emptyTitle: "All decks", allowsAll: true)
                .frame(width: 240)
        }
        .tip("Show stats for one deck (and its sections), or all of them")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Side by side when there's room; on a phone, the deck choice goes underneath.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom) {
                        title
                        Spacer()
                        deckChoice
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        title
                        deckChoice
                    }
                }
                if let stats {
                    StatTiles(stats: stats)
                    // Animus+ (Animus Dev only until it's ready): the week in words. Mac only for now.
                    #if os(macOS)
                    if plusStore.showsPreviews && plusStore.showsPrompts && plusStore.isUnlocked(.weeklyReport) {
                        WeeklyReportPanel(stats: stats, decks: decks)
                    }
                    #endif
                    Panel(title: "Reviews over the last year") {
                        Heatmap(stats: stats)
                    }
                    Panel(title: "Your cards") {
                        DeckCardBreakdown(allStats: stats)
                    }
                    Panel(title: "Coming up in the next 30 days") {
                        DueAheadChart(dueAhead: stats.dueAhead)
                    }
                    Panel(title: "How well you remember") {
                        RetentionTable(stats: stats)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            Panel(title: "Best time of day") { HourChart(stats: stats) }
                            Panel(title: "Gaps between reviews") { IntervalChart(stats: stats) }
                        }
                        VStack(spacing: 20) {
                            Panel(title: "Best time of day") { HourChart(stats: stats) }
                            Panel(title: "Gaps between reviews") { IntervalChart(stats: stats) }
                        }
                    }
                    Panel(title: "Answer buttons") {
                        AnswerButtonsChart(stats: stats)
                    }
                } else if let error {
                    ContentUnavailableView("Couldn't load stats", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(36)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .pageBackground()
        .task(id: scopeDeck) { await load() }
    }

    private func load() async {
        guard let engine = library.engine else { return }
        do {
            if let scopeDeck, let deck = Deck.find(scopeDeck, in: decks) {
                let search = "did:" + deck.idsIncludingSections.map(String.init).joined(separator: ",")
                stats = try await engine.stats(days: Heatmap.historyDays, search: search)
            } else {
                stats = try await engine.stats(days: Heatmap.historyDays)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Headline numbers

private struct StatTiles: View {
    let stats: Stats

    /// Days in a row with at least one review, counting back from today
    /// (or yesterday, so the streak isn't "lost" before you've studied today).
    private var streak: Int {
        var day = (stats.reviewsPerDay[0] ?? 0) > 0 ? 0 : -1
        var count = 0
        while (stats.reviewsPerDay[day] ?? 0) > 0 {
            count += 1
            day -= 1
        }
        return count
    }

    private var minutesToday: String {
        let minutes = stats.todaySeconds / 60
        return minutes < 60 ? "\(minutes) min" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    var body: some View {
        // Four across when there's room, two by two on a phone.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            tile("\(stats.todayReviews)", "Reviews today", "rectangle.stack")
            tile(minutesToday, "Time today", "clock")
            tile(streak == 1 ? "1 day" : "\(streak) days", "Streak", "flame")
            tile(stats.retentionMonth.map { "\(Int(($0 * 100).rounded()))%" } ?? "–",
                 "Remembered (30 days)", "brain")
        }
    }

    private func tile(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(BlockFill(cornerRadius: 14, plain: AnyShapeStyle(.background)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
    }
}

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BlockFill(cornerRadius: 16, plain: AnyShapeStyle(.background)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5)))
    }
}

// MARK: - Card breakdown

/// One bar split into New / Learning / Young / Mature / Suspended.
private struct CardBreakdown: View {
    let stats: Stats

    private var parts: [(String, Int, Color, String)] {
        [("New", stats.cardsNew, Palette.new, "Not studied yet"),
         ("Learning", stats.cardsLearning, Palette.learning, "Still being learned"),
         ("Young", stats.cardsYoung, Color(hex: "#6da7ec"), "Remembered for under 3 weeks"),
         ("Mature", stats.cardsMature, Palette.review, "Remembered for 3 weeks or more"),
         ("Suspended", stats.cardsSuspended, Color.secondary.opacity(0.5), "Paused, won't be shown")]
    }

    var body: some View {
        let total = max(1, parts.map(\.1).reduce(0, +))
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(part.2)
                            .frame(width: max(4, (geo.size.width - 8) * CGFloat(part.1) / CGFloat(total)))
                            .tip("\(part.0): \(part.1) cards")
                    }
                }
            }
            .frame(height: 14)

            HStack(spacing: 18) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 6) {
                        Circle().fill(part.2).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(part.1)").font(.headline.monospacedDigit())
                            Text(part.0).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tip(part.3)
                }
            }
        }
    }
}

// MARK: - Coming up

private struct DueAheadChart: View {
    /// Cards due per day from today (0); negative days are overdue.
    let dueAhead: [Int: Int]
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    @AppStorage("stats.comingUpDays") private var range = 30
    @State private var hovered: Date?

    /// Overdue cards: they're waiting today, so they count towards today's bar.
    private var overdue: Int { dueAhead.filter { $0.key < 0 }.reduce(0) { $0 + $1.value } }

    private func count(_ day: Int) -> Int { (dueAhead[day] ?? 0) + (day == 0 ? overdue : 0) }

    private var days: [(day: Int, count: Int)] { (0..<range).map { ($0, count($0)) } }
    private var total: Int { days.reduce(0) { $0 + $1.count } }
    private var nextWeek: Int { (0..<7).reduce(0) { $0 + count($1) } }
    /// A normal day: the overdue backlog is left out, or it would swamp the average.
    private var average: Double { Double(total - overdue) / Double(max(days.count, 1)) }
    private var busiest: (day: Int, count: Int)? { days.max { $0.count < $1.count } }

    private func date(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private func offset(of date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                        to: Calendar.current.startOfDay(for: date)).day ?? 0
    }

    private func label(_ offset: Int) -> String {
        if offset == 0 { return "Today" }
        if offset == 1 { return "Tomorrow" }
        return date(offset).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        if days.allSatisfy({ $0.count == 0 }) {
            Text("Nothing scheduled yet. Study some cards and their reviews will show up here.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    summary("\(total.formatted())", range == 7 ? "in the next 7 days" : "in the next 30 days")
                    if range == 30 {
                        summary("\(nextWeek.formatted())", "in the next 7 days")
                    }
                    if let busiest, busiest.count > 0 {
                        summary("\(busiest.count.formatted())", "on your busiest day, \(label(busiest.day))")
                    }
                    Spacer()
                    Picker("Range", selection: $range) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                chart
            }
        }
    }

    private func summary(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.trailing, 18)
    }

    private var hoveredDay: Int? { hovered.map(offset(of:)) }

    private var chart: some View {
        Chart {
            ForEach(days, id: \.day) { item in
                // One bar per day, filling most of its slot with a small gap between.
                BarMark(x: .value("Day", date(item.day), unit: .day),
                        y: .value("Cards", item.count),
                        width: .ratio(0.72))
                    // Today in full colour; the days ahead a lighter tint, brighter under the pointer.
                    .foregroundStyle(item.day == 0 ? accent.color
                                     : accent.color.opacity(hoveredDay == item.day ? 0.8 : 0.45))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            }
            RuleMark(y: .value("Average", average))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(.secondary.opacity(0.6))
                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                    Text("about \(Int(average.rounded())) a day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            if let day = hoveredDay, (0..<range).contains(day) {
                RuleMark(x: .value("Day", date(day), unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(day)
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: range == 7 ? 1 : 7)) { value in
                AxisTick(length: 3).foregroundStyle(.secondary.opacity(0.4))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        let o = offset(of: d)
                        Text(o == 0 ? "Today"
                             : d.formatted(range == 7 ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel().foregroundStyle(.secondary)
            }
        }
        .chartPlotStyle { $0.padding(.top, 6) }
        .frame(height: 220)
        .animation(.snappy, value: range)
    }

    private func tooltip(_ day: Int) -> some View {
        let n = count(day)
        return VStack(alignment: .leading, spacing: 2) {
            Text(label(day)).font(.caption.weight(.semibold))
            Text(n == 1 ? "1 card due" : "\(n.formatted()) cards due").font(.caption)
            if day == 0, overdue > 0 {
                Text("including \(overdue.formatted()) overdue").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

/// "Your cards", for one deck or all of them. Starts on the top-level deck
/// holding whatever you studied last; All cards is the last choice.
private struct DeckCardBreakdown: View {
    @Environment(Library.self) private var library
    @AppStorage(Pref.lastStudiedDeck) private var lastStudiedDeck = 0
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    let allStats: Stats

    /// nil = All cards.
    @State private var deckID: Int64?
    @State private var chosen = false
    @State private var deckStats: Stats?

    private var decks: [Deck] { library.deckList }

    /// The top-level deck containing the one you studied last.
    private var defaultDeck: Int64? {
        let last = Int64(lastStudiedDeck)
        return decks.first { $0.idsIncludingSections.contains(last) }?.id ?? decks.first?.id
    }

    private var selected: Int64? { chosen ? deckID : defaultDeck }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(decks) { deck in
                        chip(deck.shortName, isOn: selected == deck.id) { pick(deck.id) }
                    }
                    chip("All cards", isOn: selected == nil) { pick(nil) }
                }
            }
            if let stats = selected == nil ? allStats : deckStats {
                CardBreakdown(stats: stats)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: selected) { await load() }
    }

    private func pick(_ id: Int64?) {
        chosen = true
        deckID = id
    }

    private func load() async {
        guard let id = selected, let deck = Deck.find(id, in: decks), let engine = library.engine else {
            deckStats = nil
            return
        }
        deckStats = nil
        let search = "did:" + deck.idsIncludingSections.map(String.init).joined(separator: ",")
        deckStats = try? await engine.stats(days: 1, search: search)
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isOn ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? Color.white : .primary)
                .background(Capsule().fill(isOn ? AnyShapeStyle(accent.color) : AnyShapeStyle(Color.primary.opacity(0.06))))
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.04)
    }
}
