import CStudyEngine
import Foundation

/// A deck with today's due counts, as returned by Anki's engine.
public struct Deck: Decodable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let level: UInt32
    public let newCount: UInt32
    public let learnCount: UInt32
    public let reviewCount: UInt32
    public let totalCards: UInt32
    public let filtered: Bool
    public let collapsed: Bool
    public let children: [Deck]

    /// Cards waiting today, across new, learning and review.
    public var dueToday: UInt32 { newCount + learnCount + reviewCount }

    /// `nil` when there are no sub-decks, so SwiftUI's outline list
    /// doesn't show an expand arrow on every row.
    public var subdecks: [Deck]? { children.isEmpty ? nil : children }

    enum CodingKeys: String, CodingKey {
        case id, name, level, filtered, collapsed, children
        case newCount = "new_count"
        case learnCount = "learn_count"
        case reviewCount = "review_count"
        case totalCards = "total_cards"
    }
}

/// What to study next: a card, or nothing left today.
public struct StudyState: Decodable {
    public let card: StudyCard?
    public let counts: Counts

    public struct Counts: Decodable, Equatable {
        public let new: Int
        public let learn: Int
        public let review: Int
    }
}

public struct StudyCard: Decodable, Identifiable, Equatable {
    public let id: Int64
    public let question: String
    public let answer: String
    public let css: String
    public let questionAudio: [String]
    public let answerAudio: [String]
    /// Next interval for Again, Hard, Good, Easy, e.g. "<1m", "10m", "1d".
    public let intervals: [String]
    /// Question of the next card in the queue, used to load its images early.
    public let upcoming: String?
    /// Raw fields for image occlusion cards, which the app draws natively.
    public let occlusion: OcclusionFields?
    /// 0 = no flag, 1–7 = red, orange, green, blue, pink, turquoise, purple.
    public let flag: Int
    /// The note is tagged "marked".
    public let marked: Bool

    enum CodingKeys: String, CodingKey {
        case id, question, answer, css, intervals, upcoming, occlusion, flag, marked
        case questionAudio = "question_audio"
        case answerAudio = "answer_audio"
    }
}

/// The note behind an image occlusion card.
public struct OcclusionFields: Decodable, Equatable {
    /// "enhanced" (old Image Occlusion Enhanced add-on) or "builtin" (Anki's own).
    public let kind: String
    /// Which card of the note this is (1-based).
    public let ordinal: Int
    public let fields: [String: String]
}

/// Study history for the stats page.
public struct Stats: Decodable {
    /// Reviews per day, keyed by days from today (0 = today, -1 = yesterday).
    public let reviewsPerDay: [Int: Int]
    public let secondsPerDay: [Int: Int]
    /// Per day: new cards learned, forgotten cards relearned, and reviews.
    public let breakdownPerDay: [Int: [Int]]
    public let todayReviews: Int
    public let todaySeconds: Int
    public let todayCorrect: Int
    public let cardsNew: Int
    public let cardsLearning: Int
    public let cardsYoung: Int
    public let cardsMature: Int
    public let cardsSuspended: Int
    /// Share of reviews passed in the last month (0…1).
    public let retentionMonth: Double?
    /// Cards coming due on each of the next 30 days.
    public let dueAhead: [Int: Int]
    /// Review cards by interval in days.
    public let intervals: [Int: Int]
    /// By hour of day (0–23), last 3 months: (answers, correct).
    public let hours: [(total: Int, correct: Int)]
    /// Again, Hard, Good, Easy presses in the last 3 months.
    public let buttonsLearning: [Int]
    public let buttonsYoung: [Int]
    public let buttonsMature: [Int]
    /// Cards added per day (days from today, ≤ 0).
    public let addedPerDay: [Int: Int]
    /// Today, yesterday, week, month, year, all time: (young passed, young failed, mature passed, mature failed).
    public let trueRetention: [[Int]]
    public let fsrs: Bool
    public let averageRetrievability: Double?

