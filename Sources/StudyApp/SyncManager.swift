import AppKit
import Foundation
import Observation
import Security
import StudyCore

/// Keeps the sync sign-in in the macOS Keychain. Only the key the server
/// hands out is saved, never the password.
enum SyncKeychain {
    /// A test collection gets its own sign-in, so it can never sync the real one.
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

    static func delete() {
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
            let result = try await engine.sync(auth)
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
        Task.detached(priority: .utility) {
            let failure: String?
            do {
                try engine.syncMedia(auth)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                self?.mediaSyncing = false
                if let failure, self?.status == .idle { self?.status = .failed("Pictures and sounds: \(failure)") }
            }
        }
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
