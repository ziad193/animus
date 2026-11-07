import AppKit
import PDFKit
import StudyCore
import SwiftUI

// The screen every Animus+ card-maker ends on: suggested cards arrive one by
// one, each beside the slide or picture it came from; you edit, keep or drop
// them, pick the deck, and add the ones you keep.

/// Where the suggestions came from, shown beside them so checking is quick.
enum DraftSource {
    /// A lecture PDF: the card's own slide is shown.
    case lecture(PDFDocument)
    /// A captured slide or part of one.
    case picture(NSImage)
    /// Pasted notes: nothing to show beside the cards.
    case notes
}

struct DraftReviewView: View {
    let title: String
    let feature: PlusFeature
    let source: DraftSource
    /// Fill-in-the-blank cards (front holds {{c1::…}}) rather than front/back.
    let cloze: Bool
    /// Gap check: compare each suggestion with the deck and untick likely repeats.
    var checkDeck = false
    let make: () -> AsyncThrowingStream<DraftCard, Error>
    @State var deckID: Int64?
    var onDone: () -> Void

    @Environment(Library.self) private var library
    @State private var drafts: [DraftCard] = []
    @State private var making = true
    @State private var problem: String?
    @State private var selected: DraftCard.ID?
    @State private var adding = false
    @State private var added: Int?
    @State private var task: Task<Void, Never>?

