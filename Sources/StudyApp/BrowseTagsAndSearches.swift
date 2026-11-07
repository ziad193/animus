import StudyCore
import SwiftUI

// MARK: - Saved searches

/// Your saved searches as chips under the filters. Click one to show it; the
/// small x removes it. They're kept in the collection (Anki's "savedFilters"),
/// so they sync with Anki desktop's saved searches.
struct SavedSearchesRow: View {
    let saved: [String: String]
    let current: String
    let open: (String) -> Void
    let remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.secondary)
                ForEach(saved.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { name in
                    let search = saved[name] ?? ""
                    HStack(spacing: 4) {
                        Button(name) { open(search) }
                            .buttonStyle(.plain)
                        Button {
                            remove(name)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .tip("Remove this saved search")
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(current == search ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                    .tip(search)
                }
            }
        }
    }
}

// MARK: - Tag manager

/// Every tag in the collection, with how to search, rename and delete them.
/// Renaming a parent (e.g. "cardio") renames its sub-tags too ("cardio::ecg"),
/// as Anki does.
struct TagManagerSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let show: (String) -> Void
    let done: (String, Bool) -> Void

    @State private var tags: [String] = []
    @State private var filter = ""
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?
    @State private var message: String?
    @State private var error: String?

    private var shown: [String] {
        let word = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return word.isEmpty ? tags : tags.filter { $0.lowercased().contains(word) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tags", systemImage: "tag").font(.title2.weight(.semibold))
            Text("Click a tag to show its cards. Renaming a tag also renames its sub-tags.")
                .foregroundStyle(.secondary)
            TextField("Filter tags", text: $filter).textFieldStyle(.roundedBorder)
            List {
                if shown.isEmpty {
                    Text(tags.isEmpty ? "No tags yet." : "No tags match.").foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.self) { tag in
                    HStack {
                        Button {
                            show("tag:\"\(tag)\"")
                            dismiss()
                        } label: {
                            Label(tag, systemImage: tag.contains("::") ? "tag.circle" : "tag")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tip("Show cards tagged \(tag)")
                        Button("Rename") {
                            newName = tag
                            renaming = tag
                        }
                        .controlSize(.small)
                        Button(role: .destructive) {
                            deleting = tag
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                        .tip("Delete this tag from every note")
                    }
                }
            }
            .frame(minHeight: 300)
            if let message { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            HStack {
                Button {
                    Task { await clearUnused() }
                } label: {
                    Label("Clear Unused Tags", systemImage: "sparkles")
                }
                .tip("Remove tags no note uses any more")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 600)
        .task { await reload() }
        .alert("Rename tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let old = renaming { Task { await rename(old) } }
            }
        } message: {
            Text("Use :: for a sub-tag, e.g. cardio::ecg. Spaces aren't allowed in tags.")
        }
        .confirmationDialog("Delete the tag “\(deleting ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Tag", role: .destructive) {
                if let tag = deleting { Task { await delete(tag) } }
            }
        } message: {
            Text("It's removed from every note that has it, and from its sub-tags. The notes themselves stay.")
        }
    }

    private func reload() async {
        tags = ((try? await library.engine?.allTags()) ?? [])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func rename(_ old: String) async {
        let new = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard let engine = library.engine, !new.isEmpty, new != old else { return }
        do {
            let count = try await engine.renameTag(old, to: new)
            report("Renamed on \(count) note\(count == 1 ? "" : "s").")
            done("Rename Tag", true)
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ tag: String) async {
        guard let engine = library.engine else { return }
        do {
            let count = try await engine.deleteTag(tag)
            report("Removed from \(count) note\(count == 1 ? "" : "s").")
            done("Delete Tag", true)
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func clearUnused() async {
        guard let engine = library.engine else { return }
        do {
            let count = try await engine.clearUnusedTags()
            report(count == 0 ? "Every tag is in use." : "Cleared \(count) unused tag\(count == 1 ? "" : "s").")
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func report(_ text: String) {
        error = nil
        message = text
    }
}
