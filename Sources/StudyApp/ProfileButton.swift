import SwiftUI

/// Your name at the top of Home. Click to switch profile, add one, or rename.
struct ProfileButton: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.switchProfile) private var switchProfile
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 8) {
                Avatar(profile: profiles.active, size: 28)
                Text(profiles.active.name).font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.03)
        .tip("Switch profile, or add one for someone else or another subject")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ProfileList { id in
                showing = false
                switchProfile(id)
            }
        }
    }
}

private struct ProfileList: View {
    @Environment(ProfileStore.self) private var profiles
    let open: (String) -> Void

    @State private var adding = false
    @State private var renaming: Profile?
    @State private var deleting: Profile?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Profiles").font(.headline).padding(.horizontal, 8).padding(.top, 4)
            Text("Each has its own cards, progress, settings and AnkiWeb account.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 6)
            ForEach(profiles.profiles) { profile in
                HStack(spacing: 6) {
                    Button {
                        if profile.id != profiles.activeID { open(profile.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Avatar(profile: profile, size: 26)
                            Text(profile.name)
                            Spacer()
                            if profile.id == profiles.activeID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tip(profile.id == profiles.activeID ? "The profile you're using" : "Switch to \(profile.name)")
                    Button { newName = profile.name; renaming = profile } label: { Image(systemName: "pencil") }
                        .buttonStyle(.hoverable)
                        .tip("Rename")
                    if profiles.profiles.count > 1 {
                        Button { deleting = profile } label: { Image(systemName: "trash") }
                            .buttonStyle(.hoverable)
                            .disabled(profile.id == profiles.activeID)
                            .tip(profile.id == profiles.activeID
                                 ? "Switch to another profile first to delete this one"
                                 : "Delete this profile and its cards")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(profile.id == profiles.activeID ? Color.accentColor.opacity(0.12) : .clear))
            }
            Divider().padding(.vertical, 4)
            Button {
                newName = ""
                adding = true
            } label: {
                Label("Add Profile…", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.hoverable)
        }
        .padding(10)
        .frame(width: 300)
        .alert("New profile", isPresented: $adding) {
            TextField("Name", text: $newName)
            Button("Create") {
                let profile = profiles.add(named: newName)
                open(profile.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It starts empty and walks you through setup, where you can sign in to AnkiWeb or bring cards over.")
        }
        .alert("Rename profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { profiles.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Profile and Its Cards", role: .destructive) {
                if let deleting { profiles.delete(deleting.id) }
            }
        } message: {
            Text((deleting?.isOriginal == true
                  ? "This is your first profile. Its cards, settings, backups and sync sign-in will be removed from Animus. "
                  : "Its cards, settings, backups and sync sign-in will be removed from Animus. ")
                 + "The files go to the Bin, so you can get them back until you empty it. Anything synced to AnkiWeb stays on AnkiWeb.")
        }
    }
}

struct Avatar: View {
    let profile: Profile
    var size: CGFloat = 28

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        // A stable number from the id, so a profile keeps its colour.
        let n = profile.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[n % palette.count]
    }

    var body: some View {
        Text(profile.initial)
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color.gradient))
    }
}