    enum CodingKeys: String, CodingKey {
        case reviewsPerDay = "reviews_per_day", secondsPerDay = "seconds_per_day"
        case breakdownPerDay = "breakdown_per_day"
        case todayReviews = "today_reviews", todaySeconds = "today_seconds", todayCorrect = "today_correct"
        case cardsNew = "cards_new", cardsLearning = "cards_learning", cardsYoung = "cards_young"
        case cardsMature = "cards_mature", cardsSuspended = "cards_suspended"
        case retentionMonth = "retention_month", dueAhead = "due_ahead"
        case intervals, hours, fsrs
        case buttonsLearning = "buttons_learning", buttonsYoung = "buttons_young", buttonsMature = "buttons_mature"
        case addedPerDay = "added_per_day", trueRetention = "true_retention"
        case averageRetrievability = "average_retrievability"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // JSON object keys are strings; turn them back into day numbers.
        func days(_ key: CodingKeys) throws -> [Int: Int] {
            let raw = try c.decode([String: Int].self, forKey: key)
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        }
        reviewsPerDay = try days(.reviewsPerDay)
        secondsPerDay = try days(.secondsPerDay)
        dueAhead = try days(.dueAhead)
        let breakdown = try c.decodeIfPresent([String: [Int]].self, forKey: .breakdownPerDay) ?? [:]
        breakdownPerDay = Dictionary(uniqueKeysWithValues: breakdown.compactMap { k, v in Int(k).map { ($0, v) } })
        todayReviews = try c.decode(Int.self, forKey: .todayReviews)
        todaySeconds = try c.decode(Int.self, forKey: .todaySeconds)
        todayCorrect = try c.decode(Int.self, forKey: .todayCorrect)
        cardsNew = try c.decode(Int.self, forKey: .cardsNew)
        cardsLearning = try c.decode(Int.self, forKey: .cardsLearning)
        cardsYoung = try c.decode(Int.self, forKey: .cardsYoung)
        cardsMature = try c.decode(Int.self, forKey: .cardsMature)
        cardsSuspended = try c.decode(Int.self, forKey: .cardsSuspended)
        retentionMonth = try c.decodeIfPresent(Double.self, forKey: .retentionMonth)
        func optionalDays(_ key: CodingKeys) -> [Int: Int] {
            let raw = (try? c.decodeIfPresent([String: Int].self, forKey: key)) ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        }
        intervals = optionalDays(.intervals)
        addedPerDay = optionalDays(.addedPerDay)
        hours = ((try? c.decodeIfPresent([[Int]].self, forKey: .hours)) ?? [])
            .map { (total: $0.first ?? 0, correct: $0.count > 1 ? $0[1] : 0) }
        buttonsLearning = (try? c.decodeIfPresent([Int].self, forKey: .buttonsLearning)) ?? []
        buttonsYoung = (try? c.decodeIfPresent([Int].self, forKey: .buttonsYoung)) ?? []
        buttonsMature = (try? c.decodeIfPresent([Int].self, forKey: .buttonsMature)) ?? []
        trueRetention = (try? c.decodeIfPresent([[Int]].self, forKey: .trueRetention)) ?? []
        fsrs = (try? c.decodeIfPresent(Bool.self, forKey: .fsrs)) ?? false
        averageRetrievability = try? c.decodeIfPresent(Double.self, forKey: .averageRetrievability)
    }
}

/// A card type (note type) the student can add cards with.
public struct NoteType: Decodable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    /// "basic", "reversed", "optional_reversed", "typing", "cloze", "occlusion" or "other".
    public let kind: String
    public let isCloze: Bool
    public let fields: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, kind, fields
        case isCloze = "is_cloze"
    }
}

public struct ImportResult: Decodable {
    public let new: Int
    public let updated: Int
    public let duplicate: Int
}

/// One row in the Browse table (one card).
public struct BrowseRow: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let noteID: Int64
    /// Text for each column, in `BrowseColumn.allCases` order.
    public let cells: [String]
    /// "new", "learning", "review", "suspended" or "buried".
    public let state: String
    public let flag: Int
    public let marked: Bool

    enum CodingKeys: String, CodingKey {
        case id, cells, state, flag, marked
        case noteID = "note_id"
    }

    public func text(_ column: BrowseColumn) -> String {
        let index = BrowseColumn.allCases.firstIndex(of: column)!
        return index < cells.count ? cells[index] : ""
    }
}

/// The Browse table's columns. Raw values are Anki's own column names,
/// so they can be passed straight to the engine for sorting.
public enum BrowseColumn: String, CaseIterable, Identifiable, Sendable {
    case front = "noteFld"
    case back = "answer"
    case deck = "deck"
    case due = "cardDue"
    case interval = "cardIvl"
    case ease = "cardEase"
    case noteType = "note"
    case cardName = "template"
    case added = "noteCrt"

    public var id: String { rawValue }
    /// Anki can't sort by the rendered answer.
    public var sortable: Bool { self != .back }
}

