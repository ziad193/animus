import AppKit
import StudyCore
import SwiftUI

// The second batch of Animus+ workflows: Fix my card (and the leech doctor),
// cards from a photo, "why did I get that wrong?", exam plans, practice
// questions and the weekly report. Like the first batch they go through
// `PlusAI.current` only, so the stand-in works today and real models later.

// MARK: - Fix my card (and the leech doctor)

struct FixCardSheet: View {
    let cardID: Int64
    /// Called after the card was changed, so the study screen can reload it.
    var onChanged: () -> Void = {}
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var note: EditableNote?
    @State private var lapses = 0
    @State private var drafts: [DraftCard] = []
    @State private var making = true
    @State private var working = false
    @State private var problem: String?
    @State private var done: String?

    private var original: CardText {
        CardText(front: note?.fields.first?.plainText ?? "",
                 back: (note?.fields.count ?? 0) > 1 ? note!.fields[1].plainText : "")
    }
    /// A split is several fill-in-the-blank cards; otherwise one rewrite.
    private var isSplit: Bool { drafts.count > 1 || drafts.contains { $0.front.contains("{{c") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: PlusFeature.fixCard.symbol).foregroundStyle(Color.accentColor)
                Text("Fix my card").font(.title2.weight(.semibold))
                PlusBadge()
            }
            if lapses >= 4 {
                Label("You've forgotten this card \(lapses) times, so it's worth fixing. Shorter, single-fact cards stick better.",
                      systemImage: "cross.case").font(.callout).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Now").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(original.front).font(.callout.weight(.medium))
                Text(original.back).font(.callout).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))

            HStack {
                Text(isSplit ? "Suggested: split into \(drafts.count) cards" : "Suggested rewrite")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if making { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($drafts) { $draft in
                        DraftRow(draft: $draft, cloze: draft.front.contains("{{c"), selected: false) {
                            drafts.removeAll { $0.id == draft.id }
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 320)

            if PlusAI.current.isStandIn {
                Text("Stand-in suggestion: no AI is connected yet.").font(.caption2).foregroundStyle(.orange)
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if let done { Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }

            HStack {
                if isSplit {
                    Text("The original is paused (suspended), not deleted, so its history stays.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(done == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if done == nil {
                    Button(isSplit ? "Use These \(drafts.filter(\.keep).count) Cards" : "Replace Card") {
                        Task { await apply() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(making || working || drafts.filter(\.keep).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 620)
        .task { await start() }
    }

    private func start() async {
        guard let engine = library.engine else { return }
        note = try? await engine.note(forCard: cardID)
        lapses = (try? await engine.leechState(cardID))?.lapses ?? 0
        do {
            for try await draft in PlusAI.current.improve(original) { drafts.append(draft) }
        } catch {
            problem = "Couldn't finish: \(error.localizedDescription)"
        }
        making = false
    }

    private func apply() async {
        guard let engine = library.engine, let note else { return }
        working = true
        defer { working = false }
        let kept = drafts.filter(\.keep)
        do {
            if isSplit {
                var types = try await engine.noteTypes()
                if !types.contains(where: { $0.kind == "cloze" }) {
                    _ = try await engine.addStockNoteType("cloze")
                    types = try await engine.noteTypes()
                }
                guard let cloze = types.first(where: { $0.kind == "cloze" }) else { return }
                for draft in kept {
                    var fields = [draft.front.cardHTML, draft.back.cardHTML]
                    while fields.count < cloze.fields.count { fields.append("") }
                    _ = try await engine.addNote(noteType: cloze.id, deck: note.deckID,
                                                 fields: Array(fields.prefix(cloze.fields.count)), tags: note.tags + ["animus-plus"])
                }
                try await engine.setSuspended([cardID], true)
                done = "Added \(kept.count) cards and paused the original."
            } else if let rewrite = kept.first {
                // Same note, new wording: its review history is kept.
                var fields = note.fields
                if !fields.isEmpty { fields[0] = rewrite.front.cardHTML }
                if fields.count > 1 { fields[1] = rewrite.back.cardHTML }
                try await engine.updateNote(note.noteID, fields: fields, tags: note.tags)
                done = "Card updated. Its progress is kept."
            }
            onChanged()
        } catch {
            problem = "Couldn't change the card: \(error.localizedDescription)"
        }
    }
}

// MARK: - Cards from a photo

struct PictureCardsSheet: View {
    var deckID: Int64?
    @Environment(\.dismiss) private var dismiss
    @State private var picture: NSImage?
    @State private var targeted = false
    @State private var problem: String?

    var body: some View {
        if let picture {
            DraftReviewView(title: "Cards from your picture", feature: .pictureToCards,
                            source: .picture(picture), cloze: false, checkDeck: true,
                            make: {
                                guard let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                                    return AsyncThrowingStream { $0.finish() }
                                }
                                return PlusAI.current.cards(fromPicture: cg)
                            },
                            deckID: deckID) { dismiss() }
        } else {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text(PlusFeature.pictureToCards.title).font(.title2.weight(.semibold))
                    PlusBadge()
                }
                Text(PlusFeature.pictureToCards.detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 44)).foregroundStyle(.tint)
                    Text("Drop a photo or picture here").font(.headline)
                    HStack {
                        Button { choose() } label: { Label("Choose Picture…", systemImage: "folder") }
                            .buttonStyle(.borderedProminent)
                        Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    }
                    .controlSize(.large)
                    Text("Photos from your iPhone appear in Finder › AirDrop, or use Continuity Camera: right-click in Finder › Import from iPhone.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, let image = NSImage(contentsOf: url) else { return false }
                    picture = image
                    return true
                } isTargeted: { targeted = $0 }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .padding(24)
            .frame(width: 620)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        picture = image
    }

    private func paste() {
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
            picture = image
        } else {
            problem = "There's no picture on the clipboard. Copy one first."
        }
    }
}

// MARK: - Why did I get that wrong?

/// Appears after you press Again: why the card is easy to miss, and a hook to
/// remember it. Stays until you close it or miss another card.
struct MissedCardPanel: View {
    let context: AskContext
    let askMore: () -> Void
    let close: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: PlusFeature.explainMistakes.symbol).foregroundStyle(.yellow)
                Text("Why you might have missed it").font(.callout.weight(.semibold))
                PlusBadge()
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.hoverable)
                    .tip("Close")
            }
            Text(context.question).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(2)
            Text(text.isEmpty ? "…" : text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Ask more", action: askMore).buttonStyle(.link).font(.callout)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .task(id: context.question) {
            text = ""
            do {
                for try await piece in PlusAI.current.explainMistake(context) { text += piece }
            } catch {}
        }
    }
}

