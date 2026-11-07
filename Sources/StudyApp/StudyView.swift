import AppKit
import AVFoundation
import SwiftUI
import StudyCore

/// One study session: show the question, reveal the answer, grade it, repeat.
///
/// Keys: Space or Return shows the answer (then means Good),
/// 1–4 grade (Again, Hard, Good, Easy), ⌘Z undoes, Esc leaves.
struct StudyView: View {
    @Environment(Library.self) private var library
    let deck: Deck
    let onExit: () -> Void

    @State private var session = StudySession()
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Pref.cardTextSize) private var textSize = CardTextSize.normal
    @AppStorage(Pref.cardStyle) private var cardStyle = CardStyle.app
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    @AppStorage("showReference") private var showReference = false
    @Environment(Pomodoro.self) private var pomodoro
    @Environment(StudyClock.self) private var clock
    @Environment(SyncManager.self) private var sync
    /// Minutes of study after which the next "time check" nudge shows.
    @State private var nudgeAt = 0
    @State private var showNudge = false

    private var decks: [Deck] {
        if case .ready(let decks) = library.state { return decks }
        return []
    }

    var body: some View {
        HSplitView {
            studyColumn
                .overlay { BreakOverlay() }
                .animation(.easeInOut(duration: 0.3), value: pomodoro.phase.isBreak && pomodoro.isRunning)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            if showReference {
                ReferencePanel(deckID: deck.id) {
                    withAnimation { showReference = false }
                }
                .frame(minWidth: 300, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            AppDefaults.current.set(Int(deck.id), forKey: Pref.lastStudiedDeck)
            session.onExit = onExit
            if let engine = library.engine {
                await session.start(engine: engine, deckID: deck.id, media: Library.mediaFolder)
            }
        }
        .onAppear {
            session.installKeys()
            clock.start()
            sync.studying = true
        }
        .onChange(of: pomodoro.phase.isBreak && pomodoro.isRunning, initial: true) { _, onBreak in
            session.onBreak = onBreak
            clock.onBreak = onBreak
        }
        // Each reveal or grade counts as "still studying" for the timer.
        .onChange(of: session.showingAnswer) { clock.activity() }
        .onChange(of: session.reviewed) { clock.activity() }
        // The study time limit from Preferences: a gentle nudge, not a stop.
        .onChange(of: clock.sessionSeconds) { _, seconds in
            let limit = library.preferences?.timeLimitMinutes ?? 0
            guard limit > 0 else { return }
            if nudgeAt == 0 { nudgeAt = limit }
            if seconds >= nudgeAt * 60, !showNudge { withAnimation { showNudge = true } }
        }
        .overlay(alignment: .top) {
            if showNudge {
                HStack(spacing: 12) {
                    Image(systemName: "clock.badge.checkmark").font(.title3).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(nudgeAt) minutes studied").font(.headline)
                        Text("\(session.reviewed) cards so far. Keep going, or take a break?")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Take a Break") { onExit() }
                    Button("Keep Going") {
                        nudgeAt += library.preferences?.timeLimitMinutes ?? 0
                        withAnimation { showNudge = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                }
                .padding(14)
                .frame(maxWidth: 560)
                .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .padding(.top, 54)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .studyActionSheets(session: session, decks: decks)
        .overlay(alignment: .top) {
            if let toast = session.toast {
                NoticeBubble(notice: toast)
                    .id(toast.id)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .top)))
                    .allowsHitTesting(false)
            }
        }
        .onDisappear {
            clock.stop()
            // Leaving the study screen syncs (if automatic sync is on).
            sync.studying = false
            session.removeKeys()
            let finishedFiltered = deck.filtered && session.finished
            Task {
                // A finished filtered deck has done its job: remove it, which
                // sends any cards still in it back to their own decks.
                if finishedFiltered, let engine = library.engine {
                    try? await engine.deleteDeck(deck.id)
                    library.notice = "You finished “\(deck.shortName)”. Its cards are back in their own decks."
                }
                await library.refresh()
            }
        }
        // Keep Edit › Undo's name current ("Undo Answer Card"), and reload if it was used.
        .onChange(of: session.card?.id) { Task { await library.refreshUndo() } }
        .onChange(of: library.undoGeneration) { Task { await session.reloadAfterMenuUndo() } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await session.undo() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .tip("Undo last grade (⌘Z)")
                .buttonStyle(.automatic)
                .disabled(!session.canUndo)

                Toggle(isOn: $showReference.animation()) {
                    Label("Slides & Notes", systemImage: "sidebar.right")
                }
                .tip("Show a PDF or PowerPoint beside your cards")
            }
        }
    }

    private var studyColumn: some View {
        VStack(spacing: 0) {
            // The buttons sit straight on the picture: no strip behind them.
            header
                .bannerShadow()
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // The card uses the window, apart from a slim margin, so long cards
            // don't need to scroll.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)

            if session.card != nil {
                controls
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The background picture, blurred so the card stays the focus.
        .pageBackground(blur: 28, plain: .background.secondary)
        // Answering makes the card flash in that answer's colour, then fade.
        .onChange(of: session.answerPulse) { _, pulse in
            guard let pulse else { return }
            withAnimation(.easeOut(duration: 0.12)) { flash = pulse.rating }
            Task {
                // Holds through the short pause on the rated card, then fades on the next.
                try? await Task.sleep(for: .milliseconds(Int(StudySession.ratedPause * 1000) + 250))
                guard session.answerPulse == pulse else { return }
                withAnimation(.easeOut(duration: 0.7)) { flash = nil }
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.previewRating)
    }

    /// The answer just given (bright), or the grade button under the pointer (soft).
    @State private var flash: Rating?
    @AppStorage(Pref.studyGlow) private var studyGlow = true
    private var glowColor: Color? {
        guard studyGlow else { return nil }
        if let flash { return Palette.grade(flash) }
        if session.showingAnswer, let preview = session.previewRating { return Palette.grade(preview) }
        return nil
    }

    @AppStorage(Pref.studyShowDecks) private var studyShowDecks = false
    @AppStorage(Pref.studyShowTabs) private var studyShowTabs = true

    private var header: some View {
        // The counts sit dead centre, whatever is on either side of them.
        ZStack {
            HStack {
                leftButtons
                Spacer()
                // The card's tools, tucked into one menu in the corner.
                if let card = session.card {
                    CardMenuButton(session: session, card: card)
                }
            }
            if library.preferences?.showRemainingDueCounts ?? true {
                CountsBar(counts: session.counts)
            }
        }
    }

    private var leftButtons: some View {
        HStack {
            Button(action: onExit) {
                Label("Done", systemImage: "chevron.left")
            }
            .buttonStyle(.hoverable)
            .tip("Stop studying (Esc)")

            Button {
                studyShowDecks.toggle()
            } label: {
                Label(studyShowDecks ? "Hide Decks" : "Show Decks", systemImage: "sidebar.left")
            }
            .buttonStyle(.hoverable)
            .tip(studyShowDecks ? "Hide the deck list" : "Show your decks down the side")

            Button {
                studyShowTabs.toggle()
            } label: {
                Label(studyShowTabs ? "Hide Tabs" : "Show Tabs", systemImage: "menubar.rectangle")
            }
            .buttonStyle(.hoverable)
            .tip(studyShowTabs ? "Hide the tabs along the top" : "Show the tabs along the top")
        }
    }

    @ViewBuilder private var content: some View {
        if let error = session.error {
            ContentUnavailableView {
                Label("Couldn't load this card", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if let card = session.card {
            Group {
                if let occlusion = session.occlusion {
                    OcclusionCardView(card: occlusion, showingAnswer: session.showingAnswer, accent: accent.color)
                } else {
                    CardWebView(payload: CardPayload(
                                    cardID: card.id,
                                    side: session.showingAnswer ? .answer : .question,
                                    html: session.showingAnswer ? card.answer : card.question,
                                    css: card.css,
                                    // While the question shows, fetch this card's answer pictures
                                    // too, so the answer appears straight away.
                                    upcoming: session.showingAnswer ? card.upcoming
                                        : card.answer + (card.upcoming ?? ""),
                                    dark: colorScheme == .dark,
                                    zoom: textSize.zoom,
                                    appStyle: cardStyle == .app,
                                    accentHex: accent.hex),
                                mediaFolder: Library.mediaFolder) { side, index in
                        session.playAudio(side: side, index: index)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(CardPane(glow: glowColor, strength: flash != nil ? 1 : 0.5))
            .padding(.vertical, 4)
        } else if session.finished {
            ContentUnavailableView {
                Label("All done for now", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } description: {
                Text(session.reviewed > 0
                     ? "You studied \(session.reviewed) cards. Come back later for the next ones."
                     : "Nothing is due in this deck right now.")
            } actions: {
                VStack(spacing: 14) {
                    Button("Back", action: onExit)
                        .keyboardShortcut(.defaultAction)
                    StudyMoreOffer(deck: deck) {
                        Task { await session.restart() }
                    }
                }
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private var controls: some View {
        if session.showingAnswer, let card = session.card {
            HStack(spacing: 12) {
                ForEach(Rating.allCases) { rating in
                    GradeButton(rating: rating,
                                interval: (library.preferences?.showIntervalsOnButtons ?? true)
                                    ? card.intervals[safe: Int(rating.rawValue) - 1] ?? "" : "",
                                onHover: { inside in
                                    if inside { session.previewRating = rating }
                                    else if session.previewRating == rating { session.previewRating = nil }
                                }) {
                        Task { await session.grade(rating) }
                    }
                }
            }
            .frame(maxWidth: 620)
        } else {
            Button {
                session.revealAnswer()
            } label: {
                HStack {
                    Text("Show Answer").font(.headline)
                    KeyHint("Space")
                }
                .frame(width: 280)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .hoverGlow()
            .controlSize(.large)
        }
    }
}

// MARK: - Session logic

@MainActor
@Observable
final class StudySession {
    /// How long the rated card stays on screen, glowing, before the next one.
    static let ratedPause = 0.175

    private(set) var card: StudyCard?
    /// Set when the card is an image occlusion card we draw natively.
    private(set) var occlusion: OcclusionCard?
    private(set) var counts: StudyState.Counts?
    private(set) var showingAnswer = false
    private(set) var finished = false
    private(set) var canUndo = false
    private(set) var error: String?
    private(set) var reviewed = 0
    /// Bumped on every answer, so the card can glow in that answer's colour.
    private(set) var answerPulse: AnswerPulse?
    /// The grade button under the pointer, for a softer preview glow.
    var previewRating: Rating?
    /// A short message after an action, e.g. "Buried until tomorrow".
    private(set) var toast: StudyNotice?
    /// Sheets the study screen shows.
    var editing: Int64?
    var info: Int64?
    var settingDue: Int64?
    var confirmingDelete = false
    var onExit: (() -> Void)?
    /// What ⌘Z will undo: a grade, or a card action (which doesn't change the count).
    private var undoIsGrade = true
    private var toastTask: Task<Void, Never>?
    /// True during a Pomodoro break: study keys are ignored.
    var onBreak = false

    private var engine: Engine?
    private var media: URL?
    private var shownAt = Date()
    private var busy = false
    private var keyMonitor: Any?
    private let player = AVQueuePlayer()

    private var deckID: Int64?

    func start(engine: Engine, deckID: Int64, media: URL) async {
        self.engine = engine
        self.media = media
        self.deckID = deckID
        do {
            try await engine.selectDeck(deckID)
        } catch {
            self.error = error.localizedDescription
            return
        }
        await loadNext()
    }

    /// Starts again after today's limits were raised.
    func restart() async {
        guard let engine, let media, let deckID else { return }
        finished = false
        await start(engine: engine, deckID: deckID, media: media)
    }

    func revealAnswer() {
        guard card != nil, !showingAnswer else { return }
        showingAnswer = true
        autoplay(side: "a")
    }

    func grade(_ rating: Rating) async {
        guard let engine, card != nil, showingAnswer, !busy else { return }
        answerPulse = AnswerPulse(rating: rating, id: (answerPulse?.id ?? 0) + 1)
        previewRating = nil
        busy = true
        defer { busy = false }
        let ms = UInt32(min(Date().timeIntervalSince(shownAt) * 1000, 60_000))
        let cardID = card?.id ?? 0
        // A moment on the card you just rated, glowing in its colour, so it's
        // clear which card the colour belongs to before the next one appears.
        // (After the answer time is taken, so the pause isn't counted in it.)
        try? await Task.sleep(for: .seconds(Self.ratedPause))
        // Forgetting a card too often makes it a "leech"; say so, so it can be fixed.
        let wasLeech = rating == .again ? ((try? await engine.leechState(cardID))?.leech ?? true) : true
        do {
            try await engine.answer(rating, milliseconds: ms)
            if !wasLeech, let state = try? await engine.leechState(cardID), state.leech {
                show(StudyNotice(symbol: "exclamationmark.triangle.fill", color: .orange,
                                 title: state.suspended ? "Tagged “leech” and paused" : "Tagged “leech”",
                                 detail: "You've forgotten this card \(state.lapses) times. Try rewording it or splitting it up (find it in Browse)."),
                     seconds: 7)
            }
            canUndo = true
            undoIsGrade = true
            withAnimation { reviewed += 1 }
        } catch {
            self.error = error.localizedDescription
            return
        }
        await loadNext()
    }

    /// Undo goes back one step at a time, as far as Anki's engine allows
    /// (30 steps, the same as Anki), not just the last thing you did.
    func undo() async {
        guard let engine, canUndo, !busy else { return }
        busy = true
        defer { busy = false }
        // What's being undone: an answer takes one off "cards studied".
        let step = (try? await engine.undoStatus())?.undo
        let wasAnswer = step == "Answer Card" || (step == nil && undoIsGrade)
        do {
            try await engine.undo()
        } catch {
            await refreshUndo()
            return
        }
        if wasAnswer { withAnimation { reviewed = max(0, reviewed - 1) } }
        show(StudyNotice(symbol: "arrow.uturn.backward", color: .accentColor,
                         title: wasAnswer ? "Went back a card" : "Undone",
                         detail: wasAnswer ? "Your last answer was taken back." : step.map { "Undid “\($0)”." }))
        await loadNext()
        await refreshUndo()
    }

    /// Whether there's still something to undo, asked of the engine itself.
    private func refreshUndo() async {
        guard let engine else { canUndo = false; return }
        canUndo = (try? await engine.undoStatus())?.undo != nil
    }

    // MARK: Card actions

    /// Runs a change to the current card, then shows the next one (or the same one, refreshed).
    private func act(_ notice: StudyNotice, next: Bool = true, _ work: (Engine, Int64) async throws -> Void) async {
        guard let engine, let id = card?.id, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await work(engine, id)
            canUndo = true
            undoIsGrade = false
            show(notice)
        } catch {
            show(StudyNotice(symbol: "xmark.octagon.fill", color: .red, title: "That didn't work",
                             detail: error.localizedDescription), seconds: 5)
            return
        }
        await loadNext(keepAnswer: !next)
    }

    func setFlag(_ flag: Int) async {
        let new = card?.flag == flag ? 0 : flag
        let notice = new == 0
            ? StudyNotice(symbol: "flag.slash", color: .secondary, title: "Flag removed", detail: nil)
            : StudyNotice(symbol: "flag.fill", color: FlagColor.all[new - 1].color,
                          title: "Flagged \(FlagColor.all[new - 1].name.lowercased())",
                          detail: "Find flagged cards in Browse › Flagged.")
        await act(notice, next: false) {
            try await $0.setFlag([$1], new)
        }
    }

    func toggleMark() async {
        let marking = !(card?.marked ?? false)
        let notice = marking
            ? StudyNotice(symbol: "star.fill", color: .yellow, title: "Marked", detail: "Tagged “marked” so you can come back to it.")
            : StudyNotice(symbol: "star.slash", color: .secondary, title: "Unmarked", detail: nil)
        await act(notice, next: false) { engine, id in
            let note = try await engine.note(forCard: id)
            var tags = note.tags.filter { $0.caseInsensitiveCompare("marked") != .orderedSame }
            if marking { tags.append("marked") }
            try await engine.updateNote(note.noteID, fields: note.fields, tags: tags)
        }
    }

    func bury() async {
        await act(StudyNotice(symbol: "moon.zzz.fill", color: .indigo, title: "Buried until tomorrow",
                              detail: "It'll come back with tomorrow's cards.")) { try await $0.bury([$1]) }
    }

    func suspend() async {
        await act(StudyNotice(symbol: "pause.circle.fill", color: .orange, title: "Suspended",
                              detail: "Find it in Browse › Suspended to bring it back.")) { try await $0.setSuspended([$1], true) }
    }

    func setDue(_ days: String) async {
        await act(StudyNotice(symbol: "calendar", color: .teal, title: "Rescheduled",
                              detail: "It'll come back on the new date.")) { try await $0.setDueDate([$1], days: days) }
    }

    func forget() async {
        await act(StudyNotice(symbol: "arrow.counterclockwise", color: .blue, title: "Reset to new",
                              detail: "It'll be shown again as a new card.")) { try await $0.forget([$1]) }
    }

    func deleteNote() async {
        await act(StudyNotice(symbol: "trash.fill", color: .red, title: "Note deleted",
                              detail: "Changed your mind? Press ⌘Z to bring it back.")) { try await $0.deleteNotes(ofCards: [$1]) }
    }

    /// After editing: show the card again with the new text.
    func refreshAfterEdit() async {
        await loadNext(keepAnswer: true)
    }

    private func show(_ notice: StudyNotice?, seconds: Double = 2.5) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = notice }
        guard notice != nil else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { self?.toast = nil }
        }
    }

    /// After Edit › Undo or Redo changed things behind the study screen.
    func reloadAfterMenuUndo() async {
        await loadNext()
        await refreshUndo()
    }

    private func loadNext(keepAnswer: Bool = false) async {
        guard let engine else { return }
        let previous = card?.id
        player.removeAllItems()
        do {
            let state = try await engine.nextCard()
            counts = state.counts
            if let media, let fields = state.card?.occlusion {
                occlusion = OcclusionCard(fields, media: media)
            } else {
                occlusion = nil
            }
            card = state.card
            finished = state.card == nil
            let same = keepAnswer && state.card?.id == previous
            if !same {
                showingAnswer = false
                shownAt = Date()
                autoplay(side: "q")
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Audio

    func playAudio(side: String, index: Int) {
        guard let file = audioFiles(side: side)[safe: index] else { return }
        play([file])
    }

    private func autoplay(side: String) {
        let files = audioFiles(side: side)
        if !files.isEmpty { play(files) }
    }

    private func audioFiles(side: String) -> [String] {
        guard let card else { return [] }
        return side == "q" ? card.questionAudio : card.answerAudio
    }

    private func play(_ files: [String]) {
        guard let media else { return }
        player.removeAllItems()
        for file in files {
            player.insert(AVPlayerItem(url: media.appendingPathComponent(file)), after: nil)
        }
        player.play()
    }

    // MARK: Keyboard

    func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        player.removeAllItems()
    }

    /// Returns true if the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        // Leave typing alone (e.g. the search box in the slides panel).
        if event.window?.firstResponder is NSText { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "z" {
            Task { await undo() }
            return true
        }
        if event.keyCode == 53, mods.isEmpty { // Esc
            onExit?()
            return true
        }
        guard card != nil, !onBreak, editing == nil, info == nil, settingDue == nil, !confirmingDelete else { return false }
        // ⌘1–7 flag the card (⌘0 removes it), as in Anki.
        if mods == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (0...7).contains(digit) {
            Task { await setFlag(digit == 0 ? (card?.flag ?? 0) : digit) }
            return true
        }
        if mods == .command, event.keyCode == 51 { // ⌘⌫
            confirmingDelete = true
            return true
        }
        let plain = mods.subtracting([.numericPad, .function, .shift]).isEmpty
        if plain {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "e": editing = card?.id; return true
            case "i": info = card?.id; return true
            case "*": Task { await toggleMark() }; return true
            case "-": Task { await bury() }; return true
            case "@": Task { await suspend() }; return true
            default: break
            }
            switch event.characters {
            case "*": Task { await toggleMark() }; return true
            case "@": Task { await suspend() }; return true
            default: break
            }
        }
        guard mods.subtracting([.numericPad, .function]).isEmpty else { return false }
        switch event.charactersIgnoringModifiers {
        case " ", "\r":
            if showingAnswer {
                Task { await grade(.good) }
            } else {
                revealAnswer()
            }
            return true
        case "1", "2", "3", "4":
            guard showingAnswer,
                  let digit = event.charactersIgnoringModifiers.flatMap(UInt8.init),
                  let rating = Rating(rawValue: digit) else { return false }
            Task { await grade(rating) }
            return true
        default:
            return false
        }
    }
}

// MARK: - Small views

struct CountsBar: View {
    let counts: StudyState.Counts?

    var body: some View {
        HStack(spacing: 18) {
            item(counts?.new, "New", Palette.new)
            item(counts?.learn, "Learning", Palette.learning)
            item(counts?.review, "Due", Palette.review)
        }
        .font(.callout.monospacedDigit())
    }

    private func item(_ value: Int?, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(value.map(String.init) ?? "–").bold()
                .contentTransition(.numericText())
            Text(label).foregroundStyle(.secondary)
        }
    }
}

struct GradeButton: View {
    let rating: Rating
    let interval: String
    var onHover: (Bool) -> Void = { _ in }
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = Palette.grade(rating)
        Button(action: action) {
            VStack(spacing: 3) {
                Text(rating.title)
                    .font(.headline)
                    .foregroundStyle(color)
                if !interval.isEmpty {
                    Text(interval)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(hovering ? 0.22 : 0.12)))
            .overlay(alignment: .topTrailing) {
                KeyHint("\(rating.rawValue)").padding(6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; onHover($0) }
        .tip(interval.isEmpty ? "\(rating.title) (\(rating.rawValue))" : "\(rating.title): see this again in \(interval) (\(rating.rawValue))")
    }
}

/// A small keycap showing which key does the same thing.
struct KeyHint: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The box behind the card: solid normally, and thick frosted glass (like a
/// window pane) over a background picture, so the picture still shows through.
private struct CardPane: View {
    /// The colour to glow in: the answer you gave, or the one you're hovering.
    var glow: Color?
    /// 1 for the flash after answering, about half for the hover preview.
    var strength: Double = 1
    @Environment(\.onPicture) private var onPicture

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        shape
            .fill(onPicture ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.background))
            .overlay(shape.strokeBorder(.white.opacity(onPicture ? 0.18 : 0)))
            .shadow(color: .black.opacity(onPicture ? 0.28 : 0.08), radius: onPicture ? 24 : 12, y: 6)
            // The glow sits behind the pane: a coloured halo spilling out
            // around its edges, while the glass itself stays clear.
            .background {
                shape
                    .fill(glow ?? .clear)
                    .padding(-4)
                    .blur(radius: 26)
                    .opacity(glow == nil ? 0 : 0.9 * strength)
                    // Cut out where the pane is, so the frosted glass (which is
                    // see-through) isn't tinted: the colour only shows outside it.
                    .mask {
                        Rectangle()
                            .padding(-120)
                            .overlay(shape.blendMode(.destinationOut))
                            .compositingGroup()
                    }
            }
    }
}

/// One answer, so the study screen can flash in its colour.
struct AnswerPulse: Equatable {
    let rating: Rating
    let id: Int
}

/// What a study action just did, shown briefly as a notification bubble.
struct StudyNotice: Equatable {
    let id = UUID()
    let symbol: String
    let color: Color
    let title: String
    let detail: String?
}

/// A notification-style bubble: a coloured icon, what happened, and a short
/// line saying what it means. Slides down from the top, then goes by itself.
private struct NoticeBubble: View {
    let notice: StudyNotice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(notice.color.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: 460, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}
