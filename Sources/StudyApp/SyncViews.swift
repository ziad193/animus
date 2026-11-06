import AppKit
import SwiftUI
import StudyCore

/// The Sync button in the toolbar: shows what's happening, syncs on click.
struct SyncButton: View {
    @Environment(SyncManager.self) private var sync

    var body: some View {
        Button {
            Task { await sync.syncNow() }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .symbolEffect(.rotate, isActive: sync.isBusy || sync.mediaSyncing)
                if case .failed = sync.status {
                    Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 3, y: -2)
                } else if case .needsChoice = sync.status {
                    Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 3, y: -2)
                }
            }
        }
        .buttonStyle(.automatic)
        .help(sync.isSignedIn ? "Sync now · \(sync.summary)" : "Sync with AnkiWeb")
    }
}

/// Sheets and alerts for syncing, attached once to the main window.
struct SyncPresenter: ViewModifier {
    @Bindable var sync: SyncManager

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $sync.showingSignIn) { SyncSignInSheet() }
            .sheet(isPresented: Binding(get: { sync.isChoosingCopy }, set: { if !$0 { sync.dismissChoice() } })) {
                FullSyncChoice()
            }
            .alert("Sync problem", isPresented: Binding(get: { sync.failureMessage != nil },
                                                        set: { if !$0 { sync.clearFailure() } })) {
                Button("Try Again") { Task { await sync.syncNow() } }
                Button("OK", role: .cancel) {}
            } message: {
                Text(sync.failureMessage ?? "")
            }
            .alert("Message from the sync server", isPresented: Binding(get: { sync.serverMessage != nil },
                                                                         set: { if !$0 { sync.serverMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sync.serverMessage ?? "")
            }
    }
}

extension SyncManager {
    var isChoosingCopy: Bool {
        if case .needsChoice = status { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    func clearFailure() {
        if case .failed = status { dismissChoice() }
    }
}

extension View {
    func syncSheets(_ sync: SyncManager) -> some View { modifier(SyncPresenter(sync: sync)) }
}

// MARK: - Sign in

struct SyncSignInSheet: View {
    @Environment(SyncManager.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var server = ""
    @State private var ownServer = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync with AnkiWeb").font(.title2.weight(.semibold))
                    Text("Keep your cards and progress the same here, in Anki and on your phone.")
                        .foregroundStyle(.secondary)
                }
            }
            Text("AnkiWeb is the free sync service the official Anki apps use. Sign in with the same account. Your password goes only to AnkiWeb and isn't saved on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Email").font(.subheadline.weight(.medium))
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                Text("Password").font(.subheadline.weight(.medium)).padding(.top, 4)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit { Task { await signIn() } }
            }
            Toggle("I use my own sync server", isOn: $ownServer.animation())
            if ownServer {
                TextField("Server address, e.g. http://192.168.1.10:8080/", text: $server)
                    .textFieldStyle(.roundedBorder)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Link("Create a free AnkiWeb account", destination: URL(string: "https://ankiweb.net/account/signup")!)
                    .font(.callout)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await signIn() }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Sign In and Sync") }
                }
                .buttonStyle(.borderedProminent)
                .hoverGlow()
                .keyboardShortcut(.defaultAction)
                .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func signIn() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await sync.signIn(username: email.trimmingCharacters(in: .whitespaces), password: password,
                                  server: ownServer ? server : nil)
            password = ""
            dismiss()
            await sync.syncNow()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Which copy to keep

/// Shown when this Mac's cards and the server's can't be merged, e.g. the
/// first time you sync a collection, or after a big change like deleting a card type.
struct FullSyncChoice: View {
    @Environment(SyncManager.self) private var sync
    @Environment(Library.self) private var library

    var body: some View {
        let (uploadOK, downloadOK): (Bool, Bool) = {
            if case .needsChoice(let u, let d) = sync.status { return (u, d) }
            return (true, true)
        }()
        VStack(alignment: .leading, spacing: 16) {
            Label("Which cards should we keep?", systemImage: "arrow.left.arrow.right.circle.fill")
                .font(.title2.weight(.semibold))
            Text("This Mac and AnkiWeb both have cards, but they can't be merged this time. Pick the copy to keep; the other is replaced. If you mostly study in Anki or on your phone, choose AnkiWeb.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                choice(title: "Keep AnkiWeb's",
                       detail: "Download from AnkiWeb and replace the cards on this Mac.",
                       symbol: "icloud.and.arrow.down", enabled: downloadOK) {
                    Task { await sync.resolve(upload: false) }
                }
                choice(title: "Keep this Mac's",
                       detail: "Upload this Mac's \(totalCards) cards and replace what's on AnkiWeb.",
                       symbol: "icloud.and.arrow.up", enabled: uploadOK) {
                    Task { await sync.resolve(upload: true) }
                }
            }
            HStack {
                Text("Your other devices will get the kept copy next time they sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Decide Later") { sync.dismissChoice() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var totalCards: UInt32 {
        if case .ready(let decks) = library.state { return decks.reduce(0) { $0 + $1.totalCards } }
        return 0
    }

    private func choice(title: String, detail: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title).foregroundStyle(.tint)
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.02)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Preferences tab

struct SyncPreferences: View {
    @Environment(SyncManager.self) private var sync
    @AppStorage(SyncPref.automatic) private var automatic = true
    @AppStorage(SyncPref.media) private var media = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync").font(.headline)
            if sync.isSignedIn {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sync.username ?? "Signed in")
                        Text(sync.auth?.endpoint.map { "Server: \($0)" } ?? "AnkiWeb")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out") { sync.signOut() }
                }
                HStack {
                    Text(sync.summary).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Now") { Task { await sync.syncNow() } }
                        .disabled(sync.isBusy)
                }
            } else {
                HStack {
                    Text("Not signed in. Sign in to keep this Mac, Anki and your phone in step.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign In…") { sync.showingSignIn = true }
                }
            }
            Divider()
            row("Sync automatically", "When the app opens, after each study session, and every 30 minutes.", $automatic)
            row("Sync pictures and sounds", "Turn off to save space and data; cards still sync.", $media)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: Binding(get: { sync.showingSignIn }, set: { sync.showingSignIn = $0 })) { SyncSignInSheet() }
    }

    private func row(_ title: String, _ help: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: value).toggleStyle(.switch).labelsHidden()
        }
    }
}
