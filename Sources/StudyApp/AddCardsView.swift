import SwiftUI
import StudyCore

/// Make new cards. The card types sit in plain view as tiles, each with a
/// short explanation, so choosing one never means digging through menus.
struct AddCardsView: View {
    @Environment(Library.self) private var library
    /// The deck to start on (e.g. the one you were looking at); otherwise your last used.
    var initialDeckID: Int64? = nil
    /// The Slides & Notes hint (Preferences → General can turn it off).
    @AppStorage(Pref.slidesHint) private var showSlidesHint = true

    @State private var noteTypes: [NoteType] = []
    @State private var kind: CardKind = .basic
    @State private var otherType: NoteType?
    @State private var deckID: Int64?
    @State private var fields: [String] = []
    @State private var tags = ""
    /// One handle per field, so the formatting buttons reach the right editor.
    @State private var handles: [RichEditorHandle] = []
    @State private var heights: [CGFloat] = []
    /// Fields that keep their text after adding (e.g. a source or chapter), per card type.
    @State private var sticky: Set<Int> = []
    @State private var duplicate = false
    @State private var wide = true
    @State private var showCardTypes = false
    @State private var toast: String?
    @State private var error: String?
    @AppStorage("addCards.showReference") private var showReference = false

    private var decks: [Deck] {
        if case .ready(let decks) = library.state { return decks }
        return []
    }

    /// The note type behind the chosen tile.
    private var noteType: NoteType? {
        if kind == .other { return otherType }
        return noteTypes.first { $0.kind == kind.engineKind }
    }

    var body: some View {
        HSplitView {
            editor
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            if showReference {
                ReferencePanel(deckID: deckID ?? 0) { showReference = false }
                    .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Add Cards")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showReference.animation()) {
                    Label("Slides & Notes", systemImage: "sidebar.right")
                }
                .tip("Show a PDF or PowerPoint while you make cards")
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCardTypes, onDismiss: {
            Task {
                noteTypes = (try? await library.engine?.noteTypes()) ?? noteTypes
                resetFields()
            }
        }) {
            CardTypesView(startID: noteType?.id)
        }
        .onChange(of: initialDeckID) { if let initialDeckID { deckID = initialDeckID } }
        .onChange(of: kind) { resetFields() }
        .onChange(of: otherType) { resetFields() }
        .task(id: [String(noteType?.id ?? 0)] + fields.prefix(1)) { await checkDuplicate() }
    }

    @State private var plusStore = PlusStore.shared
    @State private var plusWorkflow: PlusFeature?

    // MARK: Layout

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !showReference && showSlidesHint {
                    slidesTip
                }
                // Animus+ (Animus Dev only until it's ready): make cards from a lecture.
                if plusStore.showsPreviews && plusStore.showsPrompts {
                    HStack(spacing: 10) {
                        PlusFeatureButton(feature: .lectureToCards) {
                            plusWorkflow = .lectureToCards
                        } label: {
                            Label("Make cards from a lecture", systemImage: PlusFeature.lectureToCards.symbol)
                        }
                        PlusFeatureButton(feature: .clozeFromNotes) {
                            plusWorkflow = .clozeFromNotes
                        } label: {
                            Label("Fill-in-the-blank from notes", systemImage: PlusFeature.clozeFromNotes.symbol)
                        }
                        PlusFeatureButton(feature: .pictureToCards) {
                            plusWorkflow = .pictureToCards
                        } label: {
                            Label("Cards from a photo", systemImage: PlusFeature.pictureToCards.symbol)
                        }
                    }
                    .controlSize(.large)
                    .sheet(item: $plusWorkflow) { feature in
                        switch feature {
                        case .clozeFromNotes: ClozeNotesSheet(deckID: deckID)
                        case .pictureToCards: PictureCardsSheet(deckID: deckID)
                        default: LectureCardsSheet(deckID: deckID)
                        }
                    }
                }
                typePicker
                deckPicker
                if kind == .occlusion {
                    OcclusionEditor(deckID: deckID, tags: $tags) { count in
                        let deckName = deckID.flatMap { Deck.find($0, in: decks)?.shortName } ?? "your deck"
                        withAnimation { toast = "Added \(count) card\(count == 1 ? "" : "s") to \(deckName)" }
                    }
                    if let toast {
                        Label(toast, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else if let noteType {
                    // Preview beside the fields when there's room, underneath when not.
                    // (One layout that changes shape, so the editors aren't rebuilt.)
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                                      : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                    layout {
                        fieldEditors(noteType)
                            .frame(minWidth: 320, maxWidth: .infinity)
                        CardPreview(kind: kind, fields: fields.map(HTMLText.plain))
                            .frame(width: wide ? 260 : nil)
                            .frame(maxWidth: wide ? 260 : .infinity)
                    }
                    .onGeometryChange(for: Bool.self) { $0.size.width > 640 } action: { wide = $0 }
                } else if !noteTypes.isEmpty {
                    Text("This collection doesn't have that card type yet.")
                        .foregroundStyle(.secondary)
                }
                if kind != .occlusion { footer }
            }
            .padding(28)
        }
        // The background picture, blurred so the fields stay the focus.
        .pageBackground(blur: 28, plain: .background.secondary)
    }

