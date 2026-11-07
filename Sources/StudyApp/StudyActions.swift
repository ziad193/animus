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

/// The card's tools in one place: a "Card" button in the study screen's top
/// corner that opens a tidy panel (edit, flag, mark, bury, suspend, info, and
/// the rarer ones at the bottom). Every tool keeps its keyboard key.
struct CardMenuButton: View {
    let session: StudySession
    let card: StudyCard
    @State private var open = false
    @State private var explainPlus = false

    var body: some View {
        Button { open.toggle() } label: {
            Label("Card", systemImage: "ellipsis.circle")
                // A flagged or marked card shows it here, so it isn't lost.
                .overlay(alignment: .topLeading) { statusDot.offset(x: 10, y: -3) }
        }
        .buttonStyle(.hoverable)
        .tip("Edit, flag, bury and more for this card")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            CardMenu(session: session, card: card, close: { open = false }, explainPlus: $explainPlus)
        }
        .sheet(isPresented: $explainPlus) { PlusInfoSheet(highlight: .askAnimus) }
    }

    @ViewBuilder private var statusDot: some View {
        if let flag = FlagColor.of(card.flag) {
            Circle().fill(flag.color).frame(width: 7, height: 7)
        } else if card.marked {
            Circle().fill(Color.yellow).frame(width: 7, height: 7)
        }
    }
}

private struct CardMenu: View {
    let session: StudySession
    let card: StudyCard
    let close: () -> Void
    @State private var plus = PlusStore.shared
    @Binding var explainPlus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("This card")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            row("Edit", "pencil", .blue, key: "E") { session.editing = card.id }
            row(card.marked ? "Unmark" : "Mark", card.marked ? "star.fill" : "star", .yellow, key: "*") {
                Task { await session.toggleMark() }
            }
            row("Bury until tomorrow", "moon.zzz", .indigo, key: "−") { Task { await session.bury() } }
            row("Suspend", "pause.circle", .orange, key: "@") { Task { await session.suspend() } }
            row("Card info", "info.circle", .teal, key: "I") { session.info = card.id }
            row(session.voice.isRecording ? "Stop recording" : "Record your voice", "mic", .red, key: "⇧V") {
                Task { await session.toggleVoiceRecording() }
            }
            if session.voice.hasRecording {
                row("Play your recording", "play.circle", .blue, key: "V") { session.replayVoice() }
            }
            if session.hasAutoAdvance {
                row(session.autoAdvancePaused ? "Resume auto advance" : "Pause auto advance",
                    session.autoAdvancePaused ? "forward.end" : "pause", .accentColor, key: "⇧A") {
                    session.toggleAutoAdvance()
                }
            }
            // Animus+ (Animus Dev only until the AI is connected).
            if plus.showsPreviews && plus.showsPrompts {
                MenuRow(title: "Ask Animus", symbol: PlusFeature.askAnimus.symbol, color: .purple, key: nil,
                        badge: true) {
                    close()
                    if plus.isUnlocked(.askAnimus) { session.askingAnimus = true } else { explainPlus = true }
                }
                MenuRow(title: "Fix my card", symbol: PlusFeature.fixCard.symbol, color: .purple, key: nil,
                        badge: true) {
                    close()
                    if plus.isUnlocked(.fixCard) { session.fixingCard = card.id } else { explainPlus = true }
                }
            }

            Divider().padding(.vertical, 6)

            // Flags: one tap on a colour; tap it again to take the flag off.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Flag").font(.subheadline.weight(.medium))
                    Spacer()
                    KeyCap("⌘1–7")
                }
                HStack(spacing: 8) {
                    ForEach(FlagColor.all) { flag in
                        let on = card.flag == flag.number
                        Button {
                            Task { await session.setFlag(flag.number) }
                            close()
                        } label: {
                            Circle()
                                .fill(flag.color)
                                .frame(width: 22, height: 22)
                                .overlay(Image(systemName: "checkmark").font(.caption2.weight(.bold))
                                    .foregroundStyle(.white).opacity(on ? 1 : 0))
                                .overlay(Circle().strokeBorder(.white.opacity(on ? 0.9 : 0), lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .hoverLift(scale: 1.12)
                        .tip(on ? "Remove the \(flag.name.lowercased()) flag" : "\(flag.name) flag")
                    }
                }
            }
            .padding(.horizontal, 10)

            Divider().padding(.vertical, 6)

            row("Set due date…", "calendar", .secondary, key: nil) { session.settingDue = card.id }
            row("Reset to new", "arrow.counterclockwise", .secondary, key: nil) { Task { await session.forget() } }
            row("Delete note…", "trash", .red, key: "⌘⌫", destructive: true) { session.confirmingDelete = true }
        }
        .padding(10)
        .frame(width: 290)
    }

    private func row(_ title: String, _ symbol: String, _ color: Color, key: String?,
                     destructive: Bool = false, action: @escaping () -> Void) -> some View {
        MenuRow(title: title, symbol: symbol, color: color, key: key, destructive: destructive) {
            close()
            action()
        }
    }
}

/// One line of the card menu: a coloured icon, the action, and its key.
private struct MenuRow: View {
    let title: String
    let symbol: String
    let color: Color
    let key: String?
    var destructive = false
    /// Shows the PLUS badge (an Animus+ feature).
    var badge = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15)))
                Text(title)
                    .foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                if badge { PlusBadge() }
                Spacer()
                if let key { KeyCap(key) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small keyboard-key label, e.g. "E" or "⌘⌫".
private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.4)))
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
            .sheet(item: Binding(get: { session.fixingCard.map(CardRef.init) }, set: { session.fixingCard = $0?.id })) { ref in
                FixCardSheet(cardID: ref.id) { Task { await session.refreshAfterEdit() } }
            }
            .sheet(isPresented: $session.askingAnimus) {
                if let card = session.card {
                    AskAnimusSheet(context: AskContext(card: card, deck: nil))
                }
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