// MARK: - Exam plan

struct ExamPlanSheet: View {
    let exam: Exam
    let deck: Deck?
    let study: (Deck) -> Void
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var stats: Stats?
    @State private var weakest: [(deck: Deck, retention: Double)] = []
    @State private var advice = ""
    @State private var loading = true

    /// New cards to finish three days before the exam, leaving time to revise.
    private var newPerDay: Int {
        guard let stats else { return 0 }
        let days = max(exam.daysLeft - 3, 1)
        return Int((Double(stats.cardsNew) / Double(days)).rounded(.up))
    }
    private var reviewsPerDay: Int {
        guard let stats else { return 0 }
        let week = (0..<7).reduce(0) { $0 + (stats.dueAhead[$1] ?? 0) }
        return Int((Double(week) / 7).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: PlusFeature.examPlan.symbol).foregroundStyle(Color.accentColor)
                Text("Plan for \(exam.name)").font(.title2.weight(.semibold)).lineLimit(1)
                PlusBadge()
            }
            if deck == nil {
                Text("Link a deck to this exam (edit the exam) so Animus can plan from its cards.")
                    .foregroundStyle(.secondary)
            } else if loading {
                ProgressView("Working it out…").frame(maxWidth: .infinity, minHeight: 160)
            } else if let stats {
                HStack(spacing: 12) {
                    tile("\(exam.daysLeft)", exam.daysLeft == 1 ? "day left" : "days left", .blue)
                    tile("\(newPerDay)", "new cards a day", .blue)
                    tile("~\(reviewsPerDay)", "reviews a day", .green)
                    tile(stats.retentionMonth.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "remembered (30 days)", .purple)
                }
                Text(stats.cardsNew == 0
                     ? "You've seen every card. Keep up with reviews and practise your weakest sections."
                     : "To see all \(stats.cardsNew) new cards with three days to spare for revision, do about \(newPerDay) new cards a day.")
                    .font(.callout)
                if !weakest.isEmpty {
                    Text("Weakest sections").font(.headline)
                    ForEach(weakest, id: \.deck.id) { item in
                        HStack {
                            Text(item.deck.shortName)
                            Spacer()
                            Text("\(Int((item.retention * 100).rounded()))% remembered")
                                .font(.callout.monospacedDigit()).foregroundStyle(.orange)
                            Button("Study") { dismiss(); study(item.deck) }
                                .disabled(item.deck.dueToday == 0)
                        }
                    }
                }
                Text("Advice").font(.headline)
                Text(advice.isEmpty ? "…" : advice).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .task { await load() }
    }