    private var decks: [Deck] {
        if case .ready(let decks) = library.state { return decks }
        return []
    }
    private var kept: Int { drafts.filter { $0.keep && !$0.front.trimmingCharacters(in: .whitespaces).isEmpty }.count }
    private var deckName: String { deckID.flatMap { Deck.find($0, in: decks)?.shortName } ?? "a deck" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let added {
                finished(added)
            } else {
                HStack(spacing: 0) {
                    list
                    if hasPreview {
                        Divider()
                        preview
                            .frame(width: 360)
                    }
                }
                Divider()
                footer
            }
        }
        .frame(minWidth: hasPreview ? 900 : 620, minHeight: 600)
        .task { start() }
        .onDisappear { task?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: feature.symbol).font(.title3).foregroundStyle(Color.accentColor)
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
            PlusBadge()
            Spacer()
            if making {
                ProgressView().controlSize(.small)
                Text(drafts.isEmpty ? "Reading…" : "\(drafts.count) so far…")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Stop") { task?.cancel(); making = false }
                    .tip("Stop here and keep what's been made so far")
            } else if !drafts.isEmpty {
                if checkDeck {
                    Text("\(drafts.count - repeats) new · \(repeats) you may have")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Keep All") { setAll(true) }
                Button("Keep None") { setAll(false) }
            }
        }
        .buttonStyle(.hoverable)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottomLeading) {
            if PlusAI.current.isStandIn {
                Text("Stand-in suggestions: no AI is connected yet, so these come from the slide's own text.")
                    .font(.caption2).foregroundStyle(.orange)
                    .padding(.leading, 18).padding(.bottom, 2)
            }
        }
    }

    // MARK: Cards

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if drafts.isEmpty && !making {
                    ContentUnavailableView("No cards this time",
                                           systemImage: "rectangle.dashed",
                                           description: Text(problem ?? "Nothing in there looked like something to learn. Try another slide or part of it."))
                        .padding(.top, 60)
                }
                ForEach($drafts) { $draft in
                    DraftRow(draft: $draft, cloze: cloze, selected: selected == draft.id) {
                        drafts.removeAll { $0.id == draft.id }
                    }
                    .onTapGesture { selected = draft.id }
                }
                if let problem, !drafts.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Beside the cards

    private var hasPreview: Bool {
        if case .notes = source { return false }
        return true
    }

    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch source {
            case .lecture(let document):
                let index = drafts.first { $0.id == selected }?.source ?? drafts.last?.source ?? 0
                Text("Slide \(index + 1) of \(document.pageCount)").font(.headline)
                if let page = document.page(at: index) {
                    Image(nsImage: page.thumbnail(of: CGSize(width: 680, height: 520), for: .mediaBox))
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                }
                Text("Click a card to see the slide it came from.")
                    .font(.caption).foregroundStyle(.secondary)
            case .picture(let image):
                Text("What you captured").font(.headline)
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            case .notes:
                EmptyView()
            }
            Spacer()
        }
        .padding(16)
        .background(.background.secondary)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Add to").font(.callout.weight(.medium))
            DeckPickerButton(decks: decks, selection: $deckID)
                .frame(maxWidth: 280)
            Spacer()
            Text(kept == 1 ? "1 card kept" : "\(kept) cards kept")
                .font(.callout).foregroundStyle(.secondary)
            Button("Cancel") { task?.cancel(); onDone() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await add() }
            } label: {
                if adding { ProgressView().controlSize(.small) }
                else { Text(kept == 1 ? "Add 1 Card" : "Add \(kept) Cards") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(kept == 0 || deckID == nil || adding)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func finished(_ count: Int) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text(count == 1 ? "Added 1 card to \(deckName)" : "Added \(count) cards to \(deckName)")
                .font(.title3.weight(.semibold))
            Text("They're tagged “animus-plus”, so you can find them in Browse.")
                .foregroundStyle(.secondary)
            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Doing it

    private func start() {
        guard task == nil else { return }
        task = Task {
            do {
                for try await draft in make() {
                    var draft = draft
                    if checkDeck, await alreadyInDeck(draft) {
                        draft.keep = false
                        draft.note = "You may already have this"
                    }
                    withAnimation(.snappy) { drafts.append(draft) }
                    if selected == nil { selected = draft.id }
                }
            } catch is CancellationError {
            } catch {
                problem = "Stopped early: \(error.localizedDescription)"
            }
            making = false
        }
    }

    /// Whether the deck already has a card about this suggestion's key term.
    private func alreadyInDeck(_ draft: DraftCard) async -> Bool {
        guard let engine = library.engine, let deckID, let deck = Deck.find(deckID, in: decks) else { return false }
        let term = Self.keyTerm(draft.front)
        guard term.count >= 3 else { return false }
        let query = "deck:\"\(deck.name.replacingOccurrences(of: "\"", with: ""))\" \"\(term)\""
        return !((try? await engine.search(query)) ?? []).isEmpty
    }

    /// "What is Cardiac tamponade?" → "Cardiac tamponade"; otherwise the first few words.
    static func keyTerm(_ front: String) -> String {
        var text = front
        for prefix in ["What is ", "What are ", "What does "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.replacingOccurrences(of: #"\{\{c\d+::(.+?)\}\}"#, with: "$1", options: .regularExpression)
        let cleaned = text.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }
        return cleaned.split(separator: " ").prefix(4).joined(separator: " ")
    }

    /// How many suggestions the gap check thinks you already have.
    private var repeats: Int { drafts.filter { $0.note != nil }.count }

    private func setAll(_ keep: Bool) {
        for index in drafts.indices { drafts[index].keep = keep }
    }

    private func add() async {
        guard let engine = library.engine, let deckID else { return }
        adding = true
        defer { adding = false }
        do {
            let kind = cloze ? "cloze" : "basic"
            var types = try await engine.noteTypes()
            if !types.contains(where: { $0.kind == kind }) {
                _ = try await engine.addStockNoteType(kind)
                types = try await engine.noteTypes()
            }
            guard let type = types.first(where: { $0.kind == kind }) else {
                problem = "Couldn't find a card type to use."
                return
            }
            var count = 0
            for draft in drafts where draft.keep && !draft.front.trimmingCharacters(in: .whitespaces).isEmpty {
                var fields = [draft.front.cardHTML, draft.back.cardHTML]
                while fields.count < type.fields.count { fields.append("") }
                _ = try await engine.addNote(noteType: type.id, deck: deckID, fields: Array(fields.prefix(type.fields.count)),
                                             tags: ["animus-plus"])
                count += 1
            }
            RecentDecks.use(deckID)
            await library.refresh()
            withAnimation { added = count }
        } catch {
            problem = "Couldn't add the cards: \(error.localizedDescription)"
        }
    }
}

/// One suggested card: editable front and back, keep switch, and its slide.
struct DraftRow: View {
    @Binding var draft: DraftCard
    let cloze: Bool
    let selected: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $draft.keep)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tip(draft.keep ? "Keep this card" : "Leave this card out")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let source = draft.source {
                        Text("Slide \(source + 1)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    if let note = draft.note {
                        Label(note, systemImage: "square.on.square")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                        .buttonStyle(.hoverable)
                        .tip("Drop this card")
                }
                TextField(cloze ? "Text with {{c1::blanks}}" : "Front", text: $draft.front, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.weight(.medium))
                TextField(cloze ? "Extra (optional)" : "Back", text: $draft.back, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                if cloze {
                    Text(Self.clozePreview(draft.front))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .opacity(draft.keep ? 1 : 0.5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(selected ? 0.07 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Rectangle())
    }

    /// "The {{c1::mitral}} valve" → "The [...] valve", as the card will ask it.
    static func clozePreview(_ text: String) -> String {
        "Shows as: " + text.replacingOccurrences(of: #"\{\{c\d+::(.+?)(::.+?)?\}\}"#, with: "[...]", options: .regularExpression)
    }
}