public struct MediaCheck: Decodable, Sendable {
    public let unused: [String]
    public let missing: [String]
    public let missingNotes: Int
    public let missingNoteIDs: [Int64]
    public let renamed: Int
    public let trashCount: Int
    public let trashBytes: Int
    enum CodingKeys: String, CodingKey {
        case unused, missing, renamed
        case missingNotes = "missing_notes", trashCount = "trash_count", trashBytes = "trash_bytes"
        case missingNoteIDs = "missing_note_ids"
    }
}

public struct CSVPreview: Decodable, Sendable {
    public let preview: [[String]]
    public let columnLabels: [String]
    public let delimiter: String
    public let noteTypeID: Int64
    /// For each field of the card type, the column it comes from (1-based; 0 = none).
    public let fieldColumns: [Int]
    public let isHTML: Bool
    enum CodingKeys: String, CodingKey {
        case preview, delimiter
        case columnLabels = "column_labels", noteTypeID = "notetype_id"
        case fieldColumns = "field_columns", isHTML = "is_html"
    }
}

public struct CSVImportResult: Decodable, Sendable {
    public let added: Int
    public let updated: Int
    public let skipped: Int
    public let problems: Int
}

/// Notes that share the same first field.
public struct DuplicateGroup: Decodable, Sendable, Identifiable, Hashable {
    public var id: String { noteType + "|" + text }
    public let text: String
    public let noteType: String
    public let cardIDs: [Int64]
    public let noteIDs: [Int64]
    enum CodingKeys: String, CodingKey {
        case text
        case noteType = "note_type", cardIDs = "card_ids", noteIDs = "note_ids"
    }
}

/// Everything about one card, for the Card Info sheet.
public struct CardInfo: Decodable, Sendable {
    public struct Review: Decodable, Sendable, Identifiable {
        public var id: Int64 { time }
        public let time: Int64
        public let kind: String
        public let button: Int
        public let intervalDays: Double
        public let seconds: Double
        enum CodingKeys: String, CodingKey {
            case time, kind, button, seconds
            case intervalDays = "interval_days"
        }
    }
    public let deck: String
    public let noteType: String
    public let cardType: String
    public let added: Int64
    public let firstReview: Int64?
    public let latestReview: Int64?
    public let dueDate: Int64?
    public let duePosition: Int?
    public let intervalDays: Int
    public let easePercent: Int
    public let reviews: Int
    public let lapses: Int
    public let averageSeconds: Double
    public let totalSeconds: Double
    public let retrievability: Double?
    public let stabilityDays: Double?
    public let difficulty: Double?
    public let history: [Review]

    enum CodingKeys: String, CodingKey {
        case deck, added, reviews, lapses, retrievability, difficulty, history
        case noteType = "note_type", cardType = "card_type"
        case firstReview = "first_review", latestReview = "latest_review"
        case dueDate = "due_date", duePosition = "due_position"
        case intervalDays = "interval_days", easePercent = "ease_percent"
        case averageSeconds = "average_seconds", totalSeconds = "total_seconds"
        case stabilityDays = "stability_days"
    }
}

/// A note opened for editing in Browse.
public struct EditableNote: Decodable, Sendable, Equatable {
    public let noteID: Int64
    public let cardID: Int64
    public let deckID: Int64
    public let noteTypeID: Int64
    public let noteTypeName: String
    public let isCloze: Bool
    public let fieldNames: [String]
    public var fields: [String]
    public var tags: [String]
    public let question: String
    public let answer: String
    public let css: String

    enum CodingKeys: String, CodingKey {
        case fields, tags, question, answer, css
        case noteID = "note_id", cardID = "card_id", deckID = "deck_id"
        case noteTypeID = "notetype_id", noteTypeName = "notetype_name"
        case isCloze = "is_cloze", fieldNames = "field_names"
    }
}

/// A deck's study settings, as on Anki's deck Options screen.
public struct DeckSettings: Codable, Equatable, Sendable {
    public var newPerDay: Int
    public var reviewsPerDay: Int
    /// Minutes, e.g. [1, 10].
    public var learnSteps: [Double]
    public var relearnSteps: [Double]
    /// Days.
    public var graduatingIntervalGood: Int
    public var graduatingIntervalEasy: Int
    public var maximumReviewInterval: Int
    public var initialEase: Double
    public var leechThreshold: Int
    public var leechSuspend: Bool
    public var buryNew: Bool
    public var buryReviews: Bool
    public var buryInterdayLearning: Bool
    public var desiredRetention: Double
    public var newRandom: Bool

