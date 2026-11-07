import SwiftUI
import StudyCore

/// The Browse tools that need a sheet.
enum BrowseSheet: String, Identifiable {
    case addTags, removeTags, setDue, reposition, findReplace, changeType, duplicates, manageTags
    var id: String { rawValue }
}

struct BrowseToolSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let which: BrowseSheet
    /// The selected cards (in Notes view: the first card of each selected note).
    let cards: [Int64]
    /// The search behind what's shown now.
    let scope: String
    let notesMode: Bool
    /// Done: the Undo title, and whether the whole list should be searched again.
    let done: (String, Bool) -> Void
    /// Shows a search in Browse (for duplicates).
    let show: (String) -> Void

    var body: some View {
        switch which {
        case .addTags, .removeTags:
            TagsSheet(adding: which == .addTags, cards: cards, done: done)
        case .setDue:
            SetDueSheet(count: cards.count) { days in
                Task { await apply("Set Due Date") { try await $0.setDueDate($1, days: days) } }
            }
        case .reposition:
            RepositionSheet(count: cards.count) { start, shift in
                Task { await apply("Reposition") { try await $0.reposition($1, start: start, shiftOthers: shift) } }
            }
        case .findReplace:
            FindReplaceSheet(cards: cards, scope: scope, done: done)
        case .changeType:
            ChangeTypeSheet(cards: cards, done: done)
        case .duplicates:
            DuplicatesSheet(scope: scope, show: show, done: done)
        case .manageTags:
            TagManagerSheet(show: show, done: done)
        }
    }

    /// Card-level changes: in Notes view they apply to every card of each note.
    private func apply(_ title: String, _ work: (Engine, [Int64]) async throws -> Void) async {
        guard let engine = library.engine else { return }
        var ids = cards
        if notesMode, let rows = try? await engine.browseRows(cards) {
            let notes = rows.map { String($0.noteID) }.joined(separator: ",")
            ids = (try? await engine.search("nid:" + notes)) ?? cards
        }
        do {
            try await work(engine, ids)
            done(title, false)
        } catch {
            library.notice = error.localizedDescription
        }
    }
}

// MARK: - Tags

