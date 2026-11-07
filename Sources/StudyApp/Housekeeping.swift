import AppKit
import SwiftUI
import StudyCore

// MARK: - New deck

extension Deck {
    /// The deck already using this full name ("Parent::Child"), if any. Anki
    /// treats names that differ only in capitals as the same deck.
    static func named(_ fullName: String, in decks: [Deck]) -> Deck? {
        let wanted = fullName.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        return flatten(decks).first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Anki keeps a built-in deck called "Default" and hides it while it's
    /// empty, so it isn't in the list but the name is still taken.
    static func isHiddenDefault(_ fullName: String, in decks: [Deck]) -> Bool {
        fullName.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Default") == .orderedSame
            && named(fullName, in: decks) == nil
    }
}

struct NewDeckSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let decks: [Deck]
    /// Opens a deck that already exists (when the name you typed is taken).
    var openExisting: ((Int64) -> Void)?
    @State private var name = ""
    @State private var parentID: Int64?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New deck").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline.weight(.medium))
                TextField("e.g. Cardiology", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Inside").font(.subheadline.weight(.medium))
                DeckPickerButton(decks: decks, selection: $parentID, emptyTitle: "Top level (no parent)", allowsAll: true)
                Text("Put it inside another deck to make it a section, e.g. a week of a module.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let existing {
                HStack(alignment: .firstTextBaseline) {
                    Label("You already have a deck called “\(existing.displayPath)”.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let openExisting {
                        Button("Open It") {
                            openExisting(existing.id)
                            dismiss()
                        }
                    }
                }
            } else if reservedName {
                Label("“Default” is the name of Anki's built-in deck. Pick another name.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleanName.isEmpty || name.contains("::") || existing != nil || reservedName)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespaces) }

    /// The name it would get, including the deck it's inside.
    private var fullName: String {
        let parent = parentID.flatMap { Deck.find($0, in: decks) }
        return parent.map { $0.name + "::" + cleanName } ?? cleanName
    }

    /// A deck that already has that name (Anki would quietly reuse it).
    private var existing: Deck? { cleanName.isEmpty ? nil : Deck.named(fullName, in: decks) }

    private var reservedName: Bool { Deck.isHiddenDefault(fullName, in: decks) }

    private func save() async {
        guard let engine = library.engine, !cleanName.isEmpty, existing == nil, !reservedName else { return }
        let full = fullName
        do {
            _ = try await engine.addDeck(named: full)
            await library.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Text / CSV import

struct CSVImportSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let file: URL
    let decks: [Deck]

    @State private var noteTypes: [NoteType] = []
    @State private var noteType: NoteType?
    @State private var deckID: Int64?
    @State private var preview: CSVPreview?
    @State private var duplicates = "update"
    @State private var error: String?
    @State private var result: CSVImportResult?
    @State private var working = false
    /// Spreadsheets often start with column names; those shouldn't become a card.
    @State private var hasHeader = false
    @State private var decidedHeader = false

    /// The file as Anki should read it: with a header row marked as column names.
    private var source: URL {
        guard hasHeader, let text = try? String(contentsOf: file, encoding: .utf8) else { return file }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first else { return file }
        let rest = lines.count > 1 ? String(lines[1]) : ""
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iterum-import-" + file.lastPathComponent)
        let header = first.trimmingCharacters(in: .newlines)
        // Anki reads the column names with the file's separator, so name it first.
        let separator = header.contains("\t") ? "tab"
            : header.filter { $0 == ";" }.count > header.filter { $0 == "," }.count ? "semicolon"
            : header.contains("|") && !header.contains(",") ? "pipe" : "comma"
        try? ("#separator:\(separator)\n#columns:" + header + "\n" + rest).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Import “\(file.lastPathComponent)”", systemImage: "tablecells")
                    .font(.title2.weight(.semibold))
                Text("Each row becomes a note. Columns fill the card's fields in order (or by name, if the file has a header row).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                HStack {
                    Text("Card type").font(.headline)
                    Picker("Card type", selection: $noteType) {
                        ForEach(noteTypes) { Text($0.name).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                HStack {
                    Text("Into").font(.headline)
                    DeckPickerButton(decks: decks, selection: $deckID)
                }
            }
            Toggle("The first row is column names, not a card", isOn: $hasHeader)
            if let preview, let noteType {
                mapping(preview, noteType)
                previewTable(preview)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
            Picker("If a note with the same first field is already there", selection: $duplicates) {
                Text("Update it").tag("update")
                Text("Skip it").tag("skip")
                Text("Add a copy").tag("duplicate")
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if let result {
                Label("Added \(result.added) note\(result.added == 1 ? "" : "s")"
                      + (result.updated > 0 ? ", updated \(result.updated)" : "")
                      + (result.skipped > 0 ? ", skipped \(result.skipped) already there" : "")
                      + (result.problems > 0 ? ", \(result.problems) rows couldn't be used" : "") + ".",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if result == nil {
                    Button {
                        Task { await importNow() }
                    } label: {
                        if working { ProgressView().controlSize(.small) } else { Text("Import") }
                    }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || noteType == nil || deckID == nil || preview == nil)
                }
            }
        }
        .padding(24)
        .frame(width: 640)
        .task {
            noteTypes = (try? await library.engine?.noteTypes()) ?? []
            deckID = RecentDecks.load().first { Deck.find($0, in: decks) != nil } ?? Deck.flatten(decks).first?.id
            await loadPreview(noteType: nil)
        }
        .onChange(of: noteType) { _, new in
            guard let new, new.id != preview?.noteTypeID else { return }
            Task { await loadPreview(noteType: new.id) }
        }
        .onChange(of: hasHeader) { Task { await loadPreview(noteType: noteType?.id) } }
    }

    private func mapping(_ preview: CSVPreview, _ type: NoteType) -> some View {
        FlowRow(spacing: 8) {
            ForEach(Array(type.fields.enumerated()), id: \.offset) { index, field in
                let column = preview.fieldColumns[safe: index] ?? 0
                HStack(spacing: 4) {
                    Text(column == 0 ? "—" : columnName(preview, column)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption)
                    Text(field).fontWeight(.medium)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func columnName(_ preview: CSVPreview, _ column: Int) -> String {
        let label = preview.columnLabels[safe: column - 1] ?? ""
        return label.isEmpty ? "Column \(column)" : label
    }

    private func previewTable(_ preview: CSVPreview) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(preview.preview.prefix(6).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(HTMLText.plain(value)).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(10)
        }
        .frame(height: 130)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func loadPreview(noteType id: Int64?) async {
        guard let engine = library.engine else { return }
        do {
            let loaded = try await engine.csvPreview(source, noteType: id)
            preview = loaded
            // First look: if the first row matches field names, it's a header.
            if !decidedHeader {
                decidedHeader = true
                let fieldNames = Set(noteTypes.flatMap(\.fields).map { $0.lowercased() })
                let firstRow = (loaded.preview.first ?? []).map { HTMLText.plain($0).lowercased().trimmingCharacters(in: .whitespaces) }
                if !firstRow.isEmpty, firstRow.contains(where: fieldNames.contains) {
                    hasHeader = true
                    return
                }
            }
            if noteType?.id != loaded.noteTypeID {
                noteType = noteTypes.first { $0.id == loaded.noteTypeID } ?? noteTypes.first
            }
            error = nil
        } catch {
            self.error = "Couldn't read this file: \(error.localizedDescription)"
        }
    }

    private func importNow() async {
        guard let engine = library.engine, let noteType, let deckID else { return }
        working = true
        defer { working = false }
        do {
            result = try await engine.importCSV(source, deck: deckID, noteType: noteType.id, duplicates: duplicates)
            RecentDecks.use(deckID)
            error = nil
            await library.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Collection tools (Preferences)

struct CollectionToolsView: View {
    @Environment(Library.self) private var library
    @State private var dbResult: [String]?
    @State private var media: MediaCheck?
    @State private var busy: String?
    @State private var exportMedia = true
    @State private var message: String?
    @State private var confirmTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Check Database",
                        "Looks for and fixes problems in your collection, such as cards with a missing note. Safe to run any time.") {
                    HStack {
                        runButton("Check Database", "stethoscope", "db") { await checkDatabase() }
                        if let dbResult {
                            Label(dbResult.isEmpty ? "Everything looks fine." : "Done. \(dbResult.count == 1 ? "One note" : "\(dbResult.count) notes") below.",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    if let dbResult, !dbResult.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(dbResult, id: \.self) { Text("• " + $0).font(.caption) }
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                section("Check Media",
                        "Finds pictures and sounds no card uses (taking up space), and ones your cards need but are missing.") {
                    HStack {
                        runButton("Check Media", "photo.on.rectangle", "media") { await checkMedia() }
                        if let media, media.unused.isEmpty && media.missing.isEmpty {
                            Label("Everything looks fine.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    if let media {
                        if !media.unused.isEmpty {
                            HStack {
                                Text("\(media.unused.count) unused file\(media.unused.count == 1 ? "" : "s")")
                                Spacer()
                                Button("Move to Media Trash…") { confirmTrash = true }
                            }
                        }
                        if !media.missing.isEmpty {
                            HStack {
                                Text("\(media.missing.count) missing file\(media.missing.count == 1 ? "" : "s") used by \(media.missingNotes) note\(media.missingNotes == 1 ? "" : "s")")
                                Spacer()
                                Button("Tag Those Notes") { Task { await tagMissing() } }
                                    .tip("Adds the tag “missing-media” so you can find them in Browse")
                            }
                        }
                    }
                }

                section("Export Everything",
                        "Saves your whole collection (every deck, setting and bit of progress) as one .colpkg file. Use it to move to another computer or keep your own copy.") {
                    Toggle("Include pictures and sounds", isOn: $exportMedia)
                    runButton("Export Collection…", "square.and.arrow.up", "export") { await exportAll() }
                }

                if let message {
                    Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 460)
        .confirmationDialog("Move \(media?.unused.count ?? 0) unused files to the media trash?", isPresented: $confirmTrash) {
            Button("Move to Trash") { Task { await trashUnused() } }
        } message: {
            Text("They're kept in the media trash folder until you empty it, so nothing is lost straight away.")
        }
    }

    private func section<Content: View>(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func runButton(_ title: String, _ symbol: String, _ key: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task {
                busy = key
                await action()
                busy = nil
            }
        } label: {
            if busy == key { ProgressView().controlSize(.small) } else { Label(title, systemImage: symbol) }
        }
        .disabled(busy != nil || library.engine == nil)
    }

    private func checkDatabase() async {
        guard let engine = library.engine else { return }
        await library.backup(force: true)
        do {
            dbResult = try await engine.checkDatabase()
            await library.refresh()
        } catch { message = error.localizedDescription }
    }

    private func checkMedia() async {
        guard let engine = library.engine else { return }
        do { media = try await engine.checkMedia() } catch { message = error.localizedDescription }
    }

    private func trashUnused() async {
        guard let engine = library.engine, let unused = media?.unused else { return }
        do {
            try await engine.trashMedia(unused)
            message = "Moved \(unused.count) files to the media trash."
            media = try await engine.checkMedia()
        } catch { message = error.localizedDescription }
    }

    private func tagMissing() async {
        guard let engine = library.engine else { return }
        guard let notes = media?.missingNoteIDs, !notes.isEmpty else { return }
        do {
            let cards = try await engine.search("nid:" + notes.map(String.init).joined(separator: ","), notes: true)
            let count = try await engine.addTags("missing-media", toCards: cards)
            message = "Tagged \(count) note\(count == 1 ? "" : "s") “missing-media”."
        } catch { message = error.localizedDescription }
    }

    private func exportAll() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Animus collection \(Date().formatted(.iso8601.year().month().day())).colpkg"
        panel.allowedContentTypes = [.init(filenameExtension: "colpkg") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url, let engine = library.engine else { return }
        do {
            try await engine.exportCollection(to: url, includeMedia: exportMedia)
            await library.refresh()
            message = "Saved \(url.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { message = error.localizedDescription }
    }
}
