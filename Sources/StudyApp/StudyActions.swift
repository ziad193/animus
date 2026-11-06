import SwiftUI
import StudyCore

/// Anki's seven flag colours.
struct FlagColor: Identifiable {
    let number: Int
    let name: String
    let color: Color
    var id: Int { number }

    static let all: [FlagColor] = [
        .init(number: 1, name: "Red", color: Color(red: 0.93, green: 0.26, blue: 0.24)),
        .init(number: 2, name: "Orange", color: Color(red: 0.98, green: 0.58, blue: 0.13)),
        .init(number: 3, name: "Green", color: Color(red: 0.25, green: 0.72, blue: 0.33)),
        .init(number: 4, name: "Blue", color: Color(red: 0.24, green: 0.52, blue: 0.95)),
        .init(number: 5, name: "Pink", color: Color(red: 0.95, green: 0.42, blue: 0.75)),
        .init(number: 6, name: "Turquoise", color: Color(red: 0.12, green: 0.75, blue: 0.75)),
        .init(number: 7, name: "Purple", color: Color(red: 0.6, green: 0.38, blue: 0.9)),
    ]

    static func of(_ flag: Int) -> FlagColor? { all.first { $0.number == flag } }
}

/// The row of small buttons above the card: edit, flag, mark, bury, suspend, info, more.
struct CardActionBar: View {
    let session: StudySession
    let card: StudyCard

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            barButton("Edit", "pencil", "Edit this card (E)") { session.editing = card.id }

            Menu {
                ForEach(FlagColor.all) { flag in
                    Button {
                        Task { await session.setFlag(flag.number) }
                    } label: {
                        Label(card.flag == flag.number ? "\(flag.name) ✓" : flag.name, systemImage: "flag.fill")
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(flag.number)")), modifiers: .command)
                }
                if card.flag != 0 {
                    Divider()
                    Button("Remove Flag") { Task { await session.setFlag(card.flag) } }
                }
            } label: {
                chip(FlagColor.of(card.flag)?.name ?? "Flag", card.flag == 0 ? "flag" : "flag.fill",
                     tint: FlagColor.of(card.flag)?.color)
            }
            .menuStyle(.button)
            .buttonStyle(.hoverable)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Flag this card with a colour (⌘1–7). Find flagged cards in Browse.")

            barButton(card.marked ? "Marked" : "Mark", card.marked ? "star.fill" : "star",
                      "Mark this note to come back to it (*)", tint: card.marked ? .yellow : nil) {
                Task { await session.toggleMark() }
            }
            barButton("Bury", "moon.zzz", "Skip it until tomorrow (-)") { Task { await session.bury() } }
            barButton("Suspend", "pause.circle", "Stop showing it until you unsuspend it in Browse (@)") {
                Task { await session.suspend() }
            }
            barButton("Info", "info.circle", "This card's history and stats (I)") { session.info = card.id }

            Menu {
                Button { session.settingDue = card.id } label: { Label("Set Due Date…", systemImage: "calendar") }
                Button { Task { await session.forget() } } label: {
                    Label("Reset to New", systemImage: "arrow.counterclockwise")
                }
                Divider()
                Button(role: .destructive) { session.confirmingDelete = true } label: {
                    Label("Delete Note…", systemImage: "trash")
                }
            } label: {
                chip("More", "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.hoverable)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Set due date, reset to new, or delete")
            Spacer()
        }
        .font(.callout)
    }

    private func barButton(_ title: String, _ symbol: String, _ help: String, tint: Color? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { chip(title, symbol, tint: tint) }
            .buttonStyle(.hoverable)
            .help(help)
    }

    private func chip(_ title: String, _ symbol: String, tint: Color? = nil) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
    }
}

// MARK: - Sheets

private struct StudyActionSheets: ViewModifier {
    @Bindable var session: StudySession
    let decks: [Deck]

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { session.editing.map(CardRef.init) }, set: { session.editing = $0?.id })) { ref in
                StudyEditSheet(cardID: ref.id, decks: decks) {
                    Task { await session.refreshAfterEdit() }
                }
            }
            .sheet(item: Binding(get: { session.info.map(CardRef.init) }, set: { session.info = $0?.id })) { ref in
                CardInfoSheet(cardID: ref.id)
            }
            .sheet(item: Binding(get: { session.settingDue.map(CardRef.init) }, set: { session.settingDue = $0?.id })) { _ in
                SetDueSheet { days in Task { await session.setDue(days) } }
            }
            .confirmationDialog("Delete this note?", isPresented: $session.confirmingDelete) {
                Button("Delete Note", role: .destructive) { Task { await session.deleteNote() } }
            } message: {
                Text("This deletes the note and every card made from it. You can undo it straight after with ⌘Z.")
            }
    }

    struct CardRef: Identifiable { let id: Int64 }
}

extension View {
    func studyActionSheets(session: StudySession, decks: [Deck]) -> some View {
        modifier(StudyActionSheets(session: session, decks: decks))
    }
}

