import AppKit
import Observation
import SwiftUI
import StudyCore

/// Which deck action is open right now. The main window shows the matching
/// sheet or dialog, so the cog menu can live on any tile.
@MainActor
@Observable
final class DeckActions {
    var renaming: Deck?
    var options: Deck?
    var exporting: Deck?
    var deleting: Deck?
    /// "Study more today" for this deck.
    var studyMore: Deck?
    /// The New Deck sheet.
    var creatingDeck = false
    /// The filtered-deck sheet (with the deck to borrow from, or none for all decks).
    var filtering: FilterSource?
    /// A filtered deck just made, to open straight away.
    var createdFiltered: Int64?

    struct FilterSource: Identifiable {
        let id = UUID()
        let deck: Int64?
    }
    /// After a delete, offered as an Undo button.
    var lastDeleted: String?
}

/// The cog on every deck: Rename, Options, Export, Delete.
struct DeckMenu: View {
    @Environment(DeckActions.self) private var actions
    let deck: Deck
    var size: CGFloat = 13

    var body: some View {
        Menu {
            if deck.filtered {
                // A filtered deck: refill it, or send its cards home.
                Button { Task { await rebuild() } } label: { Label("Rebuild", systemImage: "arrow.clockwise") }
                Button { Task { await returnCards() } } label: { Label("Return Cards to Their Decks", systemImage: "arrow.uturn.backward") }
                Button { actions.renaming = deck } label: { Label("Rename…", systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { actions.deleting = deck } label: { Label("Delete (Cards Go Back)", systemImage: "trash") }
            } else {
                Button { actions.renaming = deck } label: { Label("Rename…", systemImage: "pencil") }
                Button { actions.studyMore = deck } label: { Label("Study More Today…", systemImage: "plus.circle") }
                Button { actions.options = deck } label: { Label("Options…", systemImage: "slider.horizontal.3") }
                Button { actions.filtering = .init(deck: deck.id) } label: {
                    Label("Filtered Deck From This…", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button { actions.exporting = deck } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Divider()
                Button(role: .destructive) { actions.deleting = deck } label: { Label("Delete…", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .frame(width: size + 13, height: size + 13)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.hoverable)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(deck.filtered ? "Rebuild, return cards or delete “\(deck.shortName)”"
                            : "Rename, options, export or delete “\(deck.shortName)”")
    }

    @Environment(Library.self) private var library

    private func rebuild() async {
        guard let engine = library.engine else { return }
        do {
            let count = try await engine.rebuildFilteredDeck(deck.id)
            library.notice = "“\(deck.shortName)” now holds \(count) card\(count == 1 ? "" : "s")."
            await library.refresh()
        } catch { library.notice = error.localizedDescription }
    }

    private func returnCards() async {
        guard let engine = library.engine else { return }
        do {
            try await engine.emptyFilteredDeck(deck.id)
            await library.refresh()
        } catch { library.notice = error.localizedDescription }
    }
}

/// Puts the deck sheets and dialogs on the main window.
struct DeckActionPresenter: ViewModifier {
    @Environment(Library.self) private var library
    @Bindable var actions: DeckActions
    let decks: [Deck]

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.renaming) { deck in
                RenameDeckSheet(deck: deck, decks: decks)
            }
            .sheet(item: $actions.options) { deck in
                DeckOptionsView(deck: deck)
            }
            .sheet(item: $actions.studyMore) { deck in
                StudyMoreSheet(deck: deck)
            }
            .sheet(isPresented: $actions.creatingDeck) {
                NewDeckSheet(decks: decks)
            }
            .sheet(item: Binding(get: { library.csvImport }, set: { library.csvImport = $0 })) { file in
                CSVImportSheet(file: file.url, decks: decks)
            }
            .sheet(item: $actions.exporting) { deck in
                ExportDeckSheet(deck: deck)
            }
            .sheet(item: $actions.filtering) { source in
                FilteredDeckSheet(startDeck: source.deck) { id in actions.createdFiltered = id }
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { actions.deleting != nil },
                                                                  set: { if !$0 { actions.deleting = nil } }),
                                presenting: actions.deleting) { deck in
                Button("Delete Deck and Cards", role: .destructive) { Task { await delete(deck) } }
            } message: { deck in
                Text(deck.children.isEmpty
                     ? "This deletes its \(deck.totalCards) cards. You can undo it straight after."
                     : "This deletes its \(deck.children.count) sections and all \(deck.totalCards) cards inside. You can undo it straight after.")
            }
            .alert("Deck deleted", isPresented: Binding(get: { actions.lastDeleted != nil },
                                                        set: { if !$0 { actions.lastDeleted = nil } })) {
                Button("Undo") { Task { await undoDelete() } }
                Button("OK", role: .cancel) {}
            } message: {
                Text("“\(actions.lastDeleted ?? "")” and its cards were deleted.")
            }
    }

    private var deleteTitle: String {
        "Delete “\(actions.deleting?.shortName ?? "")”?"
    }

    private func delete(_ deck: Deck) async {
        guard let engine = library.engine else { return }
        do {
            try await engine.deleteDeck(deck.id)
            actions.lastDeleted = deck.shortName
            await library.refresh()
        } catch {
            library.notice = error.localizedDescription
        }
    }

    private func undoDelete() async {
        guard let engine = library.engine else { return }
        try? await engine.undo()
        actions.lastDeleted = nil
        await library.refresh()
    }
}

extension View {
    func deckActions(_ actions: DeckActions, decks: [Deck]) -> some View {
        modifier(DeckActionPresenter(actions: actions, decks: decks))
    }
}

// MARK: - Rename

private struct RenameDeckSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let deck: Deck
    let decks: [Deck]

    @State private var name = ""
    @State private var parentID: Int64?
    @State private var error: String?

    /// Decks it can't be moved into: itself and its own sections.
    private var movableDecks: [Deck] {
        let blocked = Set(deck.idsIncludingSections)
        func prune(_ list: [Deck]) -> [Deck] {
            list.filter { !blocked.contains($0.id) }
        }
        return prune(decks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename deck").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline.weight(.medium))
                TextField("Deck name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Inside").font(.subheadline.weight(.medium))
                DeckPickerButton(decks: movableDecks, selection: $parentID, emptyTitle: "Top level (no parent)", allowsAll: true)
                Text("Move it into another deck to make it a section of that deck.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("::"))
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            name = deck.shortName
            let parentName = deck.path.dropLast().joined(separator: "::")
            parentID = Deck.flatten(decks).first { $0.name == parentName }?.id
        }
    }

    private func save() async {
        guard let engine = library.engine else { return }
        let short = name.trimmingCharacters(in: .whitespaces)
        let parent = parentID.flatMap { Deck.find($0, in: decks) }
        let full = parent.map { $0.name + "::" + short } ?? short
        do {
            try await engine.renameDeck(deck.id, to: full)
            await library.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Export

private struct ExportDeckSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let deck: Deck

    @State private var withProgress = true
    @State private var withMedia = true
    @State private var working = false
    @State private var result: String?
    @State private var savedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export “\(deck.shortName)”").font(.title2.weight(.semibold))
            Text("Saves this deck\(deck.children.isEmpty ? "" : " and its \(deck.children.count) sections") as an .apkg file. It opens in Iterum, Anki and other Anki apps, so it's handy for sharing or as a backup.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $withProgress) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include your study progress")
                    Text("Turn off to share a fresh copy, as if no one had studied it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $withMedia) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include pictures and sounds")
                    Text("Turn off for a much smaller file with text only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                if let savedURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                }
                Spacer()
                Button(result == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if result == nil {
                    Button {
                        Task { await export() }
                    } label: {
                        if working { ProgressView().controlSize(.small) } else { Text("Export…") }
                    }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func export() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = deck.shortName.replacingOccurrences(of: "/", with: "-") + ".apkg"
        panel.allowedContentTypes = [.init(filenameExtension: "apkg") ?? .data]
        panel.message = "Choose where to save the deck"
        guard panel.runModal() == .OK, let url = panel.url, let engine = library.engine else { return }
        working = true
        defer { working = false }
        do {
            let notes = try await engine.exportDeck(deck.id, to: url, withProgress: withProgress, withMedia: withMedia)
            savedURL = url
            result = "Exported \(notes) note\(notes == 1 ? "" : "s") to \(url.lastPathComponent)"
        } catch {
            library.notice = error.localizedDescription
        }
    }
}
