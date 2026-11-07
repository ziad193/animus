import Foundation
import Observation
import Security

// Animus+ groundwork: the plan you're on, the product key, the list of Plus
// features, and the one question every part of the app asks ("is this
// unlocked?"). There's no Animus+ server yet, so nothing here goes online:
// `PlusServer` reports that checking isn't available, and no key is ever saved
// until a server has confirmed it.

// MARK: - Features

/// Everything Animus+ will add. Free features never appear here: they stay free.
enum PlusFeature: String, CaseIterable, Identifiable {
    /// Drop in lecture slides or a PDF; cards are made from them.
    case lectureToCards
    /// Ask questions about your cards and slides, like a tutor.
    case askAnimus
    /// Fill-in-the-blank cards made from your own notes.
    case clozeFromNotes
    /// Picture-hiding cards with the labels found for you.
    case autoOcclusion
    /// A photo or picture (textbook page, histology slide) turned into cards.
    case pictureToCards
    /// Tidy up a messy card: rewrite it, or split it into several.
    case fixCard
    /// After you get a card wrong: why, and a way to remember it.
    case explainMistakes
    /// A day-by-day plan for an exam, with your weakest areas.
    case examPlan
    /// Exam-style single-best-answer questions written from your own cards.
    case practiceQuestions
    /// A short written summary of your week's studying.
    case weeklyReport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lectureToCards: "Make cards from a lecture"
        case .askAnimus: "Ask Animus"
        case .clozeFromNotes: "Fill-in-the-blank from your notes"
        case .autoOcclusion: "Automatic picture labels"
        case .pictureToCards: "Cards from a photo"
        case .fixCard: "Fix my card"
        case .explainMistakes: "Why did I get that wrong?"
        case .examPlan: "Exam plan"
        case .practiceQuestions: "Practice questions"
        case .weeklyReport: "Weekly report"
        }
    }

    /// The big four, shown in Setup; the rest are listed in About Animus+.
    var isHeadline: Bool {
        switch self {
        case .lectureToCards, .askAnimus, .examPlan, .practiceQuestions: true
        default: false
        }
    }

    var symbol: String {
        switch self {
        case .lectureToCards: "doc.richtext"
        case .askAnimus: "bubble.left.and.text.bubble.right"
        case .clozeFromNotes: "text.badge.plus"
        case .autoOcclusion: "photo.badge.checkmark"
        case .pictureToCards: "camera.viewfinder"
        case .fixCard: "wand.and.stars"
        case .explainMistakes: "lightbulb"
        case .examPlan: "calendar.badge.checkmark"
        case .practiceQuestions: "checklist"
        case .weeklyReport: "chart.line.text.clipboard"
        }
    }

    var detail: String {
        switch self {
        case .lectureToCards:
            "Drop in your slides or a PDF and cards appear as they're made. Every card shows the slide it came from, so checking takes seconds."
        case .askAnimus:
            "Stuck on a card? Ask about it, or about your lecture slides, and get an answer in plain English."
        case .clozeFromNotes:
            "Paste your notes and get fill-in-the-blank cards, ready to check and keep."
        case .autoOcclusion:
            "Add a labelled diagram and Animus hides each label for you, ready to study."
        case .pictureToCards:
            "Photograph a textbook page or a histology slide and get cards from it."
        case .fixCard:
            "One click on a messy card: a cleaner rewrite, or a split into separate cards. Great for cards you keep forgetting."
        case .explainMistakes:
            "When you press Again, a short note on why, plus a way to remember it next time."
        case .examPlan:
            "Pick your exam and Animus works out how much to do each day, and shows your weakest sections."
        case .practiceQuestions:
            "Exam-style questions written from your own cards, to test yourself before the real thing."
        case .weeklyReport:
            "A short summary of your week: what's going well, and what's slipping."
        }
    }
}

// MARK: - Plan

/// What you're on. Saved (without the key itself) so Animus knows offline.
struct PlusLicense: Codable, Equatable {
    enum Kind: String, Codable { case monthly, yearly, lifetime, trial }
    var kind: Kind
    /// When it renews or runs out; nil for lifetime.
    var renews: Date?
    /// The key's last five characters, to show which key it is.
    var keyEnding: String
    /// When the server last confirmed it.
    var checked: Date
}

/// The answer from checking a key.
enum LicenseCheck: Equatable {
    case active(PlusLicense)
    case expired
    case invalid
    /// Can't check right now (no server yet, or offline).
    case unavailable(String)
}

// MARK: - Product keys

enum ProductKey {
    /// "abcde fghij-..." → "ABCDE-FGHIJ-KLMNO-PQRST", or nil if it isn't shaped like a key.
    /// Keys are four groups of five letters and numbers.
    static func normalised(_ raw: String) -> String? {
        let chars = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard chars.count == 20, chars.allSatisfy({ $0.isASCII }) else { return nil }
        let groups = stride(from: 0, to: 20, by: 5).map { start -> String in
            let a = chars.index(chars.startIndex, offsetBy: start)
            return String(chars[a..<chars.index(a, offsetBy: 5)])
        }
        return groups.joined(separator: "-")
    }
}

/// Where the key is kept: the Mac's keychain, never a plain file. One key per
/// Mac user, shared by every profile. A test copy keeps its own.
enum PlusKeychain {
    private static var service: String { Library.isTestCollection ? "Animus Plus (test)" : "Animus Plus" }
    private static let account = "product-key"

