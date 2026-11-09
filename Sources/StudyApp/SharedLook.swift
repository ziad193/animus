import SwiftUI
import StudyCore

// The look shared by the Mac app and the iPhone/iPad app: deck icons, count
// bubbles, the due bar and the study heatmap. Change them here and both apps follow.

/// A thin bar showing today's mix of new, learning and review cards.
struct DueBar: View {
    let deck: Deck

    var body: some View {
        let total = max(1, Double(deck.dueToday))
        GeometryReader { geo in
            HStack(spacing: 2) {
                if deck.dueToday == 0 {
                    Capsule().fill(Color.green.opacity(0.35))
                } else {
                    segment(deck.newCount, Palette.new, total, geo.size.width)
                    segment(deck.learnCount, Palette.learning, total, geo.size.width)
                    segment(deck.reviewCount, Palette.review, total, geo.size.width)
                }
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func segment(_ value: UInt32, _ color: Color, _ total: Double, _ width: CGFloat) -> some View {
        if value > 0 {
            Capsule().fill(color).frame(width: max(4, width * Double(value) / total))
        }
    }
}

/// Today's New / Learning / Due counts as three small coloured bubbles.
/// Zeros are hidden in compact mode (the sidebar) and faded otherwise.
struct CountPills: View {
    let deck: Deck
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            pill(deck.newCount, Palette.new, "New")
            pill(deck.learnCount, Palette.learning, "Learning")
            pill(deck.reviewCount, Palette.review, "Due")
        }
    }

    @ViewBuilder
    private func pill(_ value: UInt32, _ color: Color, _ label: String) -> some View {
        if !(compact && value == 0) {
            Text(Self.short(value))
                .font((compact ? Font.caption2 : .caption).weight(.semibold).monospacedDigit())
                .padding(.horizontal, compact ? 5 : 7)
                .padding(.vertical, compact ? 1 : 3)
                .background(Capsule().fill(color.opacity(value == 0 ? 0.06 : 0.16)))
                .foregroundStyle(value == 0 ? Color.secondary.opacity(0.6) : color)
                .tip("\(value) \(label.lowercased())")
        }
    }

    /// 5,827 → "5.8k" so bubbles stay small.
    static func short(_ value: UInt32) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
    }
}

