import SwiftUI
import StudyCore

/// The right side of Browse: the card as you'd see it while studying,
/// and its fields, ready to edit.
struct NoteEditorPanel: View {
    @Environment(Library.self) private var library
    @Environment(BrowseModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Pref.cardTextSize) private var textSize = CardTextSize.normal
    @AppStorage(Pref.cardStyle) private var cardStyle = CardStyle.app
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue

    let cardID: Int64
    let decks: [Deck]

    @State private var note: EditableNote?
    /// Each field as it appears in the editor, and as it was when loaded.
    @State private var drafts: [FieldDraft] = []
    @State private var tags = ""
    @State private var originalTags = ""
    @State private var showAnswer = false
    /// Off by default: fields look like the card. On shows the HTML code.
    @AppStorage("browseShowHTML") private var showHTML = false
    @State private var error: String?
    @State private var saved = false
    @State private var editingBoxes = false
    @State private var editingType = false

    /// Anki's own "hide parts of a picture" card type.
    private func isOcclusion(_ note: EditableNote) -> Bool {
        note.fieldNames.first == "Occlusion" && note.fieldNames.contains("Image")
    }

    private func occlusionCard(_ note: EditableNote) -> OcclusionCard? {
        let fields = Dictionary(zip(note.fieldNames, note.fields), uniquingKeysWith: { a, _ in a })
        return OcclusionCard(OcclusionFields(kind: "builtin", ordinal: note.cardOrdinal + 1, fields: fields),
                             media: Library.mediaFolder)
    }

