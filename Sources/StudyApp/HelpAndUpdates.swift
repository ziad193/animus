import AppKit
import Observation
import SwiftUI
import StudyCore

// MARK: - Help menu

/// Help › Copy Debug Info and Show Collection Folder, for bug reports.
struct HelpCommands: View {
    let library: Library
    let profiles: ProfileStore

    var body: some View {
        Button("Copy Debug Info") {
            Task { await copyDebugInfo() }
        }
        Button("Show Collection Folder") {
            NSWorkspace.shared.activateFileViewerSelecting([Library.collectionURL])
        }
    }

    /// Facts that help fix a bug, with nothing personal: no card text, deck
    /// names, account names or file paths.
    private func copyDebugInfo() async {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var chip = "Apple Silicon"
        #if arch(x86_64)
        chip = "Intel"
        #endif
        var lines = [
            "Animus \(version) (\(build))",
            "Anki engine \(AppInfo.ankiVersion)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(chip)",
            "Profiles: \(profiles.profiles.count)",
        ]
        if case .ready(let decks) = library.state {
            let all = Deck.flatten(decks)
            let cards = decks.reduce(0) { $0 + Int($1.totalCards) }
            lines.append("Decks: \(all.count), cards: \(cards)")
        } else {
            lines.append("Collection: not open")
        }
        if let engine = library.engine, let prefs = try? await engine.preferences() {
            lines.append("Day starts at: \(prefs.nextDayStartsAt):00")
        }
        lines.append("Signed in to sync: \(SyncKeychain.load() != nil ? "yes" : "no")")
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        library.notice = "Debug info copied. Paste it into your bug report.\n\n" + text
    }
}

enum AppInfo {
    /// The version of Anki's engine Animus is built on (vendor/anki).
    static let ankiVersion = "26.09.4"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}

// MARK: - Updates

/// Checks GitHub for a newer release. Only the version number is sent and
/// received: the request carries nothing about you or your cards.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let page: URL
        let notes: String
    }

    /// A newer version, shown as an alert.
    var available: Release?
    /// The answer to a check you asked for ("You're up to date", or a problem).
    var message: String?

    static let automaticKey = "updates.automatic"
    private static let lastCheckKey = "updates.lastCheck"

    /// "owner/repo" on GitHub, from Info.plist. No checks happen until it's set.
    private var repository: String? {
        (Bundle.main.infoDictionary?["AnimusUpdateRepository"] as? String).flatMap { $0.contains("/") ? $0 : nil }
    }

    /// At launch: at most once a day, and only if automatic checks are on.
    func checkIfDue() async {
        let defaults = AppDefaults.base
        guard defaults.object(forKey: Self.automaticKey) as? Bool ?? true else { return }
        let last = defaults.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        await check(quiet: true)
    }

    /// Animus › Check for Updates…
    func check(quiet: Bool = false) async {
        guard let repository, let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            if !quiet { message = "Update checks aren't set up in this copy of Animus yet." }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Animus/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                if !quiet { message = "You're up to date (Animus \(AppInfo.version))." }
                return
            }
            guard status == 200 else { throw URLError(.badServerResponse) }
            struct Latest: Decodable { let tag_name: String; let html_url: URL; let body: String?; let draft: Bool?; let prerelease: Bool? }
            let latest = try JSONDecoder().decode(Latest.self, from: data)
            let version = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(version, than: AppInfo.version), latest.draft != true, latest.prerelease != true {
                available = Release(version: version, page: latest.html_url, notes: latest.body ?? "")
            } else if !quiet {
                message = "You're up to date (Animus \(AppInfo.version))."
            }
        } catch {
            if !quiet { message = "Couldn't check for updates. Are you online?" }
        }
    }

    /// "0.10.0" is newer than "0.9.2".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

struct UpdateCommand: View {
    var body: some View {
        Button("Check for Updates…") { Task { await UpdateChecker.shared.check() } }
    }
}

/// Shows "a new version is available" and the answer to a manual check.
struct UpdateAlerts: ViewModifier {
    @State private var checker = UpdateChecker.shared

    func body(content: Content) -> some View {
        content
            .task { await checker.checkIfDue() }
            .alert("Animus \(checker.available?.version ?? "") is available",
                   isPresented: Binding(get: { checker.available != nil }, set: { if !$0 { checker.available = nil } })) {
                Button("Download") {
                    if let page = checker.available?.page { NSWorkspace.shared.open(page) }
                    checker.available = nil
                }
                Button("Later", role: .cancel) { checker.available = nil }
            } message: {
                let notes = checker.available?.notes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Text("You have \(AppInfo.version). Download the new version, then drag it into Applications to replace this one. Your cards and settings stay as they are."
                     + (notes.isEmpty ? "" : "\n\nWhat's new:\n" + String(notes.prefix(600))))
            }
            .alert("Check for Updates",
                   isPresented: Binding(get: { checker.message != nil }, set: { if !$0 { checker.message = nil } })) {
                Button("OK") { checker.message = nil }
            } message: {
                Text(checker.message ?? "")
            }
    }
}

extension View {
    func updateAlerts() -> some View { modifier(UpdateAlerts()) }
}