/// A coloured rounded square with the deck's first letter.
struct DeckIcon: View {
    let deck: Deck
    let size: CGFloat

    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .mint, .red, .cyan]

    var color: Color { Self.colors[Int(UInt64(bitPattern: deck.id) % UInt64(Self.colors.count))] }

    var body: some View {
        let letter = deck.initials
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(letter)
                    .font(.system(size: size * (letter.count > 1 ? 0.4 : 0.5), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

extension Deck {
    /// The last part of the name, e.g. "Week 1" for "BB::Week 1".
    var shortName: String { path.last ?? name }
    var path: [String] { name.components(separatedBy: "::") }

    /// One or two characters for the deck's icon: "W1" for "Week 1",
    /// "BG" for "Basal Ganglia…", "C" for "Cancer".
    var initials: String {
        let words = shortName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first?.first else { return "•" }
        if let second = words.dropFirst().first?.first, words.count > 1 {
            return (String(first) + String(second)).uppercased()
        }
        // A single word: keep a leading number together ("1.CRD" → "1C").
        return String(first).uppercased()
    }

    /// e.g. "4 sections · 291 cards".
    var summary: String {
        let cards = totalCards == 1 ? "1 card" : "\(totalCards) cards"
        switch children.count {
        case 0: return cards
        case 1: return "1 section · \(cards)"
        default: return "\(children.count) sections · \(cards)"
        }
    }

    static func find(_ id: Int64, in decks: [Deck]) -> Deck? {
        for deck in decks {
            if deck.id == id { return deck }
            if let found = find(id, in: deck.children) { return found }
        }
        return nil
    }
}

extension Deck {
    /// Every deck, parents before their sections, in the usual order.
    static func flatten(_ decks: [Deck]) -> [Deck] {
        decks.flatMap { [$0] + flatten($0.children) }
    }

    /// This deck's id and all of its sections' ids.
    var idsIncludingSections: [Int64] {
        [id] + children.flatMap(\.idsIncludingSections)
    }

    /// "BB › Week 1 › Basal Ganglia".
    var displayPath: String { path.joined(separator: " › ") }
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
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var grid = HeatmapGrid.empty

    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 30
    private let monthRow: CGFloat = 14

    private var thisYear: Int { Calendar.current.component(.year, from: Date()) }

    /// Squares grow to fill the panel's width.
    private var cell: CGFloat {
        let weeks = max(grid.weeks, 1)
        let available = width - labelWidth - 6 - CGFloat(weeks - 1) * gap
        #if os(iOS)
        // Phones are too narrow for a whole year: squares stay big enough to
        // see there, and the year scrolls sideways. iPads fit it, as on the Mac.
        return max(width < 600 ? 11 : 8, min(18, floor(available / CGFloat(weeks))))
        #else
        return max(8, min(18, floor(available / CGFloat(weeks))))
        #endif
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
                #if os(iOS)
                ScrollView(.horizontal, showsIndicators: false) {
                    yearGrid(step: step, gridHeight: gridHeight)
                        .frame(width: CGFloat(grid.weeks) * step - gap)
                }
                .defaultScrollAnchor(.trailing)
                #else
                yearGrid(step: step, gridHeight: gridHeight)
                #endif
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

    /// The month names and the year's squares.
    @ViewBuilder
    private func yearGrid(step: CGFloat, gridHeight: CGFloat) -> some View {
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
                    #if os(macOS)
                    if let day = grid.offset(at: location, step: step), (stats.reviewsPerDay[day] ?? 0) > 0 {
                        openWindow(id: "day-cards", value: day)
                    }
                    #else
                    // On a touch screen, tap a day to see its numbers (tap again to hide).
                    let day = grid.offset(at: location, step: step)
                    hovered = hovered == day ? nil : day
                    #endif
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
                .tip("Previous year")
            Text(String(year))
                .font(.callout.weight(.semibold).monospacedDigit())
            Button { year += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(year >= thisYear)
                .tip("Next year")
        }
        .buttonStyle(.hoverable)
    }

    private var legend: some View {
        HStack(spacing: 4) {
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
struct DayCard: View {
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

    /// Always pale → deep: lighter for quiet days, darker for busy ones (in dark mode too).
    func ramp(dark: Bool) -> [Color] {
        let hexes: [String]
        switch self {
        case .blue: hexes = ["#cfe1fb", "#7eb0f0", "#2f78dc", "#0b3a80"]
        case .green: hexes = ["#cdebd4", "#7ccc8e", "#2c9a4b", "#0c5424"]
        case .purple: hexes = ["#e3d8f8", "#b193ec", "#7a4cd5", "#401c87"]
        case .orange: hexes = ["#fde1c6", "#f6ab68", "#e1701c", "#8f3d08"]
        case .pink: hexes = ["#f9d4e5", "#ee92bc", "#d6478a", "#851a4d"]
        case .teal: hexes = ["#cdeeee", "#79cccc", "#24999b", "#0a5456"]
        }
        return hexes.map(Color.init(hex:))
    }

    /// The colour shown on its picker dot.
    var swatch: Color { ramp(dark: false)[2] }
}

/// Turning field HTML into text for previews and checks.
enum HTMLText {
    /// Plain text, roughly as it reads on the card ("[picture]" for images).
    static func plain(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"<br\s*/?>|</div>|</p>|</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<img[^>]*>"#, with: "[picture]", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\[sound:[^\]]+\]"#, with: "🔊", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .newlines)
    }

    static func hasMedia(_ html: String) -> Bool {
        html.range(of: "<img", options: .caseInsensitive) != nil || html.contains("[sound:")
    }

    /// Small clean-ups before saving: no trailing empty lines from the editor.
    static func tidy(_ html: String) -> String {
        var out = html.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = out.range(of: #"(<br\s*/?>|<div><br\s*/?></div>)$"#, options: [.regularExpression, .caseInsensitive]) {
            out.removeSubrange(range)
        }
        return out
    }
}

/// A gap between reviews in words: "10 min", "3 days", "2.5 months".
enum IntervalText {
    static func days(_ d: Double) -> String {
        if d < 1 { return "\(max(1, Int((d * 24 * 60).rounded()))) min" }
        if d < 31 { return "\(Int(d.rounded())) day\(Int(d.rounded()) == 1 ? "" : "s")" }
        if d < 365 { return String(format: "%.1f months", d / 30.4) }
        return String(format: "%.1f years", d / 365)
    }
}
