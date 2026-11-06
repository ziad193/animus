import Charts
import SwiftUI
import StudyCore

/// Your study history: today's numbers, a year-long heatmap of daily
/// reviews, what your collection is made of, and what's coming up.
struct StatsPage: View {
    @Environment(Library.self) private var library
    @State private var stats: Stats?
    @State private var error: String?
    /// Limit the whole page to one deck (nil = every deck).
    @State private var scopeDeck: Int64?

    private var decks: [Deck] {
        if case .ready(let decks) = library.state { return decks }
        return []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stats").font(.largeTitle.weight(.semibold))
                        Text("How your studying is going.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Text("For").foregroundStyle(.secondary)
                        DeckPickerButton(decks: decks, selection: $scopeDeck, emptyTitle: "All decks", allowsAll: true)
                            .frame(width: 240)
                    }
                    .help("Show stats for one deck (and its sections), or all of them")
                }
                if let stats {
                    StatTiles(stats: stats)
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
        HStack(spacing: 12) {
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
        .background(RoundedRectangle(cornerRadius: 14).fill(.background))
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
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5)))
    }
}

// MARK: - Heatmap

/// One square per day for the last year, darker for more reviews.
/// Hover a square to see the date and count.
struct Heatmap: View {
    let stats: Stats
    @Environment(\.colorScheme) private var scheme

    @State private var width: CGFloat = 700
    @State private var year = Calendar.current.component(.year, from: Date())
    /// The day under the pointer, as days from today (0 = today, -1 = yesterday).
    @State private var hovered: Int?
    @State private var cardSize = CGSize(width: 220, height: 70)
    @Environment(\.openWindow) private var openWindow
    @State private var grid = HeatmapGrid.empty

    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 30
    private let monthRow: CGFloat = 14

    private var thisYear: Int { Calendar.current.component(.year, from: Date()) }

    /// Squares grow to fill the panel's width.
    private var cell: CGFloat {
        let weeks = max(grid.weeks, 1)
        let available = width - labelWidth - 6 - CGFloat(weeks - 1) * gap
        return max(8, min(18, floor(available / CGFloat(weeks))))
    }

    /// Single-hue blue ramp, light → dark (dark mode runs the other way so
    /// more reviews always stand out more from the background).
    @AppStorage(HeatmapColor.key) private var colorChoice = HeatmapColor.blue

    /// One colour from pale to deep (dark mode runs dim to bright, so busier
    /// days always stand out more from the background).
    private var ramp: [Color] { colorChoice.ramp(dark: scheme == .dark) }

    /// Rebuild the grid only when the year or the data changes, not on every hover.
    private var gridKey: String {
        "\(year)|\(stats.reviewsPerDay.count)|\(stats.todayReviews)|\(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)"
    }