    enum CodingKeys: String, CodingKey {
        case newPerDay = "new_per_day", reviewsPerDay = "reviews_per_day"
        case learnSteps = "learn_steps", relearnSteps = "relearn_steps"
        case graduatingIntervalGood = "graduating_interval_good", graduatingIntervalEasy = "graduating_interval_easy"
        case maximumReviewInterval = "maximum_review_interval", initialEase = "initial_ease"
        case leechThreshold = "leech_threshold", leechSuspend = "leech_suspend"
        case buryNew = "bury_new", buryReviews = "bury_reviews", buryInterdayLearning = "bury_interday_learning"
        case desiredRetention = "desired_retention", newRandom = "new_random"
    }
}

/// A named group of settings that several decks can share.
public struct DeckPreset: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let useCount: Int
    enum CodingKeys: String, CodingKey { case id, name, useCount = "use_count" }
}

public struct DeckOptions: Decodable, Sendable {
    public let deckName: String
    public let presetID: Int64
    public let presets: [DeckPreset]
    public let fsrs: Bool
    public let settings: DeckSettings
    enum CodingKeys: String, CodingKey {
        case presets, fsrs, settings
        case deckName = "deck_name", presetID = "preset_id"
    }
}

/// Collection-wide preferences (Anki's Preferences window).
public struct CollectionPreferences: Codable, Equatable, Sendable {
    public var nextDayStartsAt: Int
    public var learnAheadMinutes: Int
    /// "mix", "reviews_first" or "new_first".
    public var newReviewMix: String
    public var dayLearnFirst: Bool
    public var showIntervalsOnButtons: Bool
    public var showRemainingDueCounts: Bool
    public var timeLimitMinutes: Int
    public var loadBalancer: Bool

    enum CodingKeys: String, CodingKey {
        case nextDayStartsAt = "next_day_starts_at", learnAheadMinutes = "learn_ahead_minutes"
        case newReviewMix = "new_review_mix", dayLearnFirst = "day_learn_first"
        case showIntervalsOnButtons = "show_intervals_on_buttons", showRemainingDueCounts = "show_remaining_due_counts"
        case timeLimitMinutes = "time_limit_minutes", loadBalancer = "load_balancer"
    }
}

/// What the sync server needs to recognise you: a key it handed out at sign-in
/// (never your password), and its address if it isn't AnkiWeb.
public struct SyncAuth: Codable, Equatable, Sendable {
    public var hkey: String
    public var endpoint: String?
    public init(hkey: String, endpoint: String?) {
        self.hkey = hkey
        self.endpoint = endpoint
    }
}

public struct SyncResult: Decodable, Sendable {
    /// "no_changes", "synced" or "full_sync" (you must choose upload or download).
    public let result: String
    public let uploadOK: Bool
    public let downloadOK: Bool
    public let serverMessage: String
    public let newEndpoint: String?
    enum CodingKeys: String, CodingKey {
        case result
        case uploadOK = "upload_ok", downloadOK = "download_ok"
        case serverMessage = "server_message", newEndpoint = "new_endpoint"
    }
}

/// The four grade buttons, numbered the way Anki numbers them.
public enum Rating: UInt8, CaseIterable, Identifiable, Sendable {
    case again = 1, hard, good, easy
    public var id: UInt8 { rawValue }
    public var title: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}

