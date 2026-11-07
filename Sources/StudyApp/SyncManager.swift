import AppKit
import Foundation
import Observation
import Security
import StudyCore

/// Keeps the sync sign-in in the macOS Keychain. Only the key the server
/// hands out is saved, never the password.
enum SyncKeychain {
    /// A test collection gets its own sign-in, so it can never sync the real one.
    /// Still named after the app's old name (Iterum): renaming it would sign everyone out.
    private static var service: String { Library.isTestCollection ? "Iterum Sync (test)" : "Iterum Sync" }
    /// One sign-in per profile ("default" for the first, as before).
    private static var account: String { ProfileStore.currentID }

    static func load() -> SyncAuth? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SyncAuth.self, from: data)
    }

    static func save(_ auth: SyncAuth) {
        guard let data = try? JSONEncoder().encode(auth) else { return }
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() { delete(account: account) }

    /// Forgets the sign-in of any profile (e.g. one being deleted).
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum SyncPref {
    private static var prefix: String { Library.isTestCollection ? "test.sync." : "sync." }
    static var username: String { prefix + "username" }
    static var automatic: String { prefix + "automatic" }
    static var media: String { prefix + "media" }
    static var lastSync: String { prefix + "last" }
}

/// Syncs your cards and progress with AnkiWeb (or your own sync server),
/// the same service the official Anki apps use.
@MainActor
@Observable
final class SyncManager {
    enum Status: Equatable {
        case idle
        case syncing
        /// The two copies can't be merged; you choose which to keep.
        case needsChoice(uploadOK: Bool, downloadOK: Bool)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var mediaSyncing = false
    private(set) var auth: SyncAuth?
    private(set) var lastSync: Date?
    /// A message from the server (AnkiWeb sometimes sends notices).
    var serverMessage: String?
    /// Shows the sign-in sheet.
    var showingSignIn = false
    /// True while the study screen is open; syncing then would reset the card on screen.
    var studying = false {
        didSet { if oldValue, !studying { Task { await syncIfAutomatic() } } }
    }

    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var timer: Task<Void, Never>?

    var username: String? { AppDefaults.current.string(forKey: SyncPref.username) }
    var isSignedIn: Bool { auth != nil }
    var isBusy: Bool { status == .syncing }

    var automatic: Bool {
        AppDefaults.current.object(forKey: SyncPref.automatic) as? Bool ?? true
    }

    var syncsMedia: Bool {
        AppDefaults.current.object(forKey: SyncPref.media) as? Bool ?? true
    }

    init() {
        auth = SyncKeychain.load()
        let stamp = AppDefaults.current.double(forKey: SyncPref.lastSync)
        lastSync = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// Hooks up to the collection and starts automatic syncing.
    func attach(_ library: Library) {
        self.library = library
        timer?.cancel()
        // Sync every 30 minutes while the app is open (if automatic sync is on).
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                await self?.syncIfAutomatic()
            }
        }
    }

    // MARK: Signing in

    func signIn(username: String, password: String, server: String?) async throws {
        let endpoint = server?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let newAuth = try await Task.detached {
            try Engine.syncLogin(username: username, password: password, endpoint: endpoint)
        }.value
        SyncKeychain.save(newAuth)
        auth = newAuth
        AppDefaults.current.set(username, forKey: SyncPref.username)
        status = .idle
    }

    func signOut() {
        SyncKeychain.delete()
        auth = nil
        AppDefaults.current.removeObject(forKey: SyncPref.username)
        status = .idle
    }

    // MARK: Syncing

    /// Automatic syncs (on launch, after studying, every 30 min) stay quiet on failure.
    func syncIfAutomatic() async {
        guard automatic, isSignedIn else { return }
        await sync(quiet: true)
    }

    /// The Sync button: signs in first if needed.
    func syncNow() async {
        guard isSignedIn else {
            showingSignIn = true
            return
        }
        await sync(quiet: false)
    }

    private func sync(quiet: Bool) async {
        guard let auth, let engine = library?.engine, !isBusy, !isChoosing, !studying else { return }
        status = .syncing
        do {
            let result = try await Self.retryingOnce { try await engine.sync(auth) }
            if let moved = result.newEndpoint, !moved.isEmpty {
                // AnkiWeb moved this account to another server; remember it.
                let updated = SyncAuth(hkey: auth.hkey, endpoint: moved)
                SyncKeychain.save(updated)
                self.auth = updated
            }
            if !result.serverMessage.isEmpty { serverMessage = result.serverMessage }
            if result.result == "full_sync" {
                // One side is about to replace the other: keep a copy first.
                await library?.backup(force: true)
                // When one side is empty there's nothing to choose.
                if result.downloadOK && !result.uploadOK {
                    try await engine.fullSync(auth, upload: false)
                } else if result.uploadOK && !result.downloadOK {
                    try await engine.fullSync(auth, upload: true)
                } else {
                    status = .needsChoice(uploadOK: result.uploadOK, downloadOK: result.downloadOK)
                    await library?.refresh()
                    return
                }
            }
            finished()
        } catch {
            let message = error.localizedDescription
            if message.contains("password wasn't right") { signOut() }
            status = quiet ? .idle : .failed(message)
        }
        await library?.refresh()
    }

    /// Runs a sync step, and if it fails with what looks like a hiccup (an odd
    /// reply, a dropped connection), waits a moment and tries once more before
    /// telling you. Problems that won't fix themselves (wrong password, a wrong
    /// clock, being offline…) are reported straight away.
    static func retryingOnce<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            guard isHiccup(error.localizedDescription) else { throw error }
            try? await Task.sleep(for: .seconds(2))
            return try await work()
        }
    }

    nonisolated static func isHiccup(_ message: String) -> Bool {
        let lasting = ["wasn't right", "clock looks wrong", "newer version", "too big to upload",
                       "disagree about your cards", "offline", "cancelled", "address doesn't look right"]
        return !lasting.contains { message.contains($0) }
    }

    private var isChoosing: Bool {
        if case .needsChoice = status { return true }
        return false
    }

    /// Settles a "which copy do you keep?" choice.
    func resolve(upload: Bool) async {
        guard let auth, let engine = library?.engine else { return }
        status = .syncing
        await library?.backup(force: true)
        do {
            try await engine.fullSync(auth, upload: upload)
            finished()
        } catch {
            status = .failed(error.localizedDescription)
        }
        await library?.refresh()
    }

    func dismissChoice() {
        status = .idle
    }

    private func finished() {
        status = .idle
        lastSync = Date()
        AppDefaults.current.set(Date().timeIntervalSince1970, forKey: SyncPref.lastSync)
        if syncsMedia { syncMediaInBackground() }
    }

    /// Pictures and sounds can take a while the first time, so they sync
    /// separately and studying carries on meanwhile.
    private func syncMediaInBackground() {
        guard let auth, let engine = library?.engine, !mediaSyncing else { return }
        mediaSyncing = true
        mediaProgress = nil
        // Check how far it's got a few times a second, for the progress bar.
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let progress = try? await engine.mediaProgress(), progress.active else { continue }
                self?.mediaProgress = progress
            }
        }
        Task.detached(priority: .utility) {
            let failure: String?
            do {
                try await Self.retryingOnce { try engine.syncMedia(auth) }
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                watcher.cancel()
                self?.mediaSyncing = false
                self?.mediaProgress = nil
                if let failure, self?.status == .idle { self?.status = .failed("Pictures and sounds: \(failure)") }
            }
        }
    }

    /// While pictures and sounds sync: how many have gone each way so far.
    private(set) var mediaProgress: Engine.MediaProgress?

    /// e.g. "120 downloaded · 4 uploaded", or "Checking 300 files…" before any move.
    var mediaProgressText: String {
        guard let p = mediaProgress else { return "Getting ready…" }
        var parts: [String] = []
        if p.downloaded > 0 { parts.append("\(p.downloaded.formatted()) downloaded") }
        if p.uploaded > 0 { parts.append("\(p.uploaded.formatted()) uploaded") }
        if p.removed > 0 { parts.append("\(p.removed.formatted()) removed") }
        if parts.isEmpty { return p.checked > 0 ? "Checking \(p.checked.formatted()) files…" : "Getting ready…" }
        return parts.joined(separator: " · ")
    }

    /// e.g. "Synced 3 min ago".
    var summary: String {
        switch status {
        case .syncing: return "Syncing…"
        case .needsChoice: return "Choose which copy to keep"
        case .failed(let message): return message
        case .idle:
            guard isSignedIn else { return "Not syncing" }
            if mediaSyncing { return "Syncing pictures and sounds…" }
            guard let lastSync else { return "Not synced yet" }
            return "Synced " + lastSync.formatted(.relative(presentation: .named))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