    static func load() -> String? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
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

// MARK: - Server

/// Talks to the Animus+ server: checks keys (and later passes AI requests
/// along). The server's address comes from Info.plist (`AnimusPlusServer`);
/// with none set, as now, it never goes online and says checking isn't
/// available yet.
struct PlusServer {
    let base: URL?

    static let current = PlusServer(
        base: (Bundle.main.infoDictionary?["AnimusPlusServer"] as? String).flatMap(URL.init(string:)))

    var isConfigured: Bool { base != nil }

    func check(_ key: String) async -> LicenseCheck {
        guard isConfigured else {
            return .unavailable("Animus+ keys can't be checked yet. You'll be able to activate here when Animus+ launches.")
        }
        // The real request goes here once the server exists:
        // POST {base}/license/check with the key, answer → LicenseCheck.
        return .unavailable("Couldn't reach Animus+. Are you online?")
    }
}

// MARK: - Store

/// The one place that knows your plan. Every Plus feature asks `isUnlocked`.
@MainActor
@Observable
final class PlusStore {
    static let shared = PlusStore()

    private(set) var license: PlusLicense?
    /// Animus Dev only: pretend Animus+ is on, to build and try Plus screens.
    var devPreview: Bool {
        didSet { AppDefaults.base.set(devPreview, forKey: Self.previewKey) }
    }
    /// Settings › Animus › Show Animus+ suggestions. Off hides Plus buttons,
    /// badges and prompts from free users (the Settings link stays).
    var showPrompts: Bool {
        didSet { AppDefaults.base.set(showPrompts, forKey: Self.promptsKey) }
    }

    private static let licenseKey = "plus.license"
    private static let previewKey = "plus.devPreview"
    private static let promptsKey = "plus.showPrompts"
    private static let explainKey = "plus.explainMistakes"
    /// Settings › Animus: show "Why did I get that wrong?" after Again.
    var explainMistakes: Bool {
        didSet { AppDefaults.base.set(explainMistakes, forKey: Self.explainKey) }
    }
    /// How long Animus+ keeps working offline after its last successful check.
    static let offlineGrace: TimeInterval = 14 * 24 * 3600

    private init() {
        if let data = AppDefaults.base.data(forKey: Self.licenseKey) {
            license = try? JSONDecoder().decode(PlusLicense.self, from: data)
        }
        devPreview = DevBuildBanner.isDevBuild && AppDefaults.base.bool(forKey: Self.previewKey)
        showPrompts = AppDefaults.base.object(forKey: Self.promptsKey) as? Bool ?? true
        explainMistakes = AppDefaults.base.object(forKey: Self.explainKey) as? Bool ?? true
    }

    /// Whether Plus buttons and badges appear around the app: always with
    /// Animus+, and for free users unless they've turned suggestions off.
    var showsPrompts: Bool { hasPlus || showPrompts }

    /// Animus+ screens that aren't finished only show in Animus Dev.
    var showsPreviews: Bool { DevBuildBanner.isDevBuild }

    var hasPlus: Bool {
        if devPreview { return true }
        guard let license else { return false }
        if let renews = license.renews, renews < Date() { return false }
        return Date().timeIntervalSince(license.checked) < Self.offlineGrace
    }

    func isUnlocked(_ feature: PlusFeature) -> Bool { hasPlus }

    /// For Settings: "Free", "Animus+ (yearly)", and so on.
    var planTitle: String {
        if devPreview { return "Animus+ (dev preview)" }
        guard hasPlus, let license else { return "Free" }
        switch license.kind {
        case .monthly: return "Animus+ (monthly)"
        case .yearly: return "Animus+ (yearly)"
        case .lifetime: return "Animus+ (lifetime)"
        case .trial: return "Animus+ (free trial)"
        }
    }

    /// Checks a key with the server; only a confirmed key is saved.
    /// Returns what to tell the person.
    func activate(_ raw: String) async -> String {
        guard let key = ProductKey.normalised(raw) else {
            return "That doesn't look like an Animus+ key. Keys look like XXXXX-XXXXX-XXXXX-XXXXX."
        }
        switch await PlusServer.current.check(key) {
        case .active(let found):
            PlusKeychain.save(key)
            store(found)
            return "Animus+ is on. Thank you!"
        case .expired:
            return "That key has expired. Renew Animus+ to keep using it."
        case .invalid:
            return "That key wasn't recognised. Check it and try again."
        case .unavailable(let why):
            return why
        }
    }

    /// Turns Animus+ off on this Mac (keeps nothing behind).
    func signOut() {
        PlusKeychain.delete()
        store(nil)
    }

    /// Re-checks the saved key about once a day. Does nothing without a server.
    func refreshIfDue() async {
        guard PlusServer.current.isConfigured, let license,
              Date().timeIntervalSince(license.checked) > 24 * 3600,
              let key = PlusKeychain.load() else { return }
        switch await PlusServer.current.check(key) {
        case .active(let found): store(found)
        case .expired, .invalid: store(nil)
        case .unavailable: break // offline: keep going within the grace period
        }
    }

    private func store(_ new: PlusLicense?) {
        license = new
        if let new, let data = try? JSONEncoder().encode(new) {
            AppDefaults.base.set(data, forKey: Self.licenseKey)
        } else {
            AppDefaults.base.removeObject(forKey: Self.licenseKey)
        }
    }
}
