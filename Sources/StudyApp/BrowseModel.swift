import Foundation
import Observation
import StudyCore

/// One card in the Browse table. The table only needs the id; the text is
/// loaded a screenful at a time, so even 50,000 cards scroll smoothly.
///
/// The extra properties exist only so each column has its own sort key.
struct CardRef: Identifiable, Hashable {
    let id: Int64
    var front: Int64 { id }
    var deck: Int64 { id }
    var due: Int64 { id }
    var interval: Int64 { id }
    var ease: Int64 { id }
    var noteType: Int64 { id }
    var cardName: Int64 { id }
    var added: Int64 { id }

    static let sortColumns: [PartialKeyPath<CardRef>: BrowseColumn] = [
        \CardRef.front: .front, \CardRef.deck: .deck, \CardRef.due: .due,
        \CardRef.interval: .interval, \CardRef.ease: .ease,
        \CardRef.noteType: .noteType, \CardRef.cardName: .cardName, \CardRef.added: .added,
    ]
}

/// Quick filters shown as buttons above the table.
enum BrowseFilter: String, CaseIterable, Identifiable {
    case all, due, new, learning, suspended, addedToday, flagged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All cards"
        case .due: "Due today"
        case .new: "New"
        case .learning: "Learning"
        case .suspended: "Suspended"
        case .addedToday: "Added today"
        case .flagged: "Flagged"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .due: "clock"
        case .new: "sparkles"
        case .learning: "arrow.triangle.2.circlepath"
        case .suspended: "pause.circle"
        case .addedToday: "calendar.badge.plus"
        case .flagged: "flag"
        }
    }

    /// The Anki search this button stands for.
    var search: String {
        switch self {
        case .all: ""
        case .due: "is:due"
        case .new: "is:new"
        case .learning: "is:learn"
        case .suspended: "is:suspended"
        case .addedToday: "added:1"
        case .flagged: "-flag:0"
        }
    }
}

/// What Browse is showing: the search, the matching cards, and the
/// selection. Shared with the toolbar search box, so typing there
/// searches from anywhere in the app.
@MainActor
@Observable
final class BrowseModel {
    var query = ""
    /// A fixed search this Browse is limited to (e.g. one day's reviews), on top of the rest.
    var baseSearch = ""
    var filter: BrowseFilter = .all
    /// With the Flagged filter: one colour (1–7), or 0 for any flag.
    var flagColor = 0
    /// One row per note instead of per card.
    var notesMode = false
    /// Limit to one deck and its sections; `nil` = every deck.
    var deckID: Int64?
    var sortOrder = [KeyPathComparator(\CardRef.added, order: .reverse)]
    var selection: Set<Int64> = []

    private(set) var cards: [CardRef] = []
    private(set) var rows: [Int64: BrowseRow] = [:]
    private(set) var error: String?
    private(set) var searching = false
    /// The last change made here, offered as an Undo button.
    private(set) var undoTitle: String?

    private var position: [Int64: Int] = [:]
    private var loadingPages: Set<Int> = []
    private var generation = 0
    private static let pageSize = 60

    /// The whole search: filter button, deck, then whatever was typed.
    func searchText(decks: [Deck]) -> String {
        var parts: [String] = []
        if !baseSearch.isEmpty { parts.append(baseSearch) }
        if filter == .flagged, flagColor > 0 {
            parts.append("flag:\(flagColor)")
        } else if !filter.search.isEmpty {
            parts.append(filter.search)
        }
        if let deckID, let deck = Deck.find(deckID, in: decks) {
            parts.append("did:" + deck.idsIncludingSections.map(String.init).joined(separator: ","))
        }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append("(\(typed))") }
        return parts.joined(separator: " ")
    }

    /// `force`: reload the rows even if the same cards come back (e.g. after Edit › Undo).
    func search(engine: Engine, decks: [Deck], force: Bool = false) async {
        generation += 1
        let mine = generation
        let sort = sortOrder.first
        let column = sort.flatMap { CardRef.sortColumns[$0.keyPath] }
        searching = true
        defer { if mine == generation { searching = false } }
        do {
            let ids = try await engine.search(searchText(decks: decks), sort: column,
                                              reverse: sort?.order == .reverse, notes: notesMode)
            guard mine == generation else { return }
            error = nil
            // Same results as before (e.g. the counts refreshed): keep the rows already shown.
            if !force, ids == cards.map(\.id) { return }
            cards = ids.map(CardRef.init)
            position = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            rows = [:]
            loadingPages = []
            selection = selection.filter { position[$0] != nil }
            // Load the first screenfuls now, rather than waiting for rows to ask
            // (rows already on screen don't ask again, which left them blank).
            for page in 0..<min(2, (ids.count + Self.pageSize - 1) / Self.pageSize) {
                load(page: page, engine: engine)
            }
        } catch {
            guard mine == generation else { return }
            self.error = error.localizedDescription
        }
    }

    /// Called as rows scroll into view: loads that row's page if needed.
    func need(_ id: Int64, engine: Engine) {
        guard rows[id] == nil, let index = position[id] else { return }
        load(page: index / Self.pageSize, engine: engine)
    }

    private func load(page: Int, engine: Engine) {
        guard !loadingPages.contains(page) else { return }
        loadingPages.insert(page)
        let start = page * Self.pageSize
        guard start < cards.count else { return }
        let ids = cards[start..<min(cards.count, start + Self.pageSize)].map(\.id)
        Task {
            guard let loaded = try? await engine.browseRows(ids) else {
                // Failed: let it be asked for again.
                loadingPages.remove(page)
                return
            }
            // A card's row is the same whichever search found it, so keep it
            // as long as the card is still in the results.
            for row in loaded where position[row.id] != nil { rows[row.id] = row }
        }
    }

    /// Reloads rows after they changed; drops ones that were deleted.
    func reload(_ ids: [Int64], engine: Engine) async {
        guard let loaded = try? await engine.browseRows(ids) else { return }
        let alive = Set(loaded.map(\.id))
        for row in loaded { rows[row.id] = row }
        let gone = Set(ids).subtracting(alive)
        if !gone.isEmpty {
            cards.removeAll { gone.contains($0.id) }
            position = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($1.id, $0) })
            selection.subtract(gone)
            for id in gone { rows[id] = nil }
            // Pages shifted; let them load again as needed.
            loadingPages = []
        }
    }

    /// A search is about to run (after the typing pause), so don't say "nothing found" yet.
    func markPending() { searching = true }

    func didChange(_ title: String) { undoTitle = title }
    func clearUndo() { undoTitle = nil }

    /// The selected cards, in table order.
    var selectedIDs: [Int64] {
        selection.sorted { (position[$0] ?? 0) < (position[$1] ?? 0) }
    }

    var allSelectedSuspended: Bool {
        !selection.isEmpty && selection.allSatisfy { rows[$0]?.state == "suspended" }
    }
}