public struct EngineError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Owns one open Anki collection.
///
/// Anki's engine is not built for several threads poking it at once,
/// so every call goes through this actor, one at a time.
public actor Engine {
    private var handle: OpaquePointer?
    /// The same pointer, for the one call that runs alongside others (media sync).
    /// The Rust side does its own locking, so this is safe while the collection is open.
    private let sharedAddress: UInt

    /// Opens (or creates) a `collection.anki2` file.
    public init(collectionPath: URL) throws {
        guard let handle = collectionPath.path.withCString({ study_open($0) }) else {
            throw Engine.lastError()
        }
        self.handle = handle
        self.sharedAddress = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(handle)))
    }

    deinit {
        study_close(handle)
    }

    /// Saves and closes the collection. Any later call fails politely.
    public func close() {
        study_close(handle)
        handle = nil
    }

    private func open() throws -> OpaquePointer {
        guard let handle else { throw EngineError(message: "The collection is closed.") }
        return handle
    }

    /// Top-level decks (sub-decks are nested inside), with today's counts.
    public func decks() throws -> [Deck] {
        let json = try Self.takeString(study_deck_tree(try open()))
        return try JSONDecoder().decode([Deck].self, from: Data(json.utf8))
    }

    /// Study this deck (and its sub-decks) from now on.
    public func selectDeck(_ id: Int64) throws {
        guard study_select_deck(try open(), id) else { throw Self.lastError() }
    }

    /// The next card due in the selected deck, plus what's left today.
    public func nextCard() throws -> StudyState {
        let json = try Self.takeString(study_next_card(try open()))
        return try JSONDecoder().decode(StudyState.self, from: Data(json.utf8))
    }

    /// Grades the card returned by the last `nextCard()`.
    public func answer(_ rating: Rating, milliseconds: UInt32) throws {
        guard study_answer(try open(), rating.rawValue, milliseconds) else { throw Self.lastError() }
    }

    /// Every card type in the collection.
    public func noteTypes() throws -> [NoteType] {
        let json = try Self.takeString(study_notetypes(try open()))
        return try JSONDecoder().decode([NoteType].self, from: Data(json.utf8))
    }

    /// Adds a note; returns how many cards it created.
    @discardableResult
    public func addNote(noteType: Int64, deck: Int64, fields: [String], tags: [String] = []) throws -> Int {
        struct Request: Encodable {
            let notetype_id: Int64, deck_id: Int64, fields: [String], tags: [String]
        }
        struct Reply: Decodable { let cards: Int }
        let body = try JSONEncoder().encode(Request(notetype_id: noteType, deck_id: deck, fields: fields, tags: tags))
        let json = try String(decoding: body, as: UTF8.self).withCString { try Self.takeString(study_add_note(try open(), $0)) }
        return try JSONDecoder().decode(Reply.self, from: Data(json.utf8)).cards
    }

    /// Adds one of Anki's standard card types ("basic", "reversed", "typing", "cloze").
    @discardableResult
    public func addStockNoteType(_ kind: String) throws -> Int64 {
        try call(study_add_stock_notetype, kind)
    }

    /// Imports a shared deck file (.apkg), keeping its study progress.
    public func importPackage(_ url: URL) throws -> ImportResult {
        let json = try url.path.withCString { try Self.takeString(study_import_apkg(try open(), $0)) }
        return try JSONDecoder().decode(ImportResult.self, from: Data(json.utf8))
    }

    /// Stats limited to an Anki search, e.g. `did:1,2,3` for one deck and its sections.
    public func stats(days: UInt32, search: String) throws -> Stats {
        struct Request: Encodable { let days: UInt32; let search: String }
        return try call(study_stats_search, Request(days: days, search: search))
    }

    /// Review history for the last `days` days, plus card totals.
    public func stats(days: UInt32 = 365) throws -> Stats {
        let json = try Self.takeString(study_stats(try open(), days))
        return try JSONDecoder().decode(Stats.self, from: Data(json.utf8))
    }

    /// Undoes the last change (usually the last grade).
    public func undo() throws {
        guard study_undo(try open()) else { throw Self.lastError() }
    }

    // MARK: - Sync

    /// Signs in to AnkiWeb (or your own server) and returns the key to sync with.
    public static func syncLogin(username: String, password: String, endpoint: String?) throws -> SyncAuth {
        struct Request: Encodable { let username: String; let password: String; let endpoint: String? }
        let body = String(decoding: try JSONEncoder().encode(Request(username: username, password: password, endpoint: endpoint)), as: UTF8.self)
        let json = try body.withCString { try takeString(study_sync_login($0)) }
        return try JSONDecoder().decode(SyncAuth.self, from: Data(json.utf8))
    }

    /// A normal two-way sync of cards and progress.
    public func sync(_ auth: SyncAuth) throws -> SyncResult {
        try call(study_sync, auth)
    }

    /// Replaces one side completely: `upload` sends this Mac's cards to the server,
    /// otherwise the server's cards replace this Mac's.
    public func fullSync(_ auth: SyncAuth, upload: Bool) throws {
        struct Request: Encodable { let hkey: String; let endpoint: String?; let upload: Bool }
        let _: Bool = try call(study_full_sync, Request(hkey: auth.hkey, endpoint: auth.endpoint, upload: upload))
    }

    /// Syncs pictures and sounds. Runs outside the actor so studying isn't held up.
    public nonisolated func syncMedia(_ auth: SyncAuth) throws {
        guard let handle = OpaquePointer(bitPattern: sharedAddress) else { throw EngineError(message: "The collection is closed.") }
        let body = String(decoding: try JSONEncoder().encode(auth), as: UTF8.self)
        _ = try body.withCString { try Self.takeString(study_sync_media(handle, $0)) }
    }

    // MARK: - Deck menu

    private struct DeckRequest: Encodable {
        let deck_id: Int64
        var name = ""
        var path = ""
        var with_scheduling = false
        var with_media = false
    }

    public func renameDeck(_ id: Int64, to name: String) throws {
        let _: Bool = try call(study_rename_deck, DeckRequest(deck_id: id, name: name))
    }

    /// Deletes the deck, its sections and their cards; returns how many cards went.
    @discardableResult
    public func deleteDeck(_ id: Int64) throws -> Int {
        try call(study_delete_deck, DeckRequest(deck_id: id))
    }

    /// Saves the deck as an .apkg file; returns how many notes went in.
    @discardableResult
    public func exportDeck(_ id: Int64, to url: URL, withProgress: Bool, withMedia: Bool) throws -> Int {
        try call(study_export_deck, DeckRequest(deck_id: id, path: url.path, with_scheduling: withProgress, with_media: withMedia))
    }

    public func deckOptions(_ id: Int64) throws -> DeckOptions {
        try call(study_deck_options, id)
    }

    /// Saves settings into a preset (shared by every deck using it), or into a
    /// new preset when `newPresetName` is given. `switchOnly` just moves the deck to the preset.
    public func saveDeckOptions(deck: Int64, preset: Int64, settings: DeckSettings, fsrs: Bool,
                                newPresetName: String? = nil, switchOnly: Bool = false) throws {
        struct Request: Encodable {
            let deck_id: Int64, preset_id: Int64, new_preset_name: String?, switch_only: Bool
            let settings: DeckSettings, fsrs: Bool
        }
        let _: Bool = try call(study_save_deck_options, Request(deck_id: deck, preset_id: preset, new_preset_name: newPresetName,
                                                                 switch_only: switchOnly, settings: settings, fsrs: fsrs))
    }

    // MARK: - Backups

    /// Backs up into `folder` if something changed and none was made in the
    /// last 30 minutes (or always, with `force`). Returns true if one was made.
    @discardableResult
    public func backup(to folder: URL, force: Bool = false) throws -> Bool {
        struct Request: Encodable { let folder: String; let force: Bool }
        return try call(study_backup, Request(folder: folder.path, force: force))
    }

    /// Replaces a closed collection with a backup file.
    public static func restoreBackup(_ backup: URL, collection: URL, mediaFolder: URL, mediaDB: URL) throws {
        struct Request: Encodable { let backup: String; let collection: String; let media_folder: String; let media_db: String }
        let body = String(decoding: try JSONEncoder().encode(Request(backup: backup.path, collection: collection.path,
                                                                       media_folder: mediaFolder.path, media_db: mediaDB.path)), as: UTF8.self)
        _ = try body.withCString { try takeString(study_restore_backup($0)) }
    }

    // MARK: - Filtered decks

    /// Makes a filtered deck from a search and fills it; returns its id.
    public func createFilteredDeck(name: String, search: String, limit: Int, order: String, reschedule: Bool) throws -> Int64 {
        struct Request: Encodable { let name: String; let search: String; let limit: Int; let order: String; let reschedule: Bool }
        return try call(study_create_filtered, Request(name: name, search: search, limit: limit, order: order, reschedule: reschedule))
    }

    /// Refills a filtered deck; returns how many cards it now holds.
    @discardableResult
    public func rebuildFilteredDeck(_ id: Int64) throws -> Int {
        try call(study_rebuild_filtered, id)
    }

    /// Sends a filtered deck's cards back to their own decks.
    public func emptyFilteredDeck(_ id: Int64) throws {
        let _: Bool = try call(study_empty_filtered, id)
    }

    public func preferences() throws -> CollectionPreferences {
        let json = try Self.takeString(study_preferences(try open()))
        return try JSONDecoder().decode(CollectionPreferences.self, from: Data(json.utf8))
    }

    public func setPreferences(_ prefs: CollectionPreferences) throws {
        let _: Bool = try call(study_set_preferences, prefs)
    }

    // MARK: - Browse

    /// Card ids matching an Anki search (empty text = every card).
    /// Matching card ids; with `notes`, just the first card of each note.
    public func search(_ query: String, sort: BrowseColumn? = nil, reverse: Bool = false, notes: Bool = false) throws -> [Int64] {
        struct Request: Encodable { let query: String; let sort: String?; let reverse: Bool; let notes: Bool }
        return try call(study_search, Request(query: query, sort: sort?.rawValue, reverse: reverse, notes: notes))
    }

    // MARK: Browse power tools

    private struct Bulk: Encodable {
        let action: String
        let card_ids: [Int64]
        var tags = ""
        var find = ""
        var replace = ""
        var field = ""
        var regex = false
        var match_case = false
        var start = 0
        var shift = false
        var notetype_id: Int64 = 0
    }

    /// Adds space-separated tags to the notes of these cards; returns how many notes changed.
    @discardableResult
    public func addTags(_ tags: String, toCards cards: [Int64]) throws -> Int {
        try call(study_bulk, Bulk(action: "add_tags", card_ids: cards, tags: tags))
    }

    @discardableResult
    public func removeTags(_ tags: String, fromCards cards: [Int64]) throws -> Int {
        try call(study_bulk, Bulk(action: "remove_tags", card_ids: cards, tags: tags))
    }

    /// Find & replace in the notes of these cards; returns how many notes changed.
    public func findAndReplace(cards: [Int64], find: String, replace: String, field: String?,
                               regex: Bool, matchCase: Bool) throws -> Int {
        try call(study_bulk, Bulk(action: "find_replace", card_ids: cards, find: find, replace: replace,
                                  field: field ?? "", regex: regex, match_case: matchCase))
    }

    /// Puts new cards in this order in the new-card queue, starting at `start`.
    @discardableResult
    public func reposition(_ cards: [Int64], start: Int, shiftOthers: Bool) throws -> Int {
        try call(study_bulk, Bulk(action: "reposition", card_ids: cards, start: start, shift: shiftOthers))
    }

    /// Moves notes to another card type, matching fields by name (then position). Needs a full sync after.
    @discardableResult
    public func changeNoteType(ofCards cards: [Int64], to noteType: Int64) throws -> Int {
        try call(study_bulk, Bulk(action: "change_type", card_ids: cards, notetype_id: noteType))
    }

    public func findDuplicates(in search: String) throws -> [DuplicateGroup] {
        struct Request: Encodable { let search: String }
        return try call(study_find_dupes, Request(search: search))
    }

    public func allTags() throws -> [String] {
        try call(study_all_tags, [String: String]())
    }

    /// Table rows for these cards, in the same order.
    public func browseRows(_ ids: [Int64]) throws -> [BrowseRow] {
        try call(study_browse_rows, ids)
    }

    /// The note behind a card, with its card rendered for a preview.
    public func note(forCard id: Int64) throws -> EditableNote {
        try call(study_note_for_card, id)
    }

    /// Saves a note's fields and tags.
    public func updateNote(_ id: Int64, fields: [String], tags: [String]) throws {
        struct Request: Encodable { let note_id: Int64; let fields: [String]; let tags: [String] }
        let _: Bool = try call(study_update_note, Request(note_id: id, fields: fields, tags: tags))
    }

    private struct CardsRequest: Encodable {
        let card_ids: [Int64]
        var suspended = false
        var deck_id: Int64 = 0
    }

    public func setSuspended(_ cards: [Int64], _ suspended: Bool) throws {
        let _: Bool = try call(study_set_suspended, CardsRequest(card_ids: cards, suspended: suspended))
    }

    public func moveCards(_ cards: [Int64], toDeck deck: Int64) throws {
        let _: Bool = try call(study_set_deck, CardsRequest(card_ids: cards, deck_id: deck))
    }

    /// Deletes the notes behind these cards; returns how many notes went.
    @discardableResult
    public func deleteNotes(ofCards cards: [Int64]) throws -> Int {
        try call(study_delete_notes, CardsRequest(card_ids: cards))
    }

    /// "ok", "empty", "duplicate", "missing_cloze" or "not_cloze".
    public func checkNote(noteType: Int64, fields: [String]) throws -> String {
        struct Request: Encodable { let notetype_id: Int64; let fields: [String] }
        return try call(study_check_note, Request(notetype_id: noteType, fields: fields))
    }

    /// Adds a "hide parts of a picture" note using Anki's own card type.
    public func addOcclusion(deck: Int64, image: URL, occlusions: String, header: String = "",
                             backExtra: String = "", tags: [String] = []) throws {
        struct Request: Encodable {
            let deck_id: Int64; let image_path: String; let occlusions: String
            let header: String; let back_extra: String; let tags: [String]
        }
        let _: Bool = try call(study_add_occlusion, Request(deck_id: deck, image_path: image.path, occlusions: occlusions,
                                                            header: header, back_extra: backExtra, tags: tags))
    }

    // MARK: Housekeeping

    /// Anki's Check Database: fixes problems and says what it fixed.
    public func checkDatabase() throws -> [String] {
        try call(study_check_database, [String: String]())
    }

    public func checkMedia() throws -> MediaCheck {
        try call(study_check_media, [String: String]())
    }

    /// Moves media files to the media trash (restorable until emptied).
    public func trashMedia(_ files: [String]) throws {
        let _: Bool = try call(study_trash_media, files)
    }

    public func leechState(_ card: Int64) throws -> (leech: Bool, suspended: Bool, lapses: Int) {
        struct Reply: Decodable { let leech: Bool; let suspended: Bool; let lapses: Int }
        let r: Reply = try call(study_leech_state, card)
        return (r.leech, r.suspended, r.lapses)
    }

    private struct CSVRequest: Encodable {
        let path: String
        var deck_id: Int64?
        var notetype_id: Int64?
        var duplicates = ""
    }

    public func csvPreview(_ file: URL, noteType: Int64? = nil) throws -> CSVPreview {
        try call(study_csv_preview, CSVRequest(path: file.path, notetype_id: noteType))
    }

    /// `duplicates`: "update", "skip" or "duplicate".
    public func importCSV(_ file: URL, deck: Int64, noteType: Int64, duplicates: String) throws -> CSVImportResult {
        try call(study_import_csv, CSVRequest(path: file.path, deck_id: deck, notetype_id: noteType, duplicates: duplicates))
    }

    /// Saves the whole collection as a .colpkg.
    public func exportCollection(to url: URL, includeMedia: Bool) throws {
        struct Request: Encodable { let path: String; let include_media: Bool }
        let _: Bool = try call(study_export_collection, Request(path: url.path, include_media: includeMedia))
    }

    // MARK: Study more today

    /// New cards and reviews beyond today's limits that a deck still has.
    public func studyMoreInfo(_ deck: Int64) throws -> (extraNew: Int, extraReviews: Int) {
        struct Reply: Decodable { let extra_new: Int; let extra_reviews: Int }
        let reply: Reply = try call(study_more_info, deck)
        return (reply.extra_new, reply.extra_reviews)
    }

    /// Raises today's limits (today only).
    public func studyMore(_ deck: Int64, newCards: Int = 0, reviews: Int = 0) throws {
        struct Request: Encodable { let deck_id: Int64; let new_cards: Int; let reviews: Int }
        let _: Bool = try call(study_more, Request(deck_id: deck, new_cards: newCards, reviews: reviews))
    }

    // MARK: Card actions

    private struct CardAction: Encodable {
        let action: String
        let card_ids: [Int64]
        var flag = 0
        var days = ""
    }

    /// 0 removes the flag; 1–7 = red, orange, green, blue, pink, turquoise, purple.
    public func setFlag(_ cards: [Int64], _ flag: Int) throws {
        let _: Bool = try call(study_card_action, CardAction(action: "flag", card_ids: cards, flag: flag))
    }

    /// Hides cards until tomorrow.
    public func bury(_ cards: [Int64]) throws {
        let _: Bool = try call(study_card_action, CardAction(action: "bury", card_ids: cards))
    }

    /// Anki's due text: "0" today, "1" tomorrow, "3-7" a random day in that range, "5!" also sets the interval.
    public func setDueDate(_ cards: [Int64], days: String) throws {
        let _: Bool = try call(study_card_action, CardAction(action: "set_due", card_ids: cards, days: days))
    }

    /// Turns cards back into new cards, forgetting their progress.
    public func forget(_ cards: [Int64]) throws {
        let _: Bool = try call(study_card_action, CardAction(action: "forget", card_ids: cards))
    }

    public func cardInfo(_ card: Int64) throws -> CardInfo {
        try call(study_card_info, card)
    }

    /// Makes a deck such as "Biology::Week 1" (reusing one with that name).
    public func addDeck(named name: String) throws -> Int64 {
        try call(study_add_deck, name)
    }

    /// Sends `request` as JSON to an engine function and decodes its JSON answer.
    private func call<Request: Encodable, Reply: Decodable>(
        _ function: (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
        _ request: Request
    ) throws -> Reply {
        let body = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let handle = try open()
        let json = try body.withCString { try Self.takeString(function(handle, $0)) }
        return try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
    }

    // MARK: - Helpers

    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let pointer else { throw lastError() }
        defer { study_free_string(pointer) }
        return String(cString: pointer)
    }

    private static func lastError() -> EngineError {
        guard let pointer = study_last_error() else {
            return EngineError(message: "Unknown engine error")
        }
        defer { study_free_string(pointer) }
        return EngineError(message: String(cString: pointer))
    }
}
