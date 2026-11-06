import SwiftUI
import StudyCore

/// Manage card types: rename and reorder fields, edit how each card's front and
/// back are laid out, and change their styling. Anki calls these "note types".
struct CardTypesView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// The card type to open first.
    var startID: Int64? = nil

    @State private var types: [NoteTypeSummary] = []
    @State private var selectedID: Int64?
    @State private var spec: NoteTypeSpec?
    @State private var original: NoteTypeSpec?
    @State private var tab = Tab.fields
    @State private var templateIndex = 0
    @State private var showBack = false
    @State private var error: String?
    @State private var saved = false
    @State private var copying = false
    @State private var copyName = ""
    @State private var confirmDelete = false
    @State private var pendingSwitch: Int64?
    @Environment(\.colorScheme) private var colorScheme

    enum Tab: String, CaseIterable { case fields = "Fields", cards = "Card Layout", styling = "Styling" }

    private var changed: Bool { spec != original }

    /// Changes that make the next sync upload everything once.
    private var structural: Bool {
        guard let spec, let original else { return false }
        return spec.fields.map(\.ord) != original.fields.map(\.ord)
            || spec.templates.map(\.ord) != original.templates.map(\.ord)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                if let spec {
                    editor(spec)
                } else {
                    ContentUnavailableView("Pick a card type", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                footer
            }
        }
        .frame(width: 980, height: 680)
        .task { await loadList(select: startID) }
        .onChange(of: selectedID) { old, new in
            guard let new, new != spec?.id else { return }
            if changed, old != nil {
                pendingSwitch = new
                selectedID = old
            } else {
                Task { await open(new) }
            }
        }
        .confirmationDialog("Discard your changes to “\(original?.name ?? "")”?",
                            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } })) {
            Button("Discard Changes", role: .destructive) {
                if let id = pendingSwitch {
                    spec = original
                    selectedID = id
                    Task { await open(id) }
                }
                pendingSwitch = nil
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete Card Type and Notes", role: .destructive) { Task { await deleteSelected() } }
        } message: {
            Text("This can't be undone, but Iterum makes a backup first.")
        }
        .sheet(isPresented: $copying) { copySheet }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Card types").font(.headline).padding(14)
            ScrollViewReader { proxy in
                List(types, selection: $selectedID) { type in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(type.name).lineLimit(1)
                        Text("\(type.notes.formatted()) note\(type.notes == 1 ? "" : "s")\(type.isCloze ? " · fill in the blank" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(type.id)
                    .id(type.id)
                }
                .listStyle(.sidebar)
                // Bring the open card type into view (it may be far down the list).
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Button {
                    copyName = (types.first { $0.id == selectedID }?.name ?? "Card type") + " copy"
                    copying = true
                } label: { Label("New from This", systemImage: "plus.square.on.square") }
                    .disabled(selectedID == nil)
                    .tip("Make a new card type starting as a copy of the selected one")
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .disabled(selectedID == nil || types.count < 2)
                    .tip("Delete this card type and its notes")
            }
            .buttonStyle(.hoverable)
            .padding(10)
        }
    }

    private var deleteTitle: String {
        let type = types.first { $0.id == selectedID }
        let notes = type?.notes ?? 0
        return notes == 0 ? "Delete “\(type?.name ?? "")”?"
                          : "Delete “\(type?.name ?? "")” and its \(notes.formatted()) note\(notes == 1 ? "" : "s")?"
    }

    private var copySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New card type").font(.title2.weight(.semibold))
            Text("Starts as a copy of “\(types.first { $0.id == selectedID }?.name ?? "")”, with no cards. Change its fields and layout afterwards.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $copyName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { copying = false }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await copySelected() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(copyName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    // MARK: Editor

    private func editor(_ current: NoteTypeSpec) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TextField("Name", text: binding(\.name))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .frame(maxWidth: 360)
                Spacer()
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch tab {
            case .fields: fieldsTab(current)
            case .cards: cardsTab(current)
            case .styling: stylingTab(current)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func binding<T>(_ path: WritableKeyPath<NoteTypeSpec, T>) -> Binding<T> {
        Binding(get: { spec![keyPath: path] }, set: { spec![keyPath: path] = $0 })
    }

    // Fields

    private func fieldsTab(_ current: NoteTypeSpec) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The boxes you fill in when you add a card. Renaming a field keeps its text; card layouts that use it are updated too.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(current.fields.enumerated()), id: \.element.id) { index, field in
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                            TextField("Field name", text: Binding(
                                get: { spec?.fields[safe: index]?.name ?? "" },
                                set: { rename(field: index, to: $0) }))
                                .textFieldStyle(.roundedBorder)
                            if field.ord == nil {
                                Text("New").font(.caption).foregroundStyle(.tint)
                            }
                            Button { move(field: index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0).tip("Move up")
                            Button { move(field: index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == current.fields.count - 1).tip("Move down")
                            Button(role: .destructive) { spec?.fields.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .disabled(current.fields.count <= (current.isCloze ? 1 : 1))
                                .tip(field.ord == nil ? "Remove" : "Remove this field. Its text is deleted from every note when you save.")
                        }
                        .buttonStyle(.hoverable)
                    }
                }
            }
            Button {
                spec?.fields.append(.init(name: uniqueName("Field", existing: current.fields.map(\.name))))
            } label: { Label("Add Field", systemImage: "plus") }
            if let first = current.fields.first, let originalFirst = original?.fields.first, first.ord != originalFirst.ord {
                Label("The first field is used to spot duplicates and sort cards.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rename(field index: Int, to name: String) {
        guard var spec, let old = spec.fields[safe: index]?.name else { return }
        spec.fields[index].name = name
        // Keep the layouts pointing at the field (like Anki does on rename).
        if !old.isEmpty, !name.isEmpty, old != name {
            for t in spec.templates.indices {
                spec.templates[t].front = Self.renameField(in: spec.templates[t].front, from: old, to: name)
                spec.templates[t].back = Self.renameField(in: spec.templates[t].back, from: old, to: name)
            }
        }
        self.spec = spec
    }

    /// Replaces `{{Old}}`, `{{#Old}}`, `{{/Old}}`, `{{^Old}}` and `{{filter:Old}}`.
    static func renameField(in template: String, from old: String, to new: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: old)
        let pattern = #"\{\{([#/^]?)((?:[^}:]+:)*)"# + escaped + #"\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        let replacement = "{{$1$2" + NSRegularExpression.escapedTemplate(for: new) + "}}"
        return regex.stringByReplacingMatches(in: template, range: NSRange(template.startIndex..., in: template),
                                              withTemplate: replacement)
    }

    private func move(field index: Int, by offset: Int) {
        guard var fields = spec?.fields, fields.indices.contains(index + offset) else { return }
        fields.swapAt(index, index + offset)
        spec?.fields = fields
    }

    private func uniqueName(_ base: String, existing: [String]) -> String {
        var n = existing.count + 1
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // Card layout

    private func cardsTab(_ current: NoteTypeSpec) -> some View {
        let index = min(templateIndex, max(0, current.templates.count - 1))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if current.templates.count > 1 || !current.isCloze {
                    Picker("Card", selection: $templateIndex) {
                        ForEach(Array(current.templates.enumerated()), id: \.offset) { i, t in Text(t.name).tag(i) }
                    }
                    .fixedSize()
                    TextField("Card name", text: Binding(get: { spec?.templates[safe: index]?.name ?? "" },
                                                        set: { spec?.templates[index].name = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                Spacer()
                if !current.isCloze {
                    Button {
                        let first = current.fields.first?.name ?? "Front"
                        let second = current.fields.dropFirst().first?.name ?? first
                        spec?.templates.append(.init(name: "Card \(current.templates.count + 1)",
                                                     front: "{{\(second)}}",
                                                     back: "{{FrontSide}}\n\n<hr id=answer>\n\n{{\(first)}}"))
                        templateIndex = (spec?.templates.count ?? 1) - 1
                    } label: { Label("Add Card", systemImage: "plus") }
                    .tip("Each note makes one card per layout, e.g. a reverse card")
                    Button(role: .destructive) {
                        spec?.templates.remove(at: index)
                        templateIndex = max(0, index - 1)
                    } label: { Label("Remove", systemImage: "minus.circle") }
                    .disabled(current.templates.count < 2)
                    .tip("Remove this layout. Cards made from it are deleted when you save.")
                }
            }
            .buttonStyle(.hoverable)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    templateBox("Front", Binding(get: { spec?.templates[safe: index]?.front ?? "" },
                                                 set: { spec?.templates[index].front = $0 }))
                    templateBox("Back", Binding(get: { spec?.templates[safe: index]?.back ?? "" },
                                                set: { spec?.templates[index].back = $0 }))
                    insertBar(current)
                }
                preview(current, template: index)
                    .frame(width: 330)
            }
        }
    }

    private func templateBox(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            TextEditor(text: text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .frame(minHeight: 120)
        }
    }

    private func insertBar(_ current: NoteTypeSpec) -> some View {
        HStack(spacing: 6) {
            Text("Fields:").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(current.fields) { field in
                        Text("{{\(field.name)}}")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .textSelection(.enabled)
                    }
                    Text("{{FrontSide}}")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .tip("On the back: shows the whole front")
                }
            }
        }
        .tip("Copy these into a layout to show a field. {{type:Field}} adds a box to type the answer; {{hint:Field}} hides it behind a click.")
    }

    private func preview(_ current: NoteTypeSpec, template index: Int) -> some View {
        VStack(spacing: 8) {
            Picker("Side", selection: $showBack) {
                Text("Front").tag(false)
                Text("Back").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            let rendered = TemplatePreview.render(current, template: index)
            CardWebView(payload: CardPayload(cardID: -42, side: showBack ? .answer : .question,
                                             html: showBack ? rendered.back : rendered.front, css: current.css,
                                             upcoming: nil, dark: colorScheme == .dark, zoom: 0.8,
                                             appStyle: false, accentHex: AccentChoice.blue.hex),
                        mediaFolder: Library.mediaFolder) { _, _ in }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
            if !rendered.problems.isEmpty {
                Label(rendered.problems.joined(separator: " "), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Preview with sample text").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // Styling

    private func stylingTab(_ current: NoteTypeSpec) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How every card of this type looks (CSS). Shown when Preferences › Card style is “Deck's own”.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                templateBox("Styling", binding(\.css))
            }
            preview(current, template: min(templateIndex, max(0, current.templates.count - 1)))
                .frame(width: 330)
        }
    }

    // MARK: Footer and actions

    private var footer: some View {
        HStack(spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
            } else if structural {
                Label("Adding, removing or reordering fields or cards means your next sync uploads everything once.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary).lineLimit(2)
            } else if saved, !changed {
                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Revert") { spec = original; error = nil }.disabled(!changed)
            Button { Task { await save() } } label: { Label("Save", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent)
                .hoverGlow()
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!changed)
        }
        .font(.callout)
        .padding(12)
    }

    private func loadList(select id: Int64?) async {
        guard let engine = library.engine else { return }
        types = ((try? await engine.noteTypeSummaries()) ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let pick = id ?? selectedID ?? types.first?.id
        if let pick {
            selectedID = pick
            if spec?.id != pick { await open(pick) }
        }
    }

    private func open(_ id: Int64) async {
        guard let engine = library.engine else { return }
        do {
            let loaded = try await engine.noteTypeSpec(id)
            spec = loaded
            original = loaded
            templateIndex = 0
            error = nil
            saved = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let engine = library.engine, let spec else { return }
        let names = spec.fields.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.contains(where: \.isEmpty) { error = "Every field needs a name."; return }
        if Set(names).count != names.count { error = "Two fields have the same name."; return }
        // Anki refuses layouts that name a field that doesn't exist; say which card, plainly.
        for (i, template) in spec.templates.enumerated() {
            let problems = TemplatePreview.render(spec, template: i).problems.filter { $0.hasPrefix("There's no field") }
            if let first = problems.first {
                error = "“\(template.name)”: \(first) Fix the card layout, or add that field."
                return
            }
        }
        if structural { await library.backup(force: true) }
        do {
            try await engine.saveNoteType(spec)
            saved = true
            await open(spec.id)
            await loadList(select: spec.id)
            await library.refresh()
        } catch {
            // Engine messages can carry HTML line breaks.
            self.error = error.localizedDescription
                .replacingOccurrences(of: "<br>", with: " ")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        }
    }

    private func copySelected() async {
        guard let engine = library.engine, let id = selectedID else { return }
        do {
            let newID = try await engine.copyNoteType(id, name: copyName)
            copying = false
            spec = nil
            original = nil
            await loadList(select: newID)
        } catch {
            self.error = error.localizedDescription
            copying = false
        }
    }

    private func deleteSelected() async {
        guard let engine = library.engine, let id = selectedID else { return }
        await library.backup(force: true)
        do {
            try await engine.deleteNoteType(id)
            spec = nil
            original = nil
            selectedID = nil
            await loadList(select: nil)
            await library.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Fills a card layout with sample text, the way Anki's template preview does.
enum TemplatePreview {
    struct Output { var front: String; var back: String; var problems: [String] }

    static func render(_ spec: NoteTypeSpec, template index: Int) -> Output {
        guard let template = spec.templates[safe: index] else { return Output(front: "", back: "", problems: []) }
        var problems: [String] = []
        let names = Set(spec.fields.map(\.name))
        let front = fill(template.front, spec: spec, answer: false, frontSide: "", names: names, problems: &problems)
        let back = fill(template.back, spec: spec, answer: true, frontSide: front, names: names, problems: &problems)
        if !template.front.contains("{{") { problems.append("The front doesn't show any field yet.") }
        return Output(front: front, back: back, problems: Array(Set(problems)).sorted())
    }

    private static func sample(_ field: String, spec: NoteTypeSpec) -> String {
        if spec.isCloze, field == spec.fields.first?.name { return "\u{0}CLOZE\u{0}" }
        return "(\(field))"
    }

    private static func fill(_ text: String, spec: NoteTypeSpec, answer: Bool, frontSide: String,
                             names: Set<String>, problems: inout [String]) -> String {
        var out = text
        // Sections: {{#Field}}…{{/Field}} shows (sample fields aren't empty), {{^Field}}…{{/Field}} hides.
        if let regex = try? NSRegularExpression(pattern: #"\{\{\^([^}]+)\}\}[\s\S]*?\{\{/\1\}\}"#) {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        out = out.replacingOccurrences(of: #"\{\{[#/][^}]+\}\}"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([^}]+)\}\}"#) else { return out }
        let ns = out as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let inner = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let parts = inner.split(separator: ":").map(String.init)
            let field = parts.last ?? inner
            let filters = parts.dropLast()
            switch field {
            case "FrontSide": result += frontSide; continue
            case "Tags": result += "tag1 tag2"; continue
            case "Deck", "Subdeck": result += "Deck name"; continue
            case "Card": result += spec.templates.first?.name ?? "Card 1"; continue
            case "Type", "CardFlag": result += ""; continue
            default: break
            }
            guard names.contains(field) else {
                problems.append("There's no field called “\(field)”.")
                result += "<span style='color:#d33'>{unknown field \(field)}</span>"
                continue
            }
            let value = sample(field, spec: spec)
            if value == "\u{0}CLOZE\u{0}" || filters.contains("cloze") {
                result += answer ? "This is a <span class=cloze>sample</span> blank"
                                 : "This is a <span class=cloze>[...]</span> blank"
            } else if filters.contains("type") {
                result += answer ? "<code>typed answer</code>" : "<input type=text placeholder='type the answer' style='width:80%'>"
            } else if filters.contains("hint") {
                result += "<a href=#>Show \(field)</a>"
            } else {
                result += value
            }
        }
        result += ns.substring(from: last)
        return result
    }
}
