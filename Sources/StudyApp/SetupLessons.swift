import Charts
import SwiftUI
import StudyCore

// The short "How it works" tour in setup, for people new to Anki.

// MARK: 1. Why it works

/// Two memory curves: one fading away, one topped up by reviews that get further apart.
struct MemoryLesson: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    @State private var drawn: Double = 0

    private static let reviews: [Double] = [1, 3, 7, 16]   // days
    private static let length: Double = 30

    private struct Point: Identifiable {
        let id = UUID()
        let day: Double
        let value: Double
        let series: String
    }

    /// How much you'd remember on each day, without and with reviews.
    private static let points: [Point] = {
        var out: [Point] = []
        let steps = 300
        for i in 0...steps {
            let t = length * Double(i) / Double(steps)
            out.append(Point(day: t, value: 100 * exp(-t / 2.2), series: "Without reviews"))
            let last = reviews.last { $0 <= t } ?? 0
            let done = Double(reviews.filter { $0 <= t }.count)
            out.append(Point(day: t, value: 100 * exp(-(t - last) / (2.2 * pow(2.6, done))), series: "With Animus"))
        }
        return out
    }()

    private func gap(_ day: Double) -> String {
        switch day {
        case 1: "1 day"
        case 3: "3 days"
        case 7: "1 week"
        default: "\(Int(day)) days"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            chart
                .frame(height: 200)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            Explainer(symbol: "arrow.up.right", color: .green, title: "The gaps grow",
                      text: "Each time you remember a card, it waits longer: tomorrow, then days, weeks, months.")
            Explainer(symbol: "target", color: .orange, title: "Time goes where it's needed",
                      text: "Cards you find easy rarely come back. Tricky ones come back often until they stick.")
        }
        .onAppear { withAnimation(.easeOut(duration: 1.4)) { drawn = 1 } }
    }

    private var chart: some View {
        let visible = Self.points.filter { $0.day <= Self.length * drawn + 0.001 }
        return Chart {
            ForEach(visible.filter { $0.series == "With Animus" }) { p in
                AreaMark(x: .value("Day", p.day), y: .value("Remembered", p.value), series: .value("Line", p.series))
                    .foregroundStyle(LinearGradient(colors: [accent.color.opacity(0.25), accent.color.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)
            }
            ForEach(visible) { p in
                LineMark(x: .value("Day", p.day), y: .value("Remembered", p.value), series: .value("Line", p.series))
                    .foregroundStyle(by: .value("Line", p.series))
                    .lineStyle(p.series == "With Animus" ? StrokeStyle(lineWidth: 2.5, lineJoin: .round)
                                                          : StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            // Each review, labelled with the gap since the last one.
            ForEach(Self.reviews.filter { $0 <= Self.length * drawn }, id: \.self) { day in
                PointMark(x: .value("Day", day), y: .value("Remembered", 100))
                    .foregroundStyle(accent.color)
                    .symbolSize(60)
                    .annotation(position: .top, spacing: 4) {
                        Text("review\n+\(gap(day))")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(["With Animus": accent.color, "Without reviews": Color.secondary])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartYScale(domain: 0...130)
        .chartXScale(domain: 0...Self.length)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: [0, 7, 14, 21, 30]) { value in
                AxisValueLabel { if let d = value.as(Int.self) { Text(d == 0 ? "Day 0" : "Day \(d)") } }
            }
        }
        .chartYAxisLabel("Remembered", position: .leading)
    }
}

// MARK: 2. Try a card

/// A pretend card to reveal and grade, explaining what each button does.
struct TryCardLesson: View {
    @Binding var done: Bool
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue

    @State private var index = 0
    @State private var revealed = false
    @State private var picked: Rating?

    private let cards = [
        ("What is the powerhouse of the cell?", "The mitochondria"),
        ("Which side of the heart pumps blood to the body?", "The left ventricle"),
        ("What does “animus” mean in Latin?", "Mind"),
    ]

    private let intervals: [Rating: String] = [.again: "<1m", .hard: "6m", .good: "1d", .easy: "4d"]

    var body: some View {
        let card = cards[index % cards.count]
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 14) {
                Text(card.0)
                    .font(.title2.weight(.medium))
                    .multilineTextAlignment(.center)
                if revealed {
                    Divider().padding(.horizontal, 40)
                    Text(card.1)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(accent.color)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16).fill(.background).shadow(color: .black.opacity(0.08), radius: 10, y: 3))

            if !revealed {
                HStack {
                    Text("Say the answer in your head first, then check.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Answer") { withAnimation(.spring(duration: 0.35)) { revealed = true } }
                        .buttonStyle(.borderedProminent)
                        .hoverGlow()
                        .controlSize(.large)
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(Rating.allCases) { rating in
                        GradeButton(rating: rating, interval: intervals[rating] ?? "") {
                            withAnimation(.snappy) {
                                picked = rating
                                done = true
                            }
                        }
                    }
                }
                if let picked {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                        Text(explanation(picked)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try another card") {
                            withAnimation(.snappy) {
                                index += 1
                                revealed = false
                                self.picked = nil
                            }
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(0.12)))
                    .transition(.opacity)
                } else {
                    Text("How well did you remember? The small times show when you'd see it again.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func explanation(_ rating: Rating) -> String {
        switch rating {
        case .again: "Again: you forgot. No problem, it comes back in about a minute so you can try once more. Being honest here is what makes the app work."
        case .hard: "Hard: you got it, but it was a struggle. It comes back a bit sooner than usual."
        case .good: "Good: you remembered. This is the button you'll press most. You'll see it tomorrow, then the gaps keep growing."
        case .easy: "Easy: it was instant. It skips ahead to a few days. Use it for cards that are far too easy."
        }
    }
}

// MARK: 3. The three numbers

struct NumbersLesson: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                tile("12", "New", "Cards you've never seen. You get a few each day, so they don't pile up.", Palette.new)
                tile("5", "Learning", "Seen today or recently. They come back after minutes until they stick.", Palette.learning)
                tile("48", "Due", "Cards you know, due for their check-up today.", Palette.review)
            }
            Explainer(symbol: "checkmark.circle", color: .green, title: "A good daily habit",
                      text: "Clear your Due cards every day, even on busy days. New cards are what you add on top when you have time.")
            Explainer(symbol: "calendar.badge.exclamationmark", color: .orange, title: "Missed a few days?",
                      text: "Nothing breaks. Due cards wait for you; just work through them a bit at a time.")
        }
    }

    private func tile(_ value: String, _ title: String, _ text: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.1)))
    }
}