    private func tile(_ value: String, _ title: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
    }

    private func load() async {
        guard let engine = library.engine, let deck else { loading = false; return }
        stats = try? await engine.stats(days: 30, search: Self.search(deck))
        // Each section's recent memory, weakest first (only ones you've studied).
        var scores: [(Deck, Double)] = []
        for child in deck.children {
            if let s = try? await engine.stats(days: 30, search: Self.search(child)), let r = s.retentionMonth {
                scores.append((child, r))
            }
        }
        weakest = scores.sorted { $0.1 < $1.1 }.prefix(3).map { (deck: $0.0, retention: $0.1) }
        loading = false
        let newLeft: Int = stats?.cardsNew ?? 0
        let remembered: Int = stats?.retentionMonth.map { Int($0 * 100) } ?? 0
        let weakList: [String] = weakest.map { "\($0.deck.shortName) \(Int($0.retention * 100))%" }
        var facts = "\(exam.daysLeft) days until \(exam.name). \(newLeft) new cards left, about \(newPerDay) a day. "
        facts += "About \(reviewsPerDay) reviews a day. Remembered \(remembered)% in the last 30 days. "
        if !weakList.isEmpty { facts += "Weakest: \(weakList.joined(separator: ", "))." }
        do {
            for try await piece in PlusAI.current.advice(.examPlan(facts: facts)) { advice += piece }
        } catch {}
    }

    static func search(_ deck: Deck) -> String {
        "deck:\"\(deck.name.replacingOccurrences(of: "\"", with: ""))\""
    }
}

// MARK: - Practice questions