    /// A slim, always-there reminder that you can keep slides beside the card
    /// (switched off in Settings → General).
    private var slidesTip: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.tint)
            Text("Making cards from lecture slides? Keep them open beside you.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("Open Slides & Notes") {
                withAnimation { showReference = true }
            }
            .buttonStyle(.hoverable)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What kind of card?").font(.headline)
                Spacer()
                Button {
                    showCardTypes = true
                } label: {
                    Label("Manage Card Types", systemImage: "slider.horizontal.below.rectangle")
                }
                .buttonStyle(.hoverable)
                .tip("Change a card type's fields, layout and styling, or make a new one")
            }
            // Wraps onto a second row when the Slides & Notes panel is open.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 150), spacing: 10, alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                ForEach(CardKind.allCases) { option in
                    TypeTile(kind: option, selected: kind == option,
                             // The standard types are always offered: if the collection
                             // lacks one, picking it adds Anki's own version.
                             available: option == .other ? !otherTypes.isEmpty : true) {
                        kind = option
                        Task { await ensureNoteType(for: option) }
                    }
                }
            }
            if kind == .other {
                Picker("Card type", selection: $otherType) {
                    ForEach(otherTypes) { Text($0.name).tag(Optional($0)) }
                }
                .frame(maxWidth: 360)
            }
        }
    }

    private var otherTypes: [NoteType] {
        noteTypes.filter { !["basic", "reversed", "typing", "cloze"].contains($0.kind) && $0.kind != "occlusion" }
    }

    /// A searchable deck chooser plus your recent decks as one-click chips,
    /// because a menu of hundreds of decks is impossible to scan.
    private var deckPicker: some View {
        // Recent decks sit beside the picker when there's room, underneath when not.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text("Add to").font(.headline).fixedSize()
                DeckPickerButton(decks: decks, selection: $deckID, create: createDeck)
                RecentDeckChips(decks: decks, selection: $deckID)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Add to").font(.headline).fixedSize()
                    DeckPickerButton(decks: decks, selection: $deckID, create: createDeck)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    RecentDeckChips(decks: decks, selection: $deckID)
                }
            }
        }
    }

    private func createDeck(_ name: String) async -> Int64? {
        guard let engine = library.engine else { return nil }
        do {
            let id = try await engine.addDeck(named: name)
            await library.refresh()
            return id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func fieldEditors(_ type: NoteType) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(type.fields.enumerated()), id: \.offset) { index, name in
                if index < fields.count, !(kind == .reversed && name == "Add Reverse") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(label(for: name, index: index)).font(.subheadline.weight(.medium))
                            Spacer()
                            if kind == .cloze && index == 0 {
                                Button {
                                    makeBlank()
                                } label: {
                                    Label("Make blank", systemImage: "rectangle.dashed")
                                }
                                .keyboardShortcut("c", modifiers: [.command, .shift])
                                .tip("Select words, then click to hide them (⇧⌘C)")
                            }
                        }
                        if index < handles.count {
                            RichFieldBox(html: $fields[index],
                                         height: $heights[index],
                                         handle: handles[index],
                                         minHeight: index == 0 ? 90 : 60,
                                         pinned: Binding(get: { sticky.contains(index) },
                                                         set: { setSticky(index, $0) }))
                        }
                        if index == 0 && duplicate {
                            Label("You already have a card with this front. You can still add it.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tags (optional)").font(.subheadline.weight(.medium))
                TextField("e.g. anatomy week1", text: $tags)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            Spacer()
            Button {
                Task { await add() }
            } label: {
                Label("Add Card", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .hoverGlow()
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canAdd)
            .tip("Add (⌘Return)")
        }
    }

    // MARK: Logic

    private var canAdd: Bool {
        guard noteType != nil, deckID != nil, let first = fields.first else { return false }
        let trimmed = HTMLText.plain(first).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !HTMLText.hasMedia(first) { return false }
        if kind == .cloze {
            // Needs at least one blank with something in it.
            return trimmed.firstMatch(of: CardPreview.filledBlank) != nil
        }
        return true
    }

    private func label(for name: String, index: Int) -> String {
        switch (kind, index) {
        case (.basic, 0), (.reversed, 0), (.typing, 0): "Front — the question"
        case (.basic, 1), (.reversed, 1): "Back — the answer"
        case (.typing, 1): "Back — the exact answer to type"
        case (.cloze, 0): "Text — select words and press Make blank"
        case (.cloze, 1): "Extra info shown with the answer"
        default: name
        }
    }

    /// Decks made elsewhere sometimes lack a standard card type (often
    /// "Basic (type in the answer)"); add Anki's own copy the first time it's picked.
    private func ensureNoteType(for option: CardKind) async {
        guard [.basic, .reversed, .typing, .cloze].contains(option),
              !noteTypes.contains(where: { $0.kind == option.engineKind }),
              let engine = library.engine else { return }
        do {
            try await engine.addStockNoteType(option.engineKind)
            noteTypes = (try? await engine.noteTypes()) ?? noteTypes
            resetFields()
        } catch {
            self.error = "Couldn't set up this card type: \(error.localizedDescription)"
        }
    }

    private func load() async {
        guard let engine = library.engine else { return }
        noteTypes = (try? await engine.noteTypes()) ?? []
        otherType = otherTypes.first
        if let initialDeckID, Deck.find(initialDeckID, in: decks) != nil {
            deckID = initialDeckID
        } else if deckID == nil {
            deckID = RecentDecks.load().first { Deck.find($0, in: decks) != nil } ?? Deck.flatten(decks).first?.id
        }
        resetFields()
    }

    /// A new card type: empty fields, with its own pinned fields.
    private func resetFields() {
        let count = noteType?.fields.count ?? 2
        fields = Array(repeating: "", count: count)
        handles = (0..<count).map { _ in RichEditorHandle() }
        heights = Array(repeating: 44, count: count)
        sticky = Set((AppDefaults.current.array(forKey: stickyKey) as? [Int]) ?? [])
        duplicate = false
        error = nil
    }

    /// After adding: clear the fields, except pinned ones.
    private func clearForNext() {
        for index in fields.indices where !sticky.contains(index) { fields[index] = "" }
        duplicate = false
        let first = fields.indices.first { !sticky.contains($0) } ?? 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            handles[safe: first]?.focus()
            // A kept front now matches the card just added.
            if sticky.contains(0) { await checkDuplicate() }
        }
    }

    private var stickyKey: String { "addCards.sticky.\(noteType?.id ?? 0)" }

    private func setSticky(_ index: Int, _ on: Bool) {
        if on { sticky.insert(index) } else { sticky.remove(index) }
        AppDefaults.current.set(Array(sticky), forKey: stickyKey)
    }

    /// Warns (without blocking) when the first field matches a card you already have.
    private func checkDuplicate() async {
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, let engine = library.engine, let noteType,
              let first = fields.first, !HTMLText.plain(first).trimmingCharacters(in: .whitespaces).isEmpty else {
            duplicate = false
            return
        }
        let state = (try? await engine.checkNote(noteType: noteType.id, fields: fields)) ?? "ok"
        withAnimation { duplicate = state == "duplicate" }
    }

    /// Wraps the selected words in the next cloze number: "{{c2::words}}".
    private func makeBlank() {
        guard let handle = handles.first else { return }
        let all = fields.joined()
        let next = (1...50).first { !all.contains("{{c\($0)::") } ?? 1
        handle.cloze(next)
    }

    private func add() async {
        guard canAdd, let engine = library.engine, let noteType, let deckID else { return }
        let html = fields.map(HTMLText.tidy)
        let tagList = tags.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        do {
            let cards = try await engine.addNote(noteType: noteType.id, deck: deckID, fields: html, tags: tagList)
            RecentDecks.use(deckID)
            let deckName = Deck.find(deckID, in: decks)?.shortName ?? "your deck"
            withAnimation { toast = cards == 1 ? "Added 1 card to \(deckName)" : "Added \(cards) cards to \(deckName)" }
            error = nil
            clearForNext()
            await library.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The last word that isn't already inside a blank.
    static func lastWord(in text: String) -> Range<String.Index>? {
        guard !text.hasSuffix("}}") else { return nil }
        let trimmedEnd = text.lastIndex(where: { !$0.isWhitespace && !$0.isPunctuation }).map { text.index(after: $0) }
        guard let end = trimmedEnd else { return nil }
        let start = text[..<end].lastIndex(where: { $0.isWhitespace }).map { text.index(after: $0) } ?? text.startIndex
        return start < end ? start..<end : nil
    }
}

// MARK: - Card types

enum CardKind: String, CaseIterable, Identifiable {
    case basic, reversed, typing, cloze, occlusion, other
    var id: String { rawValue }

    var engineKind: String { rawValue }

    var title: String {
        switch self {
        case .basic: "Question & Answer"
        case .reversed: "Both Ways"
        case .typing: "Type the Answer"
        case .cloze: "Fill in the Blank"
        case .occlusion: "Hide Parts of a Picture"
        case .other: "Your Other Types"
        }
    }

    var symbol: String {
        switch self {
        case .basic: "rectangle.on.rectangle"
        case .reversed: "arrow.left.arrow.right"
        case .typing: "keyboard"
        case .cloze: "text.badge.minus"
        case .occlusion: "photo.on.rectangle"
        case .other: "square.grid.2x2"
        }
    }

    /// Always shown under the tiles, so the choice is never a guess.
    var explanation: String {
        switch self {
        case .basic:
            "A question on the front, the answer on the back. Best for facts: “What does the cerebellum do?”"
        case .reversed:
            "Makes two cards so you learn it in both directions, e.g. term → meaning and meaning → term. Great for vocabulary and drug names."
        case .typing:
            "You type the answer and the app shows which letters you got right. Good for spellings, doses and exact names."
        case .cloze:
            "Write a sentence, then hide key words: “The {{c1::heart}} pumps blood”. Each blank becomes its own card. Ideal for notes and lecture slides."
        case .occlusion:
            "Cover labels on a diagram and recall them one by one. Choose a picture, then drag boxes over the parts to hide."
        case .other:
            "Card types that came with your decks."
        }
    }

    var example: (front: String, back: String) {
        switch self {
        case .basic: ("What does the cerebellum coordinate?", "Movement and balance")
        case .reversed: ("Tachycardia", "Fast heart rate (>100 bpm)")
        case .typing: ("Bone of the upper arm?", "humerus")
        case .cloze: ("The [...] pumps blood", "The heart pumps blood")
        case .occlusion: ("Diagram with a hidden label", "The label revealed")
        case .other: ("Front", "Back")
        }
    }
}

private struct TypeTile: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    let kind: CardKind
    let selected: Bool
    let available: Bool
    let action: () -> Void
    @State private var showInfo = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: kind.symbol)
                        .font(.title3)
                        .foregroundStyle(selected ? Color.white : accent.color)
                    Spacer()
                    // Room for the ? (drawn on top, outside this button, so it gets its own clicks).
                    Color.clear.frame(width: 22, height: 22)
                }
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? Color.white : .primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? AnyShapeStyle(accent.color) : AnyShapeStyle(.background)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.clear : Color.secondary.opacity(0.25)))
            .opacity(available ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.03)
        .disabled(!available)
        .overlay(alignment: .topTrailing) {
            Button { showInfo.toggle() } label: {
                Image(systemName: "questionmark.circle")
                    .font(.body)
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip("What is \(kind.title)?")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { TypeExplainer(kind: kind) }
            .padding(6)
        }
    }
}

