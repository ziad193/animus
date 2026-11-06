import SwiftUI
import StudyCore

/// The decks you picked most recently, newest first, so they're one click away.
enum RecentDecks {
    private static let key = "recentDecks"
    private static let limit = 6

    static func load() -> [Int64] {
        (AppDefaults.current.array(forKey: key) as? [NSNumber])?.map(\.int64Value) ?? []
    }

    static func use(_ id: Int64) {
        var list = load().filter { $0 != id }
        list.insert(id, at: 0)
        AppDefaults.current.set(Array(list.prefix(limit)).map(NSNumber.init(value:)), forKey: key)
    }
}

extension Deck {
    /// Every deck, parents before their sections, in the usual order.
    static func flatten(_ decks: [Deck]) -> [Deck] {
        decks.flatMap { [$0] + flatten($0.children) }
    }

    /// This deck's id and all of its sections' ids.
    var idsIncludingSections: [Int64] {
        [id] + children.flatMap(\.idsIncludingSections)
    }

    /// "BB › Week 1 › Basal Ganglia".
    var displayPath: String { path.joined(separator: " › ") }
}

/// A button showing the chosen deck. Clicking it opens a list you can type
/// into to find a deck, instead of scrolling a long menu.
struct DeckPickerButton: View {
    let decks: [Deck]
    @Binding var selection: Int64?
    /// Shown when nothing is chosen (e.g. "All decks" in Browse).
    var emptyTitle = "Choose a deck"
    /// Offer a choice that clears the selection ("All decks", "No deck"…).
    var allowsAll = false
    /// Makes a new deck from typed text and returns its id.
    var create: ((String) async -> Int64?)?

    @State private var showing = false

    private var chosen: Deck? { selection.flatMap { Deck.find($0, in: decks) } }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 10) {
                if let chosen {
                    DeckIcon(deck: chosen, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        if chosen.path.count > 1 {
                            Text(chosen.path.dropLast().joined(separator: " › "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Text(chosen.shortName).font(.body.weight(.medium)).lineLimit(1)
                    }
                } else {
                    Image(systemName: "rectangle.stack")
                        .frame(width: 26)
                        .foregroundStyle(.secondary)
                    Text(emptyTitle).font(.body.weight(.medium))
                }
                Spacer(minLength: 6)
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 240, maxWidth: 380, minHeight: 40, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.01)
        .tip("Choose a deck — type to search")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DeckChooser(decks: decks, selection: selection, allowsAll: allowsAll, allTitle: emptyTitle, create: create) { id in
                selection = id
                if let id { RecentDecks.use(id) }
                showing = false
            }
        }
    }
}

/// Recently used decks as small buttons, shown next to the picker.
struct RecentDeckChips: View {
    let decks: [Deck]
    @Binding var selection: Int64?
    /// Changes whenever a deck is picked, so the list refreshes.
    var refresh: Int64? = nil

    @State private var recent: [Deck] = []
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue

    var body: some View {
        HStack(spacing: 6) {
            ForEach(recent) { deck in
                let isOn = deck.id == selection
                Button {
                    selection = deck.id
                    RecentDecks.use(deck.id)
                } label: {
                    Text(deck.shortName)
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(isOn ? Color.white : .primary)
                        .background(Capsule().fill(isOn ? AnyShapeStyle(accent.color) : AnyShapeStyle(Color.primary.opacity(0.06))))
                }
                .buttonStyle(.plain)
                .hoverLift(scale: 1.05)
                .tip(deck.displayPath)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: selection) { reload() }
        .onChange(of: decks.count) { reload() }
    }

    private func reload() {
        recent = RecentDecks.load().compactMap { Deck.find($0, in: decks) }.prefix(4).map { $0 }
    }
}

/// The popover list: a search box, recent decks, then every deck.
/// Arrow keys move, Return picks.
struct DeckChooser: View {
    let decks: [Deck]
    let selection: Int64?
    var allowsAll = false
    var allTitle = "All decks"
    var create: ((String) async -> Int64?)?
    let pick: (Int64?) -> Void

