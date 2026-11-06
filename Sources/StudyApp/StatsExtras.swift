import Charts
import SwiftUI
import StudyCore

// MARK: - True retention

/// How often you remembered cards when they came back: Anki's "true retention".
struct RetentionTable: View {
    let stats: Stats
    private let periods = ["Today", "Yesterday", "Last 7 days", "Last 30 days", "Last year", "All time"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Out of the reviews in each period, how many you got right (anything but Again). Young cards are ones you've known under 3 weeks; mature cards, longer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                GridRow {
                    Text("")
                    Text("Young").gridColumnAlignment(.trailing)
                    Text("Mature").gridColumnAlignment(.trailing)
                    Text("All").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(Array(stats.trueRetention.prefix(periods.count).enumerated()), id: \.offset) { index, row in
                    let yp = row[safe: 0] ?? 0, yf = row[safe: 1] ?? 0, mp = row[safe: 2] ?? 0, mf = row[safe: 3] ?? 0
                    GridRow {
                        Text(periods[index])
                        cell(yp, yf)
                        cell(mp, mf)
                        cell(yp + mp, yf + mf, bold: true)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }

    private func cell(_ passed: Int, _ failed: Int, bold: Bool = false) -> some View {
        let total = passed + failed
        return VStack(alignment: .trailing, spacing: 0) {
            Text(total == 0 ? "–" : "\(Int((Double(passed) / Double(total) * 100).rounded()))%")
                .fontWeight(bold ? .semibold : .regular)
            if total > 0 {
                Text("\(passed.formatted()) of \(total.formatted())").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .tip(total == 0 ? "No reviews" : "\(passed) remembered, \(failed) forgotten")
    }
}

// MARK: - Answer buttons

/// Which buttons you press, for cards at each stage (last 3 months).
struct AnswerButtonsChart: View {
    let stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which button you pressed over the last 3 months. Lots of Again on mature cards can mean your intervals are too long.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 18) {
                group("Learning", stats.buttonsLearning)
                group("Young", stats.buttonsYoung)
                group("Mature", stats.buttonsMature)
            }
        }
    }

    private func group(_ title: String, _ counts: [Int]) -> some View {
        let total = max(1, counts.reduce(0, +))
        let bars = Rating.allCases.map { rating in
            (rating: rating, count: counts[safe: Int(rating.rawValue) - 1] ?? 0)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(counts.reduce(0, +).formatted()) answers").font(.caption).foregroundStyle(.secondary)
            }
            Chart(bars, id: \.rating) { bar in
                BarMark(x: .value("Button", bar.rating.title),
                        y: .value("Share", Double(bar.count) / Double(total)),
                        width: .fixed(26))
                    .foregroundStyle(Palette.grade(bar.rating).gradient)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .top, spacing: 3) {
                        Text("\(Int((Double(bar.count) / Double(total) * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...1.15)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption) }
            }
            .frame(height: 130)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Time of day

/// When in the day you study, and how well it goes then.
struct HourChart: View {
    let stats: Stats
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    @State private var hovered: Int?

    private var hours: [(hour: Int, total: Int, correct: Int)] {
        (0..<24).map { h in
            let value = stats.hours[safe: h]
            return (h, value?.total ?? 0, value?.correct ?? 0)
        }
    }

    private var best: (hour: Int, rate: Double)? {
        hours.filter { $0.total >= 20 }
            .map { ($0.hour, Double($0.correct) / Double($0.total)) }
            .max { $0.1 < $1.1 }
            .map { (hour: $0.0, rate: $0.1) }
    }

    private static func label(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let best {
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                    Text("You remember best around **\(Self.label(best.hour))** (\(Int((best.rate * 100).rounded()))% right).")
                } else {
                    Text("Reviews by hour of the day, over the last 3 months.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Chart(hours, id: \.hour) { item in
                BarMark(x: .value("Hour", item.hour), y: .value("Reviews", item.total), width: .fixed(14))
                    .foregroundStyle(accent.color.opacity(hovered == nil || hovered == item.hour ? 1 : 0.4))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            }
            .chartXScale(domain: -0.6...23.6)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisValueLabel { Text(Self.label(value.as(Int.self) ?? 0)).font(.caption) }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                    AxisValueLabel().font(.caption)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                guard let frame = proxy.plotFrame.map({ geo[$0] }) else { return }
                                let x = point.x - frame.minX
                                if let hour: Double = proxy.value(atX: x) {
                                    hovered = min(23, max(0, Int(hour.rounded())))
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let hovered, let item = hours[safe: hovered] {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Self.label(item.hour))–\(Self.label((item.hour + 1) % 24))").font(.caption.weight(.semibold))
                        Text("\(item.total.formatted()) reviews").font(.caption)
                        if item.total > 0 {
                            Text("\(Int((Double(item.correct) / Double(item.total) * 100).rounded()))% right").font(.caption)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 170)
        }
    }
}

// MARK: - Intervals

/// How far apart your reviews have grown: a sign of how well cards are sticking.
struct IntervalChart: View {
    let stats: Stats
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue

    private static let buckets: [(label: String, range: ClosedRange<Int>)] = [
        ("1 day", 0...1), ("2–3 d", 2...3), ("4–7 d", 4...7), ("1–2 wk", 8...14),
        ("2–4 wk", 15...30), ("1–3 mo", 31...90), ("3–6 mo", 91...180),
        ("6–12 mo", 181...365), ("1 yr +", 366...Int.max),
    ]

    private var rows: [(label: String, count: Int)] {
        Self.buckets.map { bucket in
            (bucket.label, stats.intervals.filter { bucket.range.contains($0.key) }.reduce(0) { $0 + $1.value })
        }
    }

    private var median: Int? {
        let sorted = stats.intervals.sorted { $0.key < $1.key }
        let total = sorted.reduce(0) { $0 + $1.value }
        guard total > 0 else { return nil }
        var running = 0
        for (days, count) in sorted {
            running += count
            if running * 2 >= total { return days }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(median.map { "Half of your review cards come back every **\(CardInfoSheet.days(Double($0)))** or longer. The more cards on the right, the better they're sticking." }
                 ?? "No review cards yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Chart(rows, id: \.label) { row in
                BarMark(x: .value("Gap", row.label), y: .value("Cards", row.count), width: .fixed(30))
                    .foregroundStyle(accent.color.gradient)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .top, spacing: 3) {
                        if row.count > 0 {
                            Text(row.count.formatted()).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption) } }
            .frame(height: 170)
        }
    }
}