/// The "?" popover: what the card type is, a worked example, when to use it.
private struct TypeExplainer: View {
    let kind: CardKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(kind.title, systemImage: kind.symbol).font(.headline)
            Text(kind.explanation).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                mini("Front", kind.example.front)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                mini("Back", kind.example.back)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func mini(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// A live, simplified preview of the card(s) being made.
struct CardPreview: View {
    // swiftlint:disable:next force_try
    static let clozeNumber = try! Regex(#"\{\{c(\d+)::"#)
    // swiftlint:disable:next force_try
    static let clozeBlank = try! Regex(#"\{\{c\d+::(.*?)\}\}"#)
    // swiftlint:disable:next force_try
    static let filledBlank = try! Regex(#"\{\{c\d+::[^}\s][^}]*\}\}"#)
    let kind: CardKind
    let fields: [String]

    private var front: String { fields.first ?? "" }
    private var back: String { fields.count > 1 ? fields[1] : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview").font(.headline)
            side("Front", frontText)
            side("Back", backText)
            if kind == .reversed, !back.isEmpty {
                Text("Plus a second card: \(back) → \(front)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if kind == .cloze {
                let count = Set(front.matches(of: Self.clozeNumber).compactMap { $0.output[1].substring.map(String.init) }).count
                Text(count == 1 ? "Makes 1 card" : "Makes \(count) cards, one per blank number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var frontText: String {
        switch kind {
        case .cloze: front.replacing(Self.clozeBlank) { _ in "[…]" }
        case .typing: front + (front.isEmpty ? "" : "\n\n[ type your answer ]")
        default: front
        }
    }

    private var backText: String {
        switch kind {
        case .cloze: front.replacing(Self.clozeBlank) { $0.output[1].substring.map(String.init) ?? "" } + (back.isEmpty ? "" : "\n\n" + back)
        default: back
        }
    }

    private func side(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text.isEmpty ? "…" : text)
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
        }
    }
}