struct PracticeSheet: View {
    let deck: Deck
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var questions: [PracticeQuestion] = []
    @State private var index = 0
    @State private var picked: Int?
    @State private var score = 0
    @State private var loading = true
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: PlusFeature.practiceQuestions.symbol).foregroundStyle(Color.accentColor)
                Text("Practice: \(deck.shortName)").font(.title2.weight(.semibold)).lineLimit(1)
                PlusBadge()
                Spacer()
                if !questions.isEmpty && !finished {
                    Text("\(index + 1) of \(questions.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if loading && questions.isEmpty {
                ProgressView("Writing questions from your cards…").frame(maxWidth: .infinity, minHeight: 220)
            } else if questions.isEmpty {
                ContentUnavailableView("Not enough cards", systemImage: "rectangle.stack.badge.minus",
                                       description: Text("This deck needs more cards with short answers to make questions from."))
            } else if finished {
                VStack(spacing: 12) {
                    Text("\(score) out of \(questions.count)").font(.system(size: 40, weight: .bold, design: .rounded))
                    Text(score == questions.count ? "Perfect!" : "The ones you missed are worth another look.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { restart() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                question(questions[index])
            }
            if PlusAI.current.isStandIn {
                Text("Stand-in questions: built from your own cards; no AI is connected yet.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .task { await load() }
    }

    private func question(_ q: PracticeQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(q.stem).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(q.options.enumerated()), id: \.offset) { offset, option in
                Button {
                    guard picked == nil else { return }
                    picked = offset
                    if offset == q.correct { score += 1 }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(UnicodeScalar(65 + offset)!)).font(.callout.weight(.bold)).frame(width: 18)
                        Text(option).multilineTextAlignment(.leading)
                        Spacer()
                        if picked != nil && offset == q.correct { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        if picked == offset && offset != q.correct { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(fill(offset, q)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if picked != nil {
                Text(q.explanation).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(index + 1 < questions.count ? "Next Question" : "See Score") {
                        if index + 1 < questions.count { index += 1; picked = nil } else { finished = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func fill(_ offset: Int, _ q: PracticeQuestion) -> Color {
        guard let picked else { return Color.primary.opacity(0.05) }
        if offset == q.correct { return Color.green.opacity(0.18) }
        if offset == picked { return Color.red.opacity(0.18) }
        return Color.primary.opacity(0.03)
    }

    private func restart() {
        questions.shuffle()
        index = 0; picked = nil; score = 0; finished = false
    }

    private func load() async {
        guard let engine = library.engine else { loading = false; return }
        let ids = (try? await engine.search(ExamPlanSheet.search(deck) + " -is:suspended")) ?? []
        let rows = (try? await engine.browseRows(Array(ids.prefix(300)))) ?? []
        let cards = rows.map { CardText(front: $0.text(.front).plainText, back: $0.text(.back).plainText) }
        do {
            for try await q in PlusAI.current.practiceQuestions(from: cards) { questions.append(q) }
        } catch {}
        loading = false
    }
}

// MARK: - Weekly report

struct WeeklyReportPanel: View {
    let stats: Stats
    let decks: [Deck]
    @Environment(Library.self) private var library
    @State private var report = ""
    @State private var writing = false

    private var weekReviews: Int { (-6...0).reduce(0) { $0 + (stats.reviewsPerDay[$1] ?? 0) } }
    private var weekMinutes: Int { (-6...0).reduce(0) { $0 + (stats.secondsPerDay[$1] ?? 0) } / 60 }
    private var daysStudied: Int { (-6...0).filter { (stats.reviewsPerDay[$0] ?? 0) > 0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: PlusFeature.weeklyReport.symbol).foregroundStyle(Color.accentColor)
                Text("Your week").font(.title3.weight(.semibold))
                PlusBadge()
                Spacer()
                Button {
                    Task { await write() }
                } label: {
                    if writing { ProgressView().controlSize(.small) } else { Text(report.isEmpty ? "Write My Report" : "Write Again") }
                }
                .disabled(writing)
            }
            Text("\(weekReviews) reviews · \(weekMinutes) min · studied \(daysStudied) of 7 days")
                .font(.callout).foregroundStyle(.secondary)
            if !report.isEmpty {
                Text(report).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BlockFill(cornerRadius: 16, plain: AnyShapeStyle(.background)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5)))
    }

    private func write() async {
        guard let engine = library.engine else { return }
        writing = true
        defer { writing = false }
        report = ""
        var perDeck: [String] = []
        for deck in decks {
            if let s = try? await engine.stats(days: 7, search: ExamPlanSheet.search(deck)), let r = s.retentionMonth {
                perDeck.append("\(deck.shortName) \(Int((r * 100).rounded()))%")
            }
        }
        let remembered: Int = stats.retentionMonth.map { Int($0 * 100) } ?? 0
        var facts = "\(weekReviews) reviews, \(weekMinutes) minutes, studied \(daysStudied) of 7 days. "
        facts += "Remembered \(remembered)% over 30 days. "
        if !perDeck.isEmpty { facts += "By deck: \(perDeck.joined(separator: ", "))." }
        do {
            for try await piece in PlusAI.current.advice(.weeklyReport(facts: facts)) { report += piece }
        } catch {}
    }
}