/// The Browse editor in a sheet, so you can fix a card mid-study.
private struct StudyEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let cardID: Int64
    let decks: [Deck]
    let onClose: () -> Void
    @State private var model = BrowseModel()

    var body: some View {
        VStack(spacing: 0) {
            NoteEditorPanel(cardID: cardID, decks: decks)
                .environment(model)
            Divider()
            HStack {
                Text("Save your changes, then go back to studying.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Back to Studying") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 640)
        .onDisappear(perform: onClose)
    }
}

/// Pick when the card comes back.
struct SetDueSheet: View {
    @Environment(\.dismiss) private var dismiss
    var count = 1
    let onSet: (String) -> Void
    @State private var custom = ""

    private let presets: [(String, String)] = [
        ("Today", "0"), ("Tomorrow", "1"), ("In 3 days", "3"),
        ("In a week", "7"), ("In 2 weeks", "14"), ("In a month", "30"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(count == 1 ? "When should it come back?" : "When should these \(count) cards come back?", systemImage: "calendar")
                .font(.title2.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(presets, id: \.1) { title, days in
                    Button {
                        onSet(days)
                        dismiss()
                    } label: {
                        Text(title).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .hoverGlow()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Or a number of days").font(.subheadline.weight(.medium))
                HStack {
                    TextField("e.g. 10, or 5-9 for a random day in that range", text: $custom)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(setCustom)
                    Button("Set", action: setCustom)
                        .buttonStyle(.borderedProminent)
                        .hoverGlow()
                        .disabled(!customIsValid)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var customIsValid: Bool {
        custom.trimmingCharacters(in: .whitespaces).range(of: #"^\d+(-\d+)?!?$"#, options: .regularExpression) != nil
    }

    private func setCustom() {
        guard customIsValid else { return }
        onSet(custom.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}

/// Everything Anki knows about a card, laid out plainly.
struct CardInfoSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let cardID: Int64
    @State private var info: CardInfo?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Card info", systemImage: "info.circle").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            if let info {
                ScrollView { content(info).padding(20) }
            } else if let error {
                ContentUnavailableView("Couldn't load this card", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560, height: 600)
        .task {
            do { info = try await library.engine?.cardInfo(cardID) } catch { self.error = error.localizedDescription }
        }
    }

    private func content(_ info: CardInfo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                tile("Reviews", "\(info.reviews)")
                tile("Forgotten", "\(info.lapses)×")
                tile("Interval", info.intervalDays == 0 ? "—" : Self.days(Double(info.intervalDays)))
                if let r = info.retrievability {
                    tile("Chance you'd remember now", "\(Int((r * 100).rounded()))%")
                } else {
                    tile("Ease", info.easePercent == 0 ? "—" : "\(info.easePercent)%")
                }
                tile("Average time", info.reviews == 0 ? "—" : String(format: "%.1fs", info.averageSeconds))
                tile("Total time", info.totalSeconds < 60 ? String(format: "%.0fs", info.totalSeconds)
                                                          : StudyClock.format(Int(info.totalSeconds)))
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Deck", info.deck.replacingOccurrences(of: "\u{1f}", with: " › ").replacingOccurrences(of: "::", with: " › "))
                row("Type", "\(info.noteType) · \(info.cardType)")
                row("Added", Self.date(info.added))
                if let first = info.firstReview { row("First studied", Self.date(first)) }
                if let last = info.latestReview { row("Last studied", Self.date(last)) }
                if let due = info.dueDate {
                    row("Next due", Self.date(due))
                } else if let position = info.duePosition {
                    row("Position", "New card #\(position)")
                }
                if let s = info.stabilityDays { row("Memory strength", "Lasts about \(Self.days(Double(s)))") }
                if let d = info.difficulty { row("Difficulty", String(format: "%.1f out of 10", d)) }
            }
            .font(.callout)

            if !info.history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("History").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow {
                            Text("Date"); Text("Type"); Text("Answer"); Text("Next in"); Text("Time")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        ForEach(info.history) { review in
                            GridRow {
                                Text(Date(timeIntervalSince1970: TimeInterval(review.time))
                                    .formatted(date: .abbreviated, time: .shortened))
                                Text(Self.kind(review.kind))
                                answer(review.button)
                                Text(review.intervalDays <= 0 ? "—" : Self.days(review.intervalDays))
                                Text(String(format: "%.0fs", review.seconds))
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder private func answer(_ button: Int) -> some View {
        if let rating = Rating(rawValue: UInt8(clamping: button)), button > 0 {
            Text(rating.title).foregroundStyle(Palette.grade(rating))
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    static func kind(_ kind: String) -> String {
        switch kind {
        case "learn": "Learning"
        case "review": "Review"
        case "relearn": "Relearning"
        case "filtered": "Filtered"
        case "manual": "Changed by hand"
        case "rescheduled": "Rescheduled"
        default: kind.capitalized
        }
    }

    static func date(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .omitted)
    }

    static func days(_ d: Double) -> String {
        if d < 1 { return "\(max(1, Int((d * 24 * 60).rounded()))) min" }
        if d < 31 { return "\(Int(d.rounded())) day\(Int(d.rounded()) == 1 ? "" : "s")" }
        if d < 365 { return String(format: "%.1f months", d / 30.4) }
        return String(format: "%.1f years", d / 365)
    }
}
