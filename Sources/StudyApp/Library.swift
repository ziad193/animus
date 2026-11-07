import AppKit
import Foundation
import Observation
import StudyCore

/// Where the app keeps its collection, and which collection is open.
@MainActor
@Observable
final class Library {
    enum State {
        case noCollection
        case loading
        case ready([Deck])
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var engine: Engine?
    /// A profile waiting for the student to confirm it should replace the current cards.
    var pendingProfile: URL?
    /// A short message to show the student (e.g. after an import).
    var notice: String?
    /// A text/CSV file waiting in the import sheet.
    var csvImport: CSVFile?

    struct CSVFile: Identifiable {
        let url: URL
        var id: URL { url }
    }
    /// The collection's study preferences (when the day starts, what the study screen shows…).
    private(set) var preferences: CollectionPreferences?

    /// ~/Library/Application Support/StudyApp/
    /// The current profile's folder.
    nonisolated static var folder: URL {
        // For developers: ITERUM_DATA_FOLDER runs the app on a separate test collection.
        if let test = ProcessInfo.processInfo.environment["ITERUM_DATA_FOLDER"], !test.isEmpty {
            return URL(fileURLWithPath: test, isDirectory: true)
        }
        return ProfileStore.currentFolder
    }

    /// True when running on a developer test collection.
    nonisolated static var isTestCollection: Bool {
        !(ProcessInfo.processInfo.environment["ITERUM_DATA_FOLDER"] ?? "").isEmpty
    }

    nonisolated static var collectionURL: URL { folder.appendingPathComponent("collection.anki2") }
    /// Images and audio used by cards.
    nonisolated static var mediaFolder: URL { folder.appendingPathComponent("collection.media", isDirectory: true) }

    /// Profiles found in the official Anki app's data folder.
    static func ankiProfiles() -> [URL] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anki2", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("collection.anki2").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    init() {
        if FileManager.default.fileExists(atPath: Self.collectionURL.path) {
            Task { await open() }
        } else {
            state = .noCollection
        }
    }

    /// Creates an empty collection.
    func startFresh() async {
        await open()
    }

    /// Asks first if there are already cards here; otherwise copies straight away.
    func requestImport(ofProfile profile: URL) {
        if case .noCollection = state {
            Task { await importCopy(ofProfile: profile) }
        } else {
            pendingProfile = profile
        }
    }

