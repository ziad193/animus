import SwiftUI
import StudyCore
import WebKit

/// Everything that belongs to one profile: its cards, timer, exams and sync.
/// Switching profile swaps the whole session.
@MainActor
@Observable
final class ProfileSession {
    let id = UUID()
    let library = Library()
    let pomodoro = Pomodoro()
    let simpleTimer = SimpleTimer()
    let pomodoroTasks = PomodoroTasks()
    let studyClock = StudyClock()
    let exams = ExamStore()
    let sync = SyncManager()
}

@main
struct StudyAppMain: App {
    // The profile list comes first: it decides where everything else is read from.
    @State private var profiles = ProfileStore()
    @State private var session = ProfileSession()

    var body: some Scene {
        WindowGroup("Animus") {
            RootView()
                .frame(minWidth: 860, minHeight: 560)
                .overlay(alignment: .bottomLeading) { PerfMeterOverlay() }
                .profileScope(session, profiles: profiles, switchProfile: switchProfile)
                .environment(\.deleteCurrentProfile, deleteCurrentProfile)
                .onAppear { HitchLog.startIfDevBuild() }
        }
        .defaultSize(width: 1100, height: 720)
        // Always open the main window at launch, even if Animus was last quit
        // with no window open (otherwise you'd see only the menu bar).
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                UndoCommands(library: session.library)
            }
            CommandGroup(after: .appInfo) {
                UpdateCommand()
            }
            CommandGroup(replacing: .help) {
                HelpGuideCommand()
                Divider()
                HelpCommands(library: session.library, profiles: profiles)
            }
            CommandGroup(replacing: .newItem) {
                AddCardsCommand()
                ImportCommand(library: session.library)
                Divider()
                Menu("Use a Copy of Anki Profile") {
                    ForEach(Library.ankiProfiles(), id: \.self) { profile in
                        Button(profile.lastPathComponent) {
                            session.library.requestImport(ofProfile: profile)
                        }
                    }
                }
            }
        }

        // Opened by clicking a day on the heatmap.
        WindowGroup("Cards Studied", id: "day-cards", for: Int.self) { $offset in
            DayCardsWindow(offset: offset ?? 0)
                .frame(minWidth: 800, minHeight: 500)
                .profileScope(session, profiles: profiles, switchProfile: switchProfile)
        }
        .defaultSize(width: 1100, height: 700)

        // Help › Animus Help (⌘?), or the Help button on Home.
        Window("Animus Help", id: HelpWindow.id) {
            HelpGuideView()
                .frame(minWidth: 720, minHeight: 480)
                .profileScope(session, profiles: profiles, switchProfile: switchProfile)
        }
        .defaultSize(width: 860, height: 600)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .profileScope(session, profiles: profiles, switchProfile: switchProfile)
        }
    }

    /// Closes this profile's cards and opens another's.
    private func switchProfile(_ id: String) {
        guard id != profiles.activeID else { return }
        let old = session
        Task {
            await old.library.engine?.close()
            profiles.switchTo(id)
            CardWebView.reset()
            session = ProfileSession()
        }
    }

    /// Deletes the profile you're using (its files go to the Bin), then starts a
    /// fresh, empty profile that opens on the setup screen.
    private func deleteCurrentProfile() {
        let old = session
        let oldID = profiles.activeID
        Task {
            await old.library.engine?.close()
            let fresh = profiles.add(named: "New profile")
            profiles.switchTo(fresh.id)
            profiles.delete(oldID)
            CardWebView.reset()
            session = ProfileSession()
        }
    }
}

/// Puts a profile's session, settings store and theme around a window's content.
private struct ProfileScope: ViewModifier {
    let session: ProfileSession
    let profiles: ProfileStore
    let switchProfile: (String) -> Void

    func body(content: Content) -> some View {
        // Animus Dev only: a red strip saying so, at the top of every window.
        // Stacked above the content (not an inset), so pages that reach the
        // top, like studying with the tabs hidden, still sit below it.
        VStack(spacing: 0) {
            DevBuildBanner()
            ThemedContent(content: content)
        }
            .buttonStyle(.hoverBordered)
            .environment(session.library)
            .environment(session.pomodoro)
            .environment(session.simpleTimer)
            .environment(session.pomodoroTasks)
            .environment(session.studyClock)
            .environment(session.exams)
            .environment(session.sync)
            .environment(profiles)
            .environment(\.switchProfile, switchProfile)
            .defaultAppStorage(profiles.active.defaults)
            // No dark line through the toolbar, on every window. SwiftUI owns the
            // toolbar, so tell it not to draw that edge, and keep a watcher as a backup.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .overlay(alignment: .top) { ToolbarBackdrop() }
            .background(WindowTweaks().frame(width: 0, height: 0).allowsHitTesting(false))
            // A new profile rebuilds every screen from scratch.
            .id(session.id)
    }
}

/// Reads the theme from the profile's own settings.
private struct ThemedContent<Content: View>: View {
    let content: Content
    @AppStorage(Pref.appearance) private var appearance = AppearanceChoice.system
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue

    var body: some View {
        content
            .preferredColorScheme(appearance.colorScheme)
            .tint(accent.color)
    }
}