    var body: some View {
        let step = cell + gap
        let gridHeight = 7 * step - gap

        VStack(alignment: .leading, spacing: 8) {
            // Measures the space available (not the heatmap's own size, which
            // would never let it shrink when the window gets smaller).
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: gap) {
                    Color.clear.frame(height: monthRow)
                    ForEach(0..<7, id: \.self) { row in
                        Text(["Mon", "", "Wed", "", "Fri", "", "Sun"][row])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(height: cell)
                    }
                }
                .frame(width: labelWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: gap) {
                    ZStack(alignment: .topLeading) {
                        ForEach(grid.months, id: \.week) { month in
                            Text(month.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .offset(x: CGFloat(month.week) * step)
                        }
                    }
                    // Flexible, not a fixed width, so the page can shrink with the window.
                    .frame(maxWidth: .infinity, minHeight: monthRow, maxHeight: monthRow, alignment: .topLeading)
                    .clipped()

                    squares(step: step)
                        // Click a day to see the cards you studied then, in their own window.
                        .onTapGesture(coordinateSpace: .local) { location in
                            if let day = grid.offset(at: location, step: step), (stats.reviewsPerDay[day] ?? 0) > 0 {
                                openWindow(id: "day-cards", value: day)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: gridHeight, maxHeight: gridHeight, alignment: .topLeading)
                        .overlay(alignment: .topLeading) { hoverLayer(step: step) }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): hovered = grid.offset(at: point, step: step)
                            case .ended: hovered = nil
                            }
                        }
                }
            }
            HStack {
                yearSwitcher
                Spacer()
                legend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: gridKey) { grid = HeatmapGrid(year: year, reviews: stats.reviewsPerDay) }
    }

    /// Every square drawn in one go, which keeps scrolling and hovering smooth.
    private func squares(step: CGFloat) -> some View {
        let empty = Color.primary.opacity(scheme == .dark ? 0.09 : 0.06)
        let future = Color.primary.opacity(0.08)
        let colors = ramp
        let size = cell
        let cells = grid.cells
        return Canvas { context, _ in
            for item in cells {
                let rect = CGRect(x: CGFloat(item.week) * step, y: CGFloat(item.row) * step, width: size, height: size)
                let path = Path(roundedRect: rect, cornerRadius: 3)
                switch item.level {
                case -1:
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(future), lineWidth: 1)
                case 0:
                    context.fill(path, with: .color(empty))
                default:
                    context.fill(path, with: .color(colors[item.level - 1]))
                }
                if item.offset == 0 {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3),
                                   with: .color(.primary.opacity(0.5)), lineWidth: 1)
                }
            }
        }
    }

    /// The outline round the hovered day and the card above it.
    @ViewBuilder
    private func hoverLayer(step: CGFloat) -> some View {
        if let hovered, let spot = grid.position(of: hovered) {
            let x = CGFloat(spot.week) * step
            let y = CGFloat(spot.row) * step
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.9), lineWidth: 1.5)
                    .frame(width: cell, height: cell)
                    .offset(x: x, y: y)
                DayCard(offset: hovered, stats: stats,
                        date: Calendar.current.date(byAdding: .day, value: hovered, to: Calendar.current.startOfDay(for: Date())) ?? Date())
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                    // Centred over the day, kept inside the grid, sitting just above it.
                    .offset(x: min(max(0, x + cell / 2 - cardSize.width / 2),
                                   max(0, CGFloat(grid.weeks) * step - cardSize.width)),
                            y: y - cardSize.height - 6)
            }
            .allowsHitTesting(false)
        }
    }

    private var yearSwitcher: some View {
        HStack(spacing: 6) {
            Button { year -= 1 } label: { Image(systemName: "chevron.left") }
                .disabled(year <= min(grid.firstYear, thisYear))
                .help("Previous year")
            Text(String(year))
                .font(.callout.weight(.semibold).monospacedDigit())
            Button { year += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(year >= thisYear)
                .help("Next year")
        }
        .buttonStyle(.hoverable)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            // Pick the heatmap's colour right here (also in Preferences).
            HStack(spacing: 5) {
                ForEach(HeatmapColor.allCases) { choice in
                    Button {
                        colorChoice = choice
                    } label: {
                        Circle()
                            .fill(choice.swatch)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(colorChoice == choice ? 0.9 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help("\(choice.title) heatmap")
                }
            }
            .padding(.trailing, 12)
            Text("Less").font(.caption2).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(scheme == .dark ? 0.09 : 0.06)).frame(width: cell, height: cell)
            ForEach(Array(ramp.enumerated()), id: \.offset) { _, c in
                RoundedRectangle(cornerRadius: 3).fill(c).frame(width: cell, height: cell)
            }
            Text("More").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The heatmap's squares for one year, worked out once.
struct HeatmapGrid {
    struct Cell {
        let week: Int
        let row: Int
        /// Days from today (0 = today).
        let offset: Int
        /// -1 = still to come, 0 = no reviews, 1…4 = how busy.
        let level: Int
    }

    struct Month {
        let week: Int
        let name: String
    }

    var weeks = 53
    var cells: [Cell] = []
    var months: [Month] = []
    var firstYear = Calendar.current.component(.year, from: Date())
    /// Square position for each past day, keyed by days from today.
    private var positions: [Int: (week: Int, row: Int)] = [:]
    /// Days from today at each square (nil outside the year).
    private var offsets: [[Int?]] = []

    static let empty = HeatmapGrid()

    private init() {}

    init(year: Int, reviews: [Int: Int]) {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // weeks start on Monday
        let today = calendar.startOfDay(for: Date())
        let jan1 = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
        let dec31 = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? today
        let start = calendar.dateInterval(of: .weekOfYear, for: jan1)?.start ?? jan1
        weeks = (calendar.dateComponents([.day], from: start, to: dec31).day ?? 364) / 7 + 1
        let startOffset = calendar.dateComponents([.day], from: today, to: start).day ?? 0

        // Thresholds split the days you studied into four even groups.
        let counts = reviews.values.filter { $0 > 0 }.sorted()
        let t = counts.isEmpty ? [1, 2, 3]
            : [0.25, 0.5, 0.75].map { counts[min(counts.count - 1, Int(Double(counts.count) * $0))] }

        offsets = Array(repeating: Array(repeating: nil, count: 7), count: weeks)
        for week in 0..<weeks {
            for row in 0..<7 {
                let index = week * 7 + row
                guard let date = calendar.date(byAdding: .day, value: index, to: start),
                      calendar.component(.year, from: date) == year else { continue }
                let offset = startOffset + index
                if calendar.component(.day, from: date) == 1 {
                    months.append(Month(week: week, name: date.formatted(.dateTime.month(.abbreviated))))
                }
                let level: Int
                if offset > 0 {
                    level = -1
                } else {
                    let count = reviews[offset] ?? 0
                    level = count == 0 ? 0 : count <= t[0] ? 1 : count <= t[1] ? 2 : count <= t[2] ? 3 : 4
                    positions[offset] = (week, row)
                    offsets[week][row] = offset
                }
                cells.append(Cell(week: week, row: row, offset: offset, level: level))
            }
        }
        let oldest = reviews.filter { $0.value > 0 }.keys.min() ?? 0
        firstYear = calendar.component(.year, from: calendar.date(byAdding: .day, value: oldest, to: today) ?? today)
    }

    func position(of offset: Int) -> (week: Int, row: Int)? { positions[offset] }

    /// The past day under a point in the grid, if any.
    func offset(at point: CGPoint, step: CGFloat) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let week = Int(point.x / step), row = Int(point.y / step)
        // The grid may not be worked out yet (e.g. the pointer was already over it at launch).
        guard week < offsets.count, row < offsets[week].count else { return nil }
        return offsets[week][row]
    }
}

/// The little card that appears over a heatmap day.
private struct DayCard: View {
    let offset: Int
    let stats: Stats
    let date: Date

    var body: some View {
        let count = stats.reviewsPerDay[offset] ?? 0
        let seconds = stats.secondsPerDay[offset] ?? 0
        let parts = stats.breakdownPerDay[offset] ?? []
        VStack(alignment: .leading, spacing: 4) {
            Text(offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if count == 0 {
                Text("No studying").font(.callout)
            } else {
                Text("\(count) card\(count == 1 ? "" : "s") · \(Self.duration(seconds))")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if parts.count == 3 {
                    HStack(spacing: 10) {
                        part(parts[0], "new", Palette.new)
                        part(parts[1], "relearned", Palette.learning)
                        part(parts[2], "reviewed", Palette.review)
                    }
                    .font(.caption)
                }
                Text("Click to see these cards")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private func part(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value) \(label)").monospacedDigit()
        }
        .opacity(value == 0 ? 0.5 : 1)
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
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
                            .help("\(part.0): \(part.1) cards")
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
                    .help(part.3)
                }
            }
        }
    }
}

// MARK: - Coming up

private struct DueAheadChart: View {
    let dueAhead: [Int: Int]
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    @AppStorage("stats.comingUpDays") private var range = 30
    @State private var hovered: Int?

    private var days: [(day: Int, count: Int)] { (0...range).map { ($0, dueAhead[$0] ?? 0) } }
    private var total: Int { days.reduce(0) { $0 + $1.count } }
    private var nextWeek: Int { (0...6).reduce(0) { $0 + (dueAhead[$1] ?? 0) } }
    private var average: Double { Double(total) / Double(days.count) }
    private var busiest: (day: Int, count: Int)? { days.max { $0.count < $1.count } }

    private func date(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private func label(_ offset: Int) -> String {
        if offset == 0 { return "Today" }
        if offset == 1 { return "Tomorrow" }
        return date(offset).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        if dueAhead.values.allSatisfy({ $0 == 0 }) {
            Text("Nothing scheduled yet. Study some cards and their reviews will show up here.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    summary("\(total.formatted())", range == 7 ? "in the next week" : "in the next 30 days")
                    summary("\(nextWeek.formatted())", "in the next 7 days").opacity(range == 7 ? 0 : 1)
                    if let busiest, busiest.count > 0 {
                        summary("\(busiest.count)", "on your busiest day, \(label(busiest.day))")
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

    private var chart: some View {
        Chart {
            ForEach(days, id: \.day) { item in
                BarMark(x: .value("Day", item.day), y: .value("Cards", item.count))
                    // Today stands out; the rest are a lighter tint of the same colour.
                    .foregroundStyle(item.day == 0 ? accent.color : accent.color.opacity(hovered == item.day ? 0.85 : 0.5))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            }
            RuleMark(y: .value("Average", average))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary)
                .annotation(position: .top, alignment: .trailing) {
                    Text("about \(Int(average.rounded())) a day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            if let hovered, let item = days.first(where: { $0.day == hovered }) {
                RuleMark(x: .value("Day", hovered))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(item.day)).font(.caption.weight(.semibold))
                            Text(item.count == 1 ? "1 card due" : "\(item.count) cards due").font(.caption)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartXAxis {
            AxisMarks(values: range == 7 ? Array(0...7) : [0, 7, 14, 21, 28]) { value in
                AxisValueLabel {
                    if let day = value.as(Int.self) {
                        Text(day == 0 ? "Today" : date(day).formatted(range == 7 ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel()
            }
        }
        .frame(height: 200)
        .animation(.snappy, value: range)
    }
}

extension Color {
    /// "#2a78d6" → Color.
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

extension Heatmap {
    /// Enough history to flip back a few years.
    static let historyDays: UInt32 = 5 * 366
}

/// Colours for the heatmap: one hue each, with big steps between levels so
/// light and heavy days are easy to tell apart.
enum HeatmapColor: String, CaseIterable, Identifiable {
    case blue, green, purple, orange, pink, teal
    static let key = "heatmapColor"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Pale → deep in light mode; dim → bright in dark mode.
    func ramp(dark: Bool) -> [Color] {
        let hexes: [String]
        switch (self, dark) {
        case (.blue, false): hexes = ["#cfe1fb", "#7eb0f0", "#2f78dc", "#0b3a80"]
        case (.blue, true): hexes = ["#1c3c6b", "#2f68bd", "#5c9ff0", "#bcdcff"]
        case (.green, false): hexes = ["#cdebd4", "#7ccc8e", "#2c9a4b", "#0c5424"]
        case (.green, true): hexes = ["#174428", "#2a8545", "#56c473", "#b8f0c6"]
        case (.purple, false): hexes = ["#e3d8f8", "#b193ec", "#7a4cd5", "#401c87"]
        case (.purple, true): hexes = ["#34205e", "#6440bd", "#9e7cf1", "#ddcfff"]
        case (.orange, false): hexes = ["#fde1c6", "#f6ab68", "#e1701c", "#8f3d08"]
        case (.orange, true): hexes = ["#55290d", "#a35116", "#ec8b3b", "#ffd5ad"]
        case (.pink, false): hexes = ["#f9d4e5", "#ee92bc", "#d6478a", "#851a4d"]
        case (.pink, true): hexes = ["#541b37", "#a3386a", "#e873a9", "#ffc9e1"]
        case (.teal, false): hexes = ["#cdeeee", "#79cccc", "#24999b", "#0a5456"]
        case (.teal, true): hexes = ["#144445", "#24837f", "#4fc4c0", "#b5f0ee"]
        }
        return hexes.map(Color.init(hex:))
    }

    /// The colour shown on its picker dot.
    var swatch: Color { ramp(dark: false)[2] }
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

    private var decks: [Deck] {
        if case .ready(let decks) = library.state { return decks }
        return []
    }

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
