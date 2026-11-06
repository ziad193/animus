import SwiftUI
import StudyCore

/// Every card in one searchable table, with the selected card's editor
/// and preview beside it. Filters and actions are buttons in plain view.
struct BrowsePage: View {
    @Environment(Library.self) private var library
    @Environment(BrowseModel.self) private var model
    let decks: [Deck]

    @State private var confirmDelete = false
    @State private var showMove = false
    @State private var showTips = false
    @State private var sheet: BrowseSheet?
    @State private var confirmForget = false
    @AppStorage("browse.showReference") private var showReference = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            filterBar
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    statusBar
                    table
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                detail
                    .frame(minWidth: 300, idealWidth: 420, maxWidth: 620, maxHeight: .infinity)
                // Slides & Notes, for checking cards against your lecture slides.
                if showReference {
                    ReferencePanel(deckID: model.deckID ?? 0) { withAnimation { showReference = false } }
                        .frame(minWidth: 300, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Browse")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showReference.animation()) {
                    Label("Slides & Notes", systemImage: "sidebar.right")
                }
                .help("Show a PDF, PowerPoint or Word file beside your cards")
            }
        }
        .task(id: searchKey) {
            // A short pause so typing doesn't search on every letter.
            model.markPending()
            if !model.query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled, let engine = library.engine else { return }
            await model.search(engine: engine, decks: decks)
        }
        .sheet(item: $sheet) { which in
            BrowseToolSheet(which: which, cards: model.selectedIDs, scope: model.searchText(decks: decks),
                            notesMode: model.notesMode) { title, reloadAll in
                Task { await finished(title, reloadAll: reloadAll) }
            } show: { query in
                model.filter = .all
                model.deckID = nil
                model.query = query
            }
        }
        .confirmationDialog("Reset \(model.selection.count == 1 ? "this card" : "\(model.selection.count) cards") to new?",
                            isPresented: $confirmForget) {
            Button("Reset to New", role: .destructive) {
                Task { await run("Reset") { try await $0.forget($1) } }
            }
        } message: {
            Text("They'll be studied again from scratch, as if you'd never seen them. Their review history is kept.")
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Every card made from these notes goes too. You can undo this straight after.")
        }
    }

    /// Changes to any of these run the search again.
    private var searchKey: String {
        "\(model.baseSearch)|\(model.query)|\(model.filter.rawValue)|\(model.flagColor)|\(model.notesMode)|\(model.deckID ?? 0)|\(model.sortOrder.first.map { "\($0.keyPath.hashValue)\($0.order == .reverse)" } ?? "")|\(decks.count)"
    }

    // MARK: Top bar

    /// Filter buttons, deck and search tips on one row when there's room;
    /// in a narrow window the deck and tips move to a second row so the
    /// filters are never squeezed out.
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filterChips.fixedSize()
                Spacer(minLength: 8)
                deckAndTips
            }
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) { filterChips }
                HStack(spacing: 12) {
                    deckAndTips
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(BrowseFilter.allCases) { filter in
                FilterChip(filter: filter, selected: model.filter == filter) {
                    model.filter = filter
                }
            }
            // With Flagged picked: narrow to one colour.
            if model.filter == .flagged {
                HStack(spacing: 3) {
                    flagDot(0, .secondary, "Any flag")
                    ForEach(FlagColor.all) { flag in flagDot(flag.number, flag.color, flag.name) }
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.filter)
    }

    private func flagDot(_ number: Int, _ color: Color, _ name: String) -> some View {
        Button {
            model.flagColor = number
        } label: {
            Image(systemName: number == 0 ? "flag.2.crossed" : "flag.fill")
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(model.flagColor == number ? 0.12 : 0)))
                .overlay(Circle().strokeBorder(model.flagColor == number ? color : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.hoverable)
        .help(name)
    }

    private var deckAndTips: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Picker("Show", selection: $model.notesMode) {
                Text("Cards").tag(false)
                Text("Notes").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Cards: one row per card. Notes: one row per note (a note can make several cards, e.g. Both Ways or fill-in-the-blank).")
            Button {
                sheet = .duplicates
            } label: {
                Label("Duplicates", systemImage: "square.on.square")
            }
            .help("Find notes with the same front, in what's shown now")
            Text("In").foregroundStyle(.secondary)
            DeckPickerButton(decks: decks, selection: $model.deckID, emptyTitle: "All decks", allowsAll: true)
                .frame(width: 260)
            Button {
                showTips.toggle()
            } label: {
                Label("Search tips", systemImage: "questionmark.circle")
            }
            .popover(isPresented: $showTips, arrowEdge: .bottom) { SearchTips() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text(countText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if model.searching { ProgressView().controlSize(.small) }
            }
            Spacer()
            if let undo = model.undoTitle {
                Button {
                    Task { await undoLast() }
                } label: {
                    Label("Undo \(undo)", systemImage: "arrow.uturn.backward")
                }
            }
            if !model.selection.isEmpty {
                // Words when there's room, icons (with hover notes) when the table is narrow.
                ViewThatFits(in: .horizontal) {
                    actionButtons.labelStyle(.titleAndIcon)
                    actionButtons.labelStyle(.iconOnly)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 40)
    }

    private var countText: String {
        let total = model.cards.count
        let base = total == 1 ? "1 card" : "\(total.formatted()) cards"
        let picked = model.selection.count
        return picked > 1 ? "\(base) · \(picked) selected" : base
    }

    /// Suspend, move and delete, for whatever is selected.
    private var actionButtons: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(FlagColor.all) { flag in
                    Button { Task { await setFlag(flag.number) } } label: { Label(flag.name, systemImage: "flag.fill") }
                        .keyboardShortcut(KeyEquivalent(Character("\(flag.number)")), modifiers: .command)
                }
                Divider()
                Button("Remove Flag") { Task { await setFlag(0) } }
            } label: {
                Label("Flag", systemImage: "flag")
            }
            .fixedSize()
            .help("Flag with a colour (⌘1–7)")
            Menu {
                Button("Add Tags…") { sheet = .addTags }
                Button("Remove Tags…") { sheet = .removeTags }
            } label: {
                Label("Tags", systemImage: "tag")
            }
            .fixedSize()
            .help("Add or remove tags on the selected notes")
            Button {
                Task { await toggleSuspend() }
            } label: {
                Label(model.allSelectedSuspended ? "Unsuspend" : "Suspend",
                      systemImage: model.allSelectedSuspended ? "play.circle" : "pause.circle")
            }
            .help(model.allSelectedSuspended ? "Bring these cards back into your reviews" : "Keep these cards out of your reviews for now")
            Button {
                showMove.toggle()
            } label: {
                Label("Move to…", systemImage: "folder")
            }
            .popover(isPresented: $showMove, arrowEdge: .bottom) {
                DeckChooser(decks: decks, selection: nil, create: createDeck) { id in
                    showMove = false
                    if let id { Task { await move(to: id) } }
                }
            }
            Menu {
                Button { sheet = .setDue } label: { Label("Set Due Date…", systemImage: "calendar") }
                Button { confirmForget = true } label: { Label("Reset to New…", systemImage: "arrow.counterclockwise") }
                Button { sheet = .reposition } label: { Label("Reposition New Cards…", systemImage: "list.number") }
                Divider()
                Button { sheet = .findReplace } label: { Label("Find & Replace…", systemImage: "text.magnifyingglass") }
                Button { sheet = .changeType } label: { Label("Change Card Type…", systemImage: "rectangle.2.swap") }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            .help("Set due date, reset, reposition, find & replace, change card type")
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete the selected notes")
        }
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: Table

    private var table: some View {
        @Bindable var model = model
        return Table(model.cards, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Front", value: \CardRef.front) { ref in
                FrontCell(model: model, engine: library.engine, id: ref.id)
            }
            .width(min: 160, ideal: 280)
            TableColumn("Back") { ref in
                PlainCell(model: model, id: ref.id, column: .back)
            }
            .width(min: 120, ideal: 220)
            TableColumn("Deck", value: \CardRef.deck) { ref in
                PlainCell(model: model, id: ref.id, column: .deck, lastPart: true)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Due", value: \CardRef.due) { ref in
                PlainCell(model: model, id: ref.id, column: .due)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Interval", value: \CardRef.interval) { ref in
                PlainCell(model: model, id: ref.id, column: .interval)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Ease", value: \CardRef.ease) { ref in
                PlainCell(model: model, id: ref.id, column: .ease)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Added", value: \CardRef.added) { ref in
                PlainCell(model: model, id: ref.id, column: .added)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Card type", value: \CardRef.noteType) { ref in
                PlainCell(model: model, id: ref.id, column: .noteType)
            }
            .width(min: 70, ideal: 110)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if !ids.isEmpty {
                Button("Suspend / Unsuspend") { Task { await toggleSuspend() } }
                Button("Move to…") { showMove = true }
                Menu("Flag") {
                    ForEach(FlagColor.all) { flag in
                        Button(flag.name) { Task { await setFlag(flag.number) } }
                    }
                    Divider()
                    Button("Remove Flag") { Task { await setFlag(0) } }
                }
                Button("Add Tags…") { sheet = .addTags }
                Button("Set Due Date…") { sheet = .setDue }
                Button("Find & Replace…") { sheet = .findReplace }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }
        }
        .onDeleteCommand { if !model.selection.isEmpty { confirmDelete = true } }
        .overlay {
            if model.cards.isEmpty, !model.searching, model.error == nil {
                ContentUnavailableView("No cards found",
                                       systemImage: "magnifyingglass",
                                       description: Text(emptyHint))
            }
        }
    }

    private var emptyHint: String {
        if !model.query.isEmpty { return "Try fewer words, or check the spelling." }
        if model.filter != .all { return "Nothing is \(model.filter.title.lowercased()) here." }
        return "Add some cards to see them here."
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        let picked = model.selectedIDs
        if picked.count == 1, let id = picked.first {
            NoteEditorPanel(cardID: id, decks: decks)
                .id(id)
        } else if picked.count > 1 {
            VStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("\(picked.count) cards selected").font(.title2.weight(.semibold))
                Text("Suspend, move or delete them all at once with the buttons above the table.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.secondary)
        } else {
            ContentUnavailableView("Pick a card",
                                   systemImage: "hand.point.up.left",
                                   description: Text("Click a card in the table to see it and edit it here. Hold ⌘ or ⇧ to pick several."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background.secondary)
        }
    }

    // MARK: Actions

    private var deleteTitle: String {
        let notes = Set(model.selection.compactMap { model.rows[$0]?.noteID }).count
        return notes <= 1 ? "Delete this note?" : "Delete \(notes) notes?"
    }

    /// Card-level changes act on every card of the selected notes in Notes view.
    private func targetCards() async -> [Int64] {
        let ids = model.selectedIDs
        guard model.notesMode, let engine = library.engine else { return ids }
        var notes = ids.compactMap { model.rows[$0]?.noteID }
        if notes.count < ids.count {
            notes = ((try? await engine.browseRows(ids)) ?? []).map(\.noteID)
        }
        guard !notes.isEmpty else { return ids }
        return (try? await engine.search("nid:" + notes.map(String.init).joined(separator: ","))) ?? ids
    }

    private func run(_ title: String, _ work: (Engine, [Int64]) async throws -> Void) async {
        guard let engine = library.engine else { return }
        let ids = await targetCards()
        do {
            try await work(engine, ids)
            await finished(title, reloadAll: false)
        } catch {
            library.notice = error.localizedDescription
        }
    }

    /// After a change: offer Undo, refresh what's shown.
    private func finished(_ title: String, reloadAll: Bool) async {
        guard let engine = library.engine else { return }
        model.didChange(title)
        if reloadAll {
            await model.search(engine: engine, decks: decks)
        }
        await model.reload(model.selectedIDs, engine: engine)
        await library.refresh()
    }

    private func setFlag(_ flag: Int) async {
        await run(flag == 0 ? "Remove Flag" : "Flag") { try await $0.setFlag($1, flag) }
    }

    private func toggleSuspend() async {
        guard let engine = library.engine else { return }
        let ids = model.selectedIDs
        let suspend = !model.allSelectedSuspended
        do {
            try await engine.setSuspended(ids, suspend)
            model.didChange(suspend ? "Suspend" : "Unsuspend")
            await model.reload(ids, engine: engine)
            await library.refresh()
        } catch {
            library.notice = error.localizedDescription
        }
    }

    private func move(to deck: Int64) async {
        guard let engine = library.engine else { return }
        let ids = model.selectedIDs
        do {
            try await engine.moveCards(ids, toDeck: deck)
            RecentDecks.use(deck)
            model.didChange("Move")
            await model.reload(ids, engine: engine)
            await library.refresh()
        } catch {
            library.notice = error.localizedDescription
        }
    }

    private func delete() async {
        guard let engine = library.engine else { return }
        let ids = model.selectedIDs
        do {
            try await engine.deleteNotes(ofCards: ids)
            model.didChange("Delete")
            // Deleting a note removes its other cards too, so search again.
            await model.search(engine: engine, decks: decks)
            await library.refresh()
        } catch {
            library.notice = error.localizedDescription
        }
    }

    private func undoLast() async {
        guard let engine = library.engine else { return }
        do {
            try await engine.undo()
            model.clearUndo()
            await model.search(engine: engine, decks: decks)
            await library.refresh()
        } catch {
            library.notice = error.localizedDescription
        }
    }

    private func createDeck(_ name: String) async -> Int64? {
        guard let engine = library.engine else { return nil }
        let id = try? await engine.addDeck(named: name)
        await library.refresh()
        return id
    }
}

// MARK: - Cells

/// The Front column: a coloured dot for the card's state, a flag if any,
/// and the text. Asks for its page of rows when it scrolls into view.
/// Table cells get the model passed in rather than from the environment:
/// SwiftUI can refresh a table's cells while the page is closing, after the
/// environment is gone, which would crash.
private struct FrontCell: View {
    let model: BrowseModel
    let engine: Engine?
    let id: Int64

    var body: some View {
        let row = model.rows[id]
        HStack(spacing: 6) {
            Circle()
                .fill(row.map { StateStyle.color($0.state) } ?? .clear)
                .frame(width: 7, height: 7)
                .help(row.map { StateStyle.title($0.state) } ?? "")
            if let flag = row?.flag, flag > 0 {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(StateStyle.flagColor(flag))
            }
            Text(row.map(Self.frontText) ?? " ")
                .lineLimit(1)
                .foregroundStyle(row?.state == "suspended" ? .secondary : .primary)
        }
        .onAppear {
            if let engine { model.need(id, engine: engine) }
        }
    }

    /// Picture-hiding cards have no text on the front; name the card type instead.
    static func frontText(_ row: BrowseRow) -> String {
        let text = StateStyle.tidy(row.text(.front))
        if text.contains("image-occlusion:") {
            return "🖼 Hidden-picture card (" + row.text(.noteType) + ")"
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return "🖼 " + row.text(.noteType)
        }
        return text
    }
}

private struct PlainCell: View {
    let model: BrowseModel
    let id: Int64
    let column: BrowseColumn
    /// For decks: show "Week 1" rather than the whole path.
    var lastPart = false

    var body: some View {
        let row = model.rows[id]
        let text = row?.text(column) ?? ""
        Text(lastPart ? (text.components(separatedBy: "::").last ?? text) : StateStyle.tidy(text))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .help(lastPart ? text.replacingOccurrences(of: "::", with: " › ") : "")
    }
}

enum StateStyle {
    // swiftlint:disable:next force_try
    private static let mediaFile = try! Regex(#"[^\s"'<>]+\.(?i:png|jpe?g|gif|webp|svg|bmp|tiff?|heic|avif)\b"#)

    /// Table text with picture file names ("paste-1a2b….png") shown as 🖼.
    static func tidy(_ text: String) -> String {
        let replaced = text.replacing(mediaFile) { _ in "🖼" }
        return replaced.trimmingCharacters(in: .whitespaces).isEmpty && !text.isEmpty ? "🖼 Picture" : replaced
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "new": Palette.new
        case "learning": Palette.learning
        case "review": Palette.review
        default: .gray.opacity(0.5)
        }
    }

    static func title(_ state: String) -> String {
        switch state {
        case "new": "New — not studied yet"
        case "learning": "Learning"
        case "review": "In review"
        case "suspended": "Suspended — left out of reviews"
        case "buried": "Buried until tomorrow"
        default: state
        }
    }

    static func flagColor(_ flag: Int) -> Color {
        [Color.red, .orange, .green, .blue, .pink, .teal, .purple][max(0, min(6, flag - 1))]
    }
}

private struct FilterChip: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    let filter: BrowseFilter
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(filter.title, systemImage: filter.symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : .primary)
                .background(Capsule().fill(selected ? AnyShapeStyle(accent.color) : AnyShapeStyle(Color.primary.opacity(0.06))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.03)
    }
}

/// Plain-language examples of what you can type in the search box.
private struct SearchTips: View {
    private let tips: [(String, String)] = [
        ("heart valve", "Cards containing both words, anywhere"),
        ("\"left ventricle\"", "That exact phrase"),
        ("heart -valve", "“heart” but not “valve”"),
        ("heart or lung", "Either word"),
        ("front:*heart*", "“heart” on the front only"),
        ("tag:week1", "Cards with a tag"),
        ("is:due", "Due today (same as the button)"),
        ("rated:7", "Cards you studied in the last 7 days"),
        ("prop:lapses>3", "Cards you've forgotten more than 3 times"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Searching your cards").font(.headline)
            Text("Type in the search box at the top right. Searches ignore capitals and work on the card's text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(tips, id: \.0) { tip in
                    GridRow {
                        Text(tip.0).font(.callout.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                        Text(tip.1).font(.callout)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

/// Its own window: the cards you studied on one day, opened by clicking that
/// day on the heatmap. Everything Browse does works here too.
struct DayCardsWindow: View {
    @Environment(Library.self) private var library
    let offset: Int
    @State private var model: BrowseModel

    init(offset: Int) {
        self.offset = offset
        let model = BrowseModel()
        // Anki's search for "answered this many days ago" (0 = today).
        model.baseSearch = "prop:rated=\(offset)"
        _model = State(initialValue: model)
    }

    private var decks: [Deck] {
        if case .ready(let decks) = library.state { return decks }
        return []
    }

    private var date: Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private var title: String {
        offset == 0 ? "Cards studied today"
            : "Cards studied on " + date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    var body: some View {
        BrowsePage(decks: decks)
            .environment(model)
            .navigationTitle(title)
    }
}