    @State private var text = ""
    @State private var highlighted = 0
    @State private var creating = false
    @FocusState private var focused: Bool

    private enum Choice: Hashable {
        case all
        case deck(Deck, recent: Bool)
        case create(String)
    }

    private var all: [Deck] { Deck.flatten(decks) }

    /// Every word typed must appear somewhere in the deck's full name.
    private var matches: [Deck] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all
            .filter { deck in
                let name = deck.name.lowercased()
                return words.allSatisfy { name.contains($0) }
            }
            // Decks whose own name matches come before ones matched by a parent.
            .sorted { a, b in
                let aLeaf = words.allSatisfy { a.shortName.lowercased().contains($0) }
                let bLeaf = words.allSatisfy { b.shortName.lowercased().contains($0) }
                return aLeaf && !bLeaf
            }
    }

    private var choices: [Choice] {
        var list: [Choice] = []
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if allowsAll { list.append(.all) }
            let recent = RecentDecks.load().compactMap { Deck.find($0, in: decks) }
            list += recent.map { .deck($0, recent: true) }
            list += all.map { .deck($0, recent: false) }
        } else {
            list += matches.map { .deck($0, recent: false) }
            let exact = all.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.displayPath.caseInsensitiveCompare(trimmed) == .orderedSame }
            if create != nil, !exact { list.append(.create(trimmed)) }
        }
        return list
    }

    var body: some View {
        let list = choices
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search decks", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { choose(list, at: highlighted) }
                    .onKeyPress(.downArrow) { move(1, in: list); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let firstAll = list.firstIndex { if case .deck(_, false) = $0 { true } else { false } }
                        let firstRecent = list.firstIndex { if case .deck(_, true) = $0 { true } else { false } }
                        ForEach(Array(list.enumerated()), id: \.offset) { index, choice in
                            if text.isEmpty, index == firstRecent { header("Recent") }
                            if text.isEmpty, index == firstAll { header("All decks") }
                            row(choice, highlighted: index == highlighted)
                                .id(index)
                                .onHover { if $0 { highlighted = index } }
                                .onTapGesture { choose(list, at: index) }
                        }
                        if list.isEmpty {
                            Text("No decks match “\(text)”")
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
        }
        .frame(width: 400, height: 440)
        .onAppear { focused = true }
        .onChange(of: text) { highlighted = 0 }
        .disabled(creating)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func row(_ choice: Choice, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            switch choice {
            case .all:
                Image(systemName: "square.stack.3d.up").frame(width: 22)
                Text(allTitle).font(.body.weight(.medium))
                Spacer()
                if selection == nil { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            case .deck(let deck, let recent):
                // In the full list, indent sections under their parents.
                if !recent, text.isEmpty {
                    Color.clear.frame(width: CGFloat(max(0, deck.path.count - 1)) * 16, height: 1)
                }
                DeckIcon(deck: deck, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(deck.shortName).lineLimit(1)
                    if (recent || !text.isEmpty), deck.path.count > 1 {
                        Text(deck.path.dropLast().joined(separator: " › "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                Text("\(deck.totalCards)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if deck.id == selection { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            case .create(let name):
                Image(systemName: "plus.circle.fill").frame(width: 22).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Create “\(name.replacingOccurrences(of: "::", with: " › "))”")
                    Text("Tip: use :: for a section, e.g. Biology::Week 1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(highlighted ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
    }

    private func move(_ step: Int, in list: [Choice]) {
        guard !list.isEmpty else { return }
        highlighted = min(max(0, highlighted + step), list.count - 1)
    }

    private func choose(_ list: [Choice], at index: Int) {
        guard list.indices.contains(index) else { return }
        switch list[index] {
        case .all:
            pick(nil)
        case .deck(let deck, _):
            pick(deck.id)
        case .create(let name):
            guard let create else { return }
            creating = true
            Task {
                // Accept "Biology › Week 1" as well as "Biology::Week 1".
                let native = name.replacingOccurrences(of: " › ", with: "::")
                if let id = await create(native) { pick(id) }
                creating = false
            }
        }
    }
}
