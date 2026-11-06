import Foundation
import Observation

/// Where the current profile keeps its settings. Everything the app
/// remembers (theme, exams, study time, sync sign-in…) goes here, so each
/// profile is completely separate.
enum AppDefaults {
    nonisolated(unsafe) static var current: UserDefaults = .standard
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyApp", isDirectory: true)
        return isOriginal ? base : base.appendingPathComponent("Profiles/\(id)", isDirectory: true)
    }

    var defaults: UserDefaults {
        isOriginal ? .standard : (UserDefaults(suiteName: "com.ziad.studyapp.profile.\(id)") ?? .standard)
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
        let d = UserDefaults.standard
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

    /// Deletes a profile's cards and settings. The original profile and the open one can't be deleted.
    func delete(_ id: String) {
        guard id != activeID, let profile = profiles.first(where: { $0.id == id }), !profile.isOriginal else { return }
        try? FileManager.default.removeItem(at: profile.folder)
        UserDefaults.standard.removePersistentDomain(forName: "com.ziad.studyapp.profile.\(id)")
        let plist = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/com.ziad.studyapp.profile.\(id).plist")
        try? FileManager.default.removeItem(at: plist)
        profiles.removeAll { $0.id == id }
        save()
    }

    private func save() {
        Self.currentFolder = active.folder
        Self.currentID = activeID
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
        UserDefaults.standard.set(activeID, forKey: Self.activeKey)
    }
}