extension View {
    fileprivate func profileScope(_ session: ProfileSession, profiles: ProfileStore,
                                  switchProfile: @escaping (String) -> Void) -> some View {
        modifier(ProfileScope(session: session, profiles: profiles, switchProfile: switchProfile))
    }
}

private struct SwitchProfileKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

private struct DeleteCurrentProfileKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Deletes the open profile and starts setup for a new one.
    var deleteCurrentProfile: () -> Void {
        get { self[DeleteCurrentProfileKey.self] }
        set { self[DeleteCurrentProfileKey.self] = newValue }
    }

    /// Opens another profile.
    var switchProfile: (String) -> Void {
        get { self[SwitchProfileKey.self] }
        set { self[SwitchProfileKey.self] = newValue }
    }
}

/// File › Add Cards… (⌘N), plus Back and Forward. Shortcuts only; the main
/// way in is the visible tab and buttons.
private struct AddCardsCommand: View {
    var body: some View {
        Button("Add Cards…") { NotificationCenter.default.post(name: .iterumShowAddCards, object: nil) }
            .keyboardShortcut("n")
        Button("Back") { NotificationCenter.default.post(name: .iterumGoBack, object: nil) }
            .keyboardShortcut("[")
        Button("Forward") { NotificationCenter.default.post(name: .iterumGoForward, object: nil) }
            .keyboardShortcut("]")
    }
}

private struct ImportCommand: View {
    let library: Library
    var body: some View {
        Button("Import…") {
            Task {
                if let message = await library.chooseAndImport() { library.notice = message }
            }
        }
        .keyboardShortcut("i")
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(SyncManager.self) private var sync
    @AppStorage(Pref.setupDone) private var setupDone = false
    @AppStorage(Pref.connector) private var connectorOn = false

    var body: some View {
        Group {
            if !setupDone {
                SetupView()
                    .transition(.opacity)
            } else {
                mainContent
            }
        }
        // Start a card view loading now, so the first card shows instantly later.
        .onAppear { CardWebView.prepare() }
        // At most once a day: is there a newer Animus on GitHub?
        .updateAlerts()
        // Sync once the collection is open (if signed in and automatic sync is on).
        .task(id: library.isReady) {
            sync.attach(library)
            if library.isReady { await sync.syncIfAutomatic() }
        }
        // Test only: Claude's way into Animus (see Connector.swift).
        .task(id: "\(library.isReady) \(connectorOn)") {
            Connector.shared.update(library: library, switchedOn: connectorOn)
        }
        .alert("Animus",
               isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
            Button("OK") { library.notice = nil }
        } message: {
            Text(library.notice ?? "")
        }
        .confirmationDialog(
            "Replace the cards in this app?",
            isPresented: Binding(get: { library.pendingProfile != nil },
                                 set: { if !$0 { library.pendingProfile = nil } }),
            presenting: library.pendingProfile
        ) { profile in
            Button("Use “\(profile.lastPathComponent)”", role: .destructive) {
                Task { await library.importCopy(ofProfile: profile) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("This app's cards and any studying done here will be replaced with a fresh copy of “\(profile.lastPathComponent)” from Anki. Your Anki files aren't changed.")
        }
    }

    @ViewBuilder private var mainContent: some View {
        switch library.state {
        case .noCollection:
            WelcomeView()
        case .loading:
            ProgressView("Opening your cards…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let decks):
            DecksView(decks: decks)
        case .failed(let message):
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }
}

/// Temporary first-launch screen. The full set-up flow comes in a later phase.
struct WelcomeView: View {
    @Environment(Library.self) private var library
    private let profiles = Library.ankiProfiles()

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("Welcome to Animus")
                    .font(.largeTitle.weight(.semibold))
                Text("Flashcards that remember what you forget.\nChoose where your cards come from to get started.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(profiles, id: \.self) { profile in
                    WelcomeOption(icon: "square.on.square",
                                  title: "Use a copy of “\(profile.lastPathComponent)”",
                                  subtitle: "Your decks from the Anki app") {
                        Task { await library.importCopy(ofProfile: profile) }
                    }
                }
                WelcomeOption(icon: "sparkles",
                              title: "Start fresh",
                              subtitle: "An empty collection") {
                    Task { await library.startFresh() }
                }
            }
            .frame(width: 380)

            if !profiles.isEmpty {
                Label("Your Anki files are only copied, never changed.", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeOption: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Edit › Undo and Redo. While you're typing in a box they undo the typing;
/// otherwise they undo the last change to your cards (a grade, an edit, a delete…).
private struct UndoCommands: View {
    let library: Library

    var body: some View {
        Button(library.undoStatus.undo.map { "Undo \($0)" } ?? "Undo") {
            if !Self.sendToTextBox("undo:") { Task { await library.undoFromMenu() } }
        }
        .keyboardShortcut("z", modifiers: .command)
        Button(library.undoStatus.redo.map { "Redo \($0)" } ?? "Redo") {
            if !Self.sendToTextBox("redo:") { Task { await library.redoFromMenu() } }
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    /// Hands Undo/Redo to the text box being typed in, if there is one.
    @MainActor
    private static func sendToTextBox(_ action: String) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return false }
        var view: NSView? = responder
        var editing = responder is NSText
        while !editing, let current = view {
            if current is WKWebView { editing = true }
            view = current.superview
        }
        guard editing else { return false }
        return NSApp.sendAction(Selector((action)), to: nil, from: nil)
    }
}