    private func imageURL(_ note: EditableNote) -> URL? {
        guard let index = note.fieldNames.firstIndex(of: "Image"),
              let range = note.fields[index].range(of: #"src\s*=\s*"[^"]+""#, options: .regularExpression) else { return nil }
        let match = note.fields[index][range]
        guard let start = match.firstIndex(of: "\""), let end = match.lastIndex(of: "\""), start < end else { return nil }
        let name = String(match[match.index(after: start)..<end])
        return Library.mediaFolder.appendingPathComponent(name.removingPercentEncoding ?? name)
    }

    private var changed: Bool {
        drafts.contains(where: \.changed) || tags != originalTags
    }

    var body: some View {
        Group {
            if let note {
                content(note)
            } else if let error {
                ContentUnavailableView("Couldn't open this card", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background.secondary)
        .task { await load() }
        .sheet(isPresented: $editingType, onDismiss: { Task { await load() } }) {
            CardTypesView(startID: note?.noteTypeID)
        }
        .sheet(isPresented: $editingBoxes) {
            if let note, let url = imageURL(note) {
                BoxEditSheet(note: note, image: url, tags: $tags) {
                    editingBoxes = false
                    Task {
                        await load()
                        if let engine = library.engine {
                            model.didChange("Edit Boxes")
                            await model.reload([cardID], engine: engine)
                        }
                    }
                }
            }
        }
    }

    private func content(_ note: EditableNote) -> some View {
        VStack(spacing: 0) {
            preview(note)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Button {
                            editingType = true
                        } label: {
                            Label(note.noteTypeName, systemImage: "rectangle.on.rectangle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.hoverable)
                        .help("Edit this card type's fields, layout and styling")
                        Spacer()
                        Toggle("Show HTML", isOn: $showHTML)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.caption)
                            .help("See and edit the formatting code behind each field")
                        if let deck = Deck.find(note.deckID, in: decks) {
                            Label(deck.displayPath, systemImage: "rectangle.stack")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    if isOcclusion(note), imageURL(note) != nil {
                        Button {
                            editingBoxes = true
                        } label: {
                            Label("Edit Boxes…", systemImage: "rectangle.dashed")
                        }
                        .buttonStyle(.borderedProminent)
                        .hoverGlow()
                        .help("Move, add or remove the boxes hiding parts of this picture")
                    }
                    ForEach($drafts) { $draft in
                        // The boxes and picture are edited with Edit Boxes, not as text.
                        if !(isOcclusion(note) && !showHTML && ["Occlusion", "Image"].contains(draft.name)) {
                            FieldEditor(draft: $draft, showHTML: showHTML)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tags").font(.subheadline.weight(.medium))
                        TextField("e.g. anatomy week1", text: $tags)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
    }

    private func preview(_ note: EditableNote) -> some View {
        VStack(spacing: 8) {
            Picker("Side", selection: $showAnswer) {
                Text("Front").tag(false)
                Text("Back").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            if isOcclusion(note), let card = occlusionCard(note) {
                OcclusionCardView(card: card, showingAnswer: showAnswer, accent: accent.color)
                    .padding(10)
                    .frame(minHeight: 180, idealHeight: 230)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.background))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
            } else {
            CardWebView(payload: CardPayload(
                            cardID: note.cardID,
                            side: showAnswer ? .answer : .question,
                            html: showAnswer ? note.answer : note.question,
                            css: note.css,
                            upcoming: nil,
                            dark: colorScheme == .dark,
                            zoom: textSize.zoom * 0.8,
                            appStyle: cardStyle == .app,
                            accentHex: accent.hex),
                        mediaFolder: Library.mediaFolder) { _, _ in }
                .frame(minHeight: 180, idealHeight: 230)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
            }
        }
        .padding(14)
        .frame(height: 290)
    }

    private var footer: some View {
        HStack {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if saved, !changed {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else if changed {
                Text("Unsaved changes").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { reset() }
                .disabled(!changed)
            Button {
                Task { await save() }
            } label: {
                Label("Save", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .hoverGlow()
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!changed)
            .help("Save changes (⌘S)")
        }
        .font(.callout)
        .padding(12)
    }

    // MARK: Logic

    private func load() async {
        guard let engine = library.engine else { return }
        do {
            let loaded = try await engine.note(forCard: cardID)
            note = loaded
            reset(to: loaded)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        if let note { reset(to: note) }
    }

    private func reset(to note: EditableNote) {
        drafts = zip(note.fieldNames, note.fields).enumerated().map { index, pair in
            FieldDraft(index: index, name: pair.0, html: pair.1)
        }
        tags = note.tags.joined(separator: " ")
        originalTags = tags
    }

    private func save() async {
        guard let engine = library.engine, let note else { return }
        let fields = drafts.map(\.output)
        let tagList = tags.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        do {
            try await engine.updateNote(note.noteID, fields: fields, tags: tagList)
            error = nil
            withAnimation { saved = true }
            model.didChange("Edit")
            await model.reload([cardID], engine: engine)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One field being edited. `html` starts as the note's own HTML and only
/// changes when you edit it, so untouched fields are saved back exactly.
struct FieldDraft: Identifiable {
    let index: Int
    let name: String
    let original: String
    var html: String

    var id: Int { index }
    var changed: Bool { html != original }
    var output: String { html }

    init(index: Int, name: String, html: String) {
        self.index = index
        self.name = name
        self.original = html
        self.html = html
    }
}

private struct FieldEditor: View {
    @Binding var draft: FieldDraft
    let showHTML: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 44
    @State private var handle = RichEditorHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(draft.name).font(.subheadline.weight(.medium))
                Spacer()
                if !showHTML {
                    formatButton("bold", "bold", "Bold")
                    formatButton("italic", "italic", "Italic")
                    formatButton("underline", "underline", "Underline")
                    formatButton("insertUnorderedList", "list.bullet", "Bullet list")
                }
            }
            Group {
                if showHTML {
                    TextEditor(text: $draft.html)
                        .font(.callout.monospaced())
                        .frame(minHeight: 54)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .scrollContentBackground(.hidden)
                } else {
                    RichFieldEditor(html: draft.html, dark: colorScheme == .dark, handle: handle,
                                    height: $height) { draft.html = $0 }
                        .frame(height: height)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(draft.changed ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)))
        }
    }

    private func formatButton(_ command: String, _ symbol: String, _ help: String) -> some View {
        Button { handle.format(command) } label: {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .buttonStyle(.hoverable)
        .help(help)
    }
}


/// Reopens the box editor for a picture card from Browse.
private struct BoxEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let note: EditableNote
    let image: URL
    @Binding var tags: String
    let saved: () -> Void

    private func field(_ name: String) -> String {
        note.fieldNames.firstIndex(of: name).map { note.fields[$0] } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Edit boxes", systemImage: "rectangle.dashed").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                OcclusionEditor(deckID: note.deckID, tags: $tags, onAdded: { _ in saved() },
                                existing: .init(noteID: note.noteID, image: image, occlusions: field("Occlusion"),
                                                header: OcclusionCard.plainText(field("Header")),
                                                extra: OcclusionCard.plainText(field("Back Extra"))))
            }
        }
        .padding(20)
        .frame(width: 820, height: 630)
    }
}