    /// Copies a profile's collection and media from the official Anki app.
    /// The original is only read, never changed. On Apple's file system the
    /// copy is near-instant and takes no extra space until files change.
    func importCopy(ofProfile profile: URL) async {
        pendingProfile = nil
        state = .loading
        await engine?.close()
        engine = nil
        let folder = Self.folder
        do {
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in ["collection.anki2", "collection.anki2-wal", "collection.media"] {
                    let source = profile.appendingPathComponent(name)
                    let target = folder.appendingPathComponent(name)
                    try? fm.removeItem(at: target)
                    if fm.fileExists(atPath: source.path) {
                        try fm.copyItem(at: source, to: target)
                    }
                }
            }.value
            await open()
        } catch {
            state = .failed("Couldn't copy the collection: \(error.localizedDescription)")
        }
    }

    /// Shared deck files (.apkg) in Downloads, newest first, for setup to offer.
    /// Only file names and dates are read. macOS asks once before Animus can look.
    nonisolated static func recentDeckFiles(limit: Int = 2) -> [RecentDeckFile] {
        let fm = FileManager.default
        var folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Test collections look in a stand-in folder, never the real Downloads.
        if isTestCollection {
            guard let stand = ProcessInfo.processInfo.environment["ITERUM_TEST_DOWNLOADS"] else { return [] }
            folder = URL(fileURLWithPath: stand, isDirectory: true)
        }
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey]
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == "apkg" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return RecentDeckFile(url: url,
                                      date: values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast,
                                      bytes: values?.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    struct RecentDeckFile: Hashable, Sendable {
        let url: URL
        let date: Date
        let bytes: Int
        var name: String { url.deletingPathExtension().lastPathComponent }
        /// e.g. "Downloaded 3 days ago · 12 MB"
        var detail: String {
            "Downloaded " + date.formatted(.relative(presentation: .named))
                + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    /// Imports a shared deck file (.apkg) into the open collection and
    /// returns a short summary for the student.
    func importPackage(_ url: URL) async -> String {
        if engine == nil { await startFresh() }
        guard let engine else { return "Couldn't open your collection." }
        do {
            let result = try await engine.importPackage(url)
            await refresh()
            var parts = ["\(result.new) new notes"]
            if result.updated > 0 { parts.append("\(result.updated) updated") }
            if result.duplicate > 0 { parts.append("\(result.duplicate) already here") }
            return "Imported “\(url.deletingPathExtension().lastPathComponent)”: " + parts.joined(separator: ", ") + "."
        } catch {
            return error.localizedDescription
        }
    }

    /// Asks for a deck file, then imports it. Returns nil if cancelled.
    func chooseAndImport() async -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["apkg", "colpkg", "csv", "tsv", "txt"].compactMap { .init(filenameExtension: $0) }
        panel.message = "Choose a shared deck (.apkg), or a spreadsheet or text file of cards (.csv, .tsv, .txt)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if ["csv", "tsv", "txt"].contains(url.pathExtension.lowercased()) {
            // A spreadsheet: pick the deck and card type first.
            csvImport = CSVFile(url: url)
            return nil
        }
        return await importPackage(url)
    }

    // MARK: Backups

    /// Backups live next to the collection, in the profile's own folder.
    nonisolated static var backupFolder: URL { folder.appendingPathComponent("backups", isDirectory: true) }

    struct Backup: Identifiable, Hashable {
        let url: URL
        let date: Date
        let bytes: Int
        var id: URL { url }
    }

    /// Saved backups, newest first.
    static func backups() -> [Backup] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: backupFolder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "colpkg" }.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            return Backup(url: url, date: values?.creationDate ?? .distantPast, bytes: values?.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }
    }

    @ObservationIgnored private var backupTimer: Task<Void, Never>?

    /// Backs up if anything changed and none was made in the last 30 minutes,
    /// or always when `force` (e.g. just before a full sync). Quiet on failure
    /// unless forced.
    @discardableResult
    func backup(force: Bool = false) async -> Bool {
        guard let engine else { return false }
        do {
            return try await engine.backup(to: Self.backupFolder, force: force)
        } catch {
            if force { notice = error.localizedDescription }
            return false
        }
    }

    /// Every 30 minutes while the app is open (Anki does the same).
    private func startBackups() {
        backupTimer?.cancel()
        backupTimer = Task { [weak self] in
            await self?.backup()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                await self?.backup()
            }
        }
    }

    /// Replaces the cards with a backup. Your current cards are backed up first,
    /// so a restore can itself be undone by restoring that one.
    func restore(_ backup: Backup) async {
        await self.backup(force: true)
        state = .loading
        await engine?.close()
        engine = nil
        let collection = Self.collectionURL
        let media = Self.mediaFolder
        let mediaDB = Self.folder.appendingPathComponent("collection.mdb")
        do {
            try await Task.detached {
                try Engine.restoreBackup(backup.url, collection: collection, mediaFolder: media, mediaDB: mediaDB)
            }.value
            notice = "Restored the backup from \(backup.date.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            notice = error.localizedDescription
        }
        await open()
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Saves preferences; counts are refreshed because the day start may have moved.
    func savePreferences(_ prefs: CollectionPreferences) async throws {
        guard let engine else { return }
        try await engine.setPreferences(prefs)
        preferences = try await engine.preferences()
        await refresh()
    }

    func refresh() async {
        guard let engine else { return }
        do {
            state = .ready(try await engine.decks())
        } catch {
            state = .failed(error.localizedDescription)
        }
        await refreshUndo()
    }

    // MARK: Undo / redo (the Edit menu)

    /// What Edit › Undo and Redo would do, e.g. "Answer Card".
    private(set) var undoStatus = Engine.UndoStatus(undo: nil, redo: nil)
    /// Goes up after an undo or redo from the Edit menu, so open screens reload.
    private(set) var undoGeneration = 0

    func refreshUndo() async {
        guard let engine else { return }
        let status = (try? await engine.undoStatus()) ?? .init(undo: nil, redo: nil)
        if status != undoStatus { undoStatus = status }
    }

    func undoFromMenu() async {
        guard let engine, undoStatus.undo != nil else { return }
        do {
            try await engine.undo()
        } catch {
            notice = error.localizedDescription
        }
        undoGeneration += 1
        await refresh()
    }

    func redoFromMenu() async {
        guard let engine, undoStatus.redo != nil else { return }
        do {
            try await engine.redo()
        } catch {
            notice = error.localizedDescription
        }
        undoGeneration += 1
        await refresh()
    }

    private func open() async {
        state = .loading
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let engine = try Engine(collectionPath: Self.collectionURL)
            self.engine = engine
            state = .ready(try await engine.decks())
            preferences = try? await engine.preferences()
            startBackups()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
