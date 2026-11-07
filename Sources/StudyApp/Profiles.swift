import Foundation
import Observation

/// Where the current profile keeps its settings. Everything the app
/// remembers (theme, exams, study time, sync sign-in…) goes here, so each
/// profile is completely separate.
enum AppDefaults {
    nonisolated(unsafe) static var current: UserDefaults = base

    /// The app's main settings store. Test collections get a separate one, so
    /// a test run can never change the real app's settings or profiles.
    static let base: UserDefaults = {
        if Library.isTestCollection { return UserDefaults(suiteName: "com.ziad.studyapp.test") ?? .standard }
        carryOverOldSettings()
        return .standard
    }()

    /// The app used to be "Iterum" with the ID com.ziad.studyapp, whose settings
    /// macOS keeps under that name. The first time Animus opens, copy them across
    /// so nothing is lost (theme, exams, study time, profiles, setup done…).
    /// The old copy is left untouched.
    private static func carryOverOldSettings() {
        let oldID = "com.ziad.studyapp"
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != oldID,
              !defaults.bool(forKey: "migratedFromIterum"),
              let old = defaults.persistentDomain(forName: oldID), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "migratedFromIterum")
    }
}

/// A person (or subject) with their own cards, settings and sync account,
/// like profiles in Anki.
struct Profile: Codable, Identifiable, Hashable {
    let id: String
    var name: String

    /// The first profile keeps the original files and settings exactly where they were.
    static let originalID = "default"
    var isOriginal: Bool { id == Self.originalID }

    var folder: URL {
        // A test collection keeps every profile inside its own test folder, so
        // nothing done in a test (like deleting a profile) can reach real files.
        let base = Library.isTestCollection
            ? URL(fileURLWithPath: ProcessInfo.processInfo.environment["ITERUM_DATA_FOLDER"] ?? "", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StudyApp", isDirectory: true)
        return isOriginal ? base : base.appendingPathComponent("Profiles/\(id)", isDirectory: true)
    }

    var defaults: UserDefaults {
        isOriginal ? AppDefaults.base : (UserDefaults(suiteName: "com.ziad.studyapp.profile.\(id)") ?? .standard)
    }

    /// e.g. "Z" for the avatar circle.
    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
}

/// The list of profiles and which one is open. This list itself is shared
/// by all profiles.
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [Profile] = []
    private(set) var activeID: String

    private static let listKey = "profiles.list"
    private static let activeKey = "profiles.active"

    init() {
        let d = AppDefaults.base
        var list: [Profile]
        if let data = d.data(forKey: Self.listKey), let saved = try? JSONDecoder().decode([Profile].self, from: data), !saved.isEmpty {
            list = saved
        } else {
            // First launch with profiles: the existing cards become the first profile.
            list = [Profile(id: Profile.originalID, name: NSFullUserName().components(separatedBy: " ").first ?? "Me")]
        }
        let saved = d.string(forKey: Self.activeKey) ?? Profile.originalID
        let activeID = list.contains { $0.id == saved } ? saved : list[0].id
        profiles = list
        self.activeID = activeID
        AppDefaults.current = active.defaults
        save()
    }

    private func active(in list: [Profile]) -> Profile {
        list.first { $0.id == activeID } ?? list[0]
    }

    var active: Profile { active(in: profiles) }

    /// The folder for the current profile (read by code outside the main actor too).
    nonisolated(unsafe) static var currentFolder: URL = Profile(id: Profile.originalID, name: "").folder
    nonisolated(unsafe) static var currentID: String = Profile.originalID

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = trimmed
        save()
    }

    /// Adds a profile; it starts with no cards and runs the setup the first time it opens.
    @discardableResult
    func add(named name: String) -> Profile {
        let profile = Profile(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "New profile" : name)
        profiles.append(profile)
        save()
        return profile
    }

    func switchTo(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        AppDefaults.current = active.defaults
        Self.currentFolder = active.folder
        save()
    }

    /// Moves a profile's cards, settings and backups to the Bin (so it can be
    /// recovered), and forgets its sync sign-in. The open profile can't be
    /// deleted (switch first), and there must always be one profile left.
    func delete(_ id: String) {
        guard id != activeID, profiles.count > 1, let profile = profiles.first(where: { $0.id == id }) else { return }
        let fm = FileManager.default
        if profile.isOriginal {
            // The first profile's files sit in the main folder, next to the other
            // profiles' folders, so move only its own things.
            let base = profile.folder
            let label = Library.isTestCollection ? "deleted test profile" : "deleted profile"
            let bundle = base.appendingPathComponent("\(profile.name) (\(label))", isDirectory: true)
            try? fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            let items = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for item in items where item.lastPathComponent != "Profiles" && item != bundle {
                try? fm.moveItem(at: item, to: bundle.appendingPathComponent(item.lastPathComponent))
            }
            try? fm.trashItem(at: bundle, resultingItemURL: nil)
            // Its settings share the app's main store with the profile list: clear only its own.
            let keep = ["profiles.", "updates.", "migratedFromIterum", "NS", "Apple"]
            for key in AppDefaults.base.dictionaryRepresentation().keys
            where !keep.contains(where: { key.hasPrefix($0) }) {
                AppDefaults.base.removeObject(forKey: key)
            }
        } else {
            try? fm.trashItem(at: profile.folder, resultingItemURL: nil)
            UserDefaults.standard.removePersistentDomain(forName: "com.ziad.studyapp.profile.\(id)")
            let plist = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Preferences/com.ziad.studyapp.profile.\(id).plist")
            try? fm.removeItem(at: plist)
        }
        SyncKeychain.delete(account: id)
        profiles.removeAll { $0.id == id }
        save()
    }

    private func save() {
        Self.currentFolder = active.folder
        Self.currentID = activeID
        if let data = try? JSONEncoder().encode(profiles) {
            AppDefaults.base.set(data, forKey: Self.listKey)
        }
        AppDefaults.base.set(activeID, forKey: Self.activeKey)
    }
}