private struct TagsSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let adding: Bool
    let cards: [Int64]
    let done: (String, Bool) -> Void
    @State private var text = ""
    @State private var all: [String] = []
    @State private var error: String?

    private var typedWord: String { String(text.split(separator: " ", omittingEmptySubsequences: false).last ?? "") }

    private var suggestions: [String] {
        let word = typedWord.lowercased()
        let chosen = Set(text.lowercased().split(separator: " ").map(String.init))
        return all.filter { tag in
            !chosen.contains(tag.lowercased()) && (word.isEmpty || tag.lowercased().contains(word))
        }
        .prefix(14).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(adding ? "Add tags" : "Remove tags", systemImage: adding ? "tag" : "tag.slash")
                .font(.title2.weight(.semibold))
            Text(adding ? "Tags help you find and study groups of cards, e.g. “cardio week3”. Separate tags with spaces."
                        : "Removes these tags from the selected notes. Other tags stay.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("e.g. cardio week3", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await save() } }
            if !suggestions.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(suggestions, id: \.self) { tag in
                        Button(tag) { pick(tag) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(adding ? "Add" : "Remove") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .task { all = (try? await library.engine?.allTags()) ?? [] }
    }

    private func pick(_ tag: String) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words.isEmpty { words = [""] }
        words[words.count - 1] = tag
        text = words.joined(separator: " ") + " "
    }

    private func save() async {
        guard let engine = library.engine else { return }
        let tags = text.trimmingCharacters(in: .whitespaces)
        guard !tags.isEmpty else { return }
        do {
            if adding { try await engine.addTags(tags, toCards: cards) } else { try await engine.removeTags(tags, fromCards: cards) }
            dismiss()
            done(adding ? "Add Tags" : "Remove Tags", false)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Reposition

private struct RepositionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let onSet: (Int, Bool) -> Void
    @State private var start = 1
    @State private var shift = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Reposition new cards", systemImage: "list.number").font(.title2.weight(.semibold))
            Text("Changes the order new cards are shown in. Only cards you haven't studied yet are moved.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Start at position")
                TextField("1", value: $start, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                Stepper("", value: $start, in: 1...1_000_000).labelsHidden()
            }
            Toggle("Move other new cards back to make room", isOn: $shift)
            Text(start == 1 ? "Position 1 means these \(count == 1 ? "card comes" : "cards come") up next." : "")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reposition") {
                    onSet(max(1, start), shift)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .hoverGlow()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Find & replace

private struct FindReplaceSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let cards: [Int64]
    let scope: String
    let done: (String, Bool) -> Void

    @State private var find = ""
    @State private var replace = ""
    @State private var field = ""
    @State private var fields: [String] = []
    @State private var regex = false
    @State private var matchCase = false
    @State private var onlySelected = true
    @State private var result: String?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Find & replace", systemImage: "text.magnifyingglass").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Find")
                    TextField("e.g. adrenaline", text: $find).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Replace with")
                    TextField("e.g. epinephrine (leave empty to delete)", text: $replace).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("In")
                    Picker("In", selection: $field) {
                        Text("All fields").tag("")
                        ForEach(fields, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Picker("Notes", selection: $onlySelected) {
                Text(cards.count == 1 ? "The selected card" : "The \(cards.count) selected cards").tag(true)
                Text("Everything shown in Browse").tag(false)
            }
            .pickerStyle(.radioGroup)
            .disabled(cards.isEmpty)
            HStack(spacing: 18) {
                Toggle("Match case", isOn: $matchCase)
                Toggle("Regular expression (for experts)", isOn: $regex)
            }
            if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace") { Task { await run() } }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                    .keyboardShortcut(.defaultAction)
                    .disabled(find.isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task {
            onlySelected = !cards.isEmpty
            let types = (try? await library.engine?.noteTypes()) ?? []
            var seen = Set<String>()
            fields = types.flatMap(\.fields).filter { seen.insert($0).inserted }
        }
    }

    private func run() async {
        guard let engine = library.engine else { return }
        working = true
        defer { working = false }
        do {
            let ids = onlySelected ? cards : try await engine.search(scope)
            let changed = try await engine.findAndReplace(cards: ids, find: find, replace: replace,
                                                          field: field.isEmpty ? nil : field,
                                                          regex: regex, matchCase: matchCase)
            error = nil
            result = changed == 0 ? "Nothing matched." : "Changed \(changed) note\(changed == 1 ? "" : "s")."
            if changed > 0 { done("Find & Replace", true) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Change card type

private struct ChangeTypeSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let cards: [Int64]
    let done: (String, Bool) -> Void
    @State private var types: [NoteType] = []
    @State private var target: NoteType?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Change card type", systemImage: "rectangle.2.swap").font(.title2.weight(.semibold))
            Text("Moves the selected notes to another card type. Fields with the same name keep their text; the rest are matched in order.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("New type", selection: $target) {
                Text("Choose…").tag(NoteType?.none)
                ForEach(types) { Text($0.name).tag(Optional($0)) }
            }
            .frame(maxWidth: 360)
            if let target {
                Text("Fields: " + target.fields.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Label("If you sync, the next sync will need to upload your whole collection once.",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change") { Task { await run() } }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { types = (try? await library.engine?.noteTypes()) ?? [] }
    }

    private func run() async {
        guard let engine = library.engine, let target else { return }
        do {
            try await engine.changeNoteType(ofCards: cards, to: target.id)
            dismiss()
            done("Change Card Type", true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Duplicates

private struct DuplicatesSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let scope: String
    let show: (String) -> Void
    let done: (String, Bool) -> Void
    @State private var groups: [DuplicateGroup]?
    @State private var error: String?
    @State private var tagged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Duplicates", systemImage: "square.on.square").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Text("Notes with the same front (ignoring formatting and capitals), among the cards shown in Browse.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Divider()
            Group {
                if let groups, groups.isEmpty {
                    ContentUnavailableView("No duplicates", systemImage: "checkmark.seal",
                                           description: Text("Every note here has a different front."))
                } else if let groups {
                    List(groups) { group in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.text).lineLimit(2)
                                Text("\(group.noteIDs.count) notes · \(group.noteType)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show") {
                                show("nid:" + group.noteIDs.map(String.init).joined(separator: ","))
                                dismiss()
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } else if let error {
                    ContentUnavailableView("Couldn't check", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("Looking for duplicates…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            if let groups, !groups.isEmpty {
                Divider()
                HStack {
                    Text("\(groups.count) set\(groups.count == 1 ? "" : "s") of duplicates")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(tagged ? "Tagged “duplicate”" : "Tag All as “duplicate”") { Task { await tagAll(groups) } }
                        .disabled(tagged)
                        .tip("Adds the tag “duplicate” so you can find and tidy them later")
                }
                .padding(14)
            }
        }
        .frame(width: 560, height: 520)
        .task {
            do { groups = try await library.engine?.findDuplicates(in: scope) } catch { self.error = error.localizedDescription }
        }
    }

    private func tagAll(_ groups: [DuplicateGroup]) async {
        guard let engine = library.engine else { return }
        do {
            try await engine.addTags("duplicate", toCards: groups.flatMap(\.cardIDs))
            tagged = true
            done("Tag Duplicates", false)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