// MARK: 4. Decks and sections

struct DecksLesson: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                miniDeck("Biology", "3 sections · 240 cards", "B", .green, big: true)
                Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary).padding(.top, 30)
                VStack(spacing: 8) {
                    miniDeck("Week 1: Cells", "80 cards", "W1", .teal)
                    miniDeck("Week 2: Heart", "90 cards", "W2", .blue)
                    miniDeck("Week 3: Lungs", "70 cards", "W3", .purple)
                }
            }
            Explainer(symbol: "play.circle", color: accent.color, title: "Study a whole deck or one section",
                      text: "Studying Biology covers all its weeks. Click a week to study just that one.")
            Explainer(symbol: "gearshape", color: .gray, title: "The cog on each deck",
                      text: "Rename it, move it into another deck, change how many new cards you get a day, export or delete it.")
        }
    }

    private func miniDeck(_ name: String, _ detail: String, _ initials: String, _ color: Color, big: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(initials)
                .font(.system(size: big ? 16 : 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: big ? 40 : 28, height: big ? 40 : 28)
                .background(RoundedRectangle(cornerRadius: big ? 10 : 7).fill(color.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(big ? .headline : .callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(big ? 14 : 9)
        .frame(width: big ? 220 : 230)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
}

// MARK: 5. Kinds of card

struct CardTypesLesson: View {
    private let kinds: [CardKind] = [.basic, .reversed, .cloze, .occlusion]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(kinds) { kind in
                VStack(alignment: .leading, spacing: 8) {
                    Label(kind.title, systemImage: kind.symbol).font(.headline)
                    HStack(spacing: 6) {
                        Text(kind.example.front).lineLimit(2)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(kind.example.back).lineLimit(2).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    Text(kind.shortUse).font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            }
        }
    }
}

extension CardKind {
    /// One line on when to use it, for the tour.
    var shortUse: String {
        switch self {
        case .basic: "For facts and definitions."
        case .reversed: "For vocabulary: learn it both ways round."
        case .typing: "For exact spellings and names."
        case .cloze: "For notes and slides: hide key words in a sentence."
        case .occlusion: "For diagrams: hide labels and recall them."
        case .other: "Card types that came with shared decks."
        }
    }
}
