import SwiftUI
import StudyCore

/// First-run setup, one idea per page with big titles, a progress bar and
/// Back / Next at the bottom (in the style of a new-PC setup).
///
/// New Anki users get a short, hands-on tour of how spaced repetition and
/// the app work; people who know Anki can skip it.
struct SetupView: View {
    @Environment(SyncManager.self) private var sync
    @Environment(Library.self) private var library
    @Environment(ProfileStore.self) private var profiles
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    @AppStorage(Pref.setupDone) private var setupDone = false

    @State private var step: Step = .welcome
    @State private var source: CardSource = .keep
    @State private var forward = true
    @State private var showingSignIn = false
    @State private var name = ""
    @State private var wantsTour: Bool?
    /// Set once the try-a-card lesson has been done, so Next lights up.
    @State private var triedCard = false

    private let ankiProfiles = Library.ankiProfiles()
    /// Shared decks found in Downloads (looked for when you reach the cards step).
    @State private var downloadedDecks: [Library.RecentDeckFile] = []

    enum Step: Int, CaseIterable {
        case welcome, aboutYou
        case memory, tryCard, numbers, decks, cardTypes
        case cards, look, keys, done

        var isLesson: Bool { [.memory, .tryCard, .numbers, .decks, .cardTypes].contains(self) }
    }

    enum CardSource: Hashable {
        case keep
        case profile(URL)
        case deckFile
        case downloaded(URL)
        case ankiWeb
        case fresh
    }

    /// The pages this person will see (the tour only if they asked for it).
    private var steps: [Step] {
        Step.allCases.filter { !$0.isLesson || wantsTour == true }
    }

    private var hasCards: Bool {
        if case .noCollection = library.state { return false }
        return true
    }

    private var isWorking: Bool {
        if case .loading = library.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(steps.firstIndex(of: step) ?? 0), total: Double(max(1, steps.count - 1)))
                .progressViewStyle(.linear)
                .tint(accent.color)
                .padding(.horizontal, 48)
                .padding(.top, 28)

            HStack(alignment: .center, spacing: step.isLesson ? 40 : 56) {
                if !step.isLesson {
                    Illustration(symbol: page.symbol)
                        .frame(width: 260)
                }
                VStack(alignment: .leading, spacing: 14) {
                    if step.isLesson, let lesson = lessonNumber {
                        Text("How it works · \(lesson) of 5")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent.color)
                    }
                    Text(page.title)
                        .font(.system(size: 34, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(page.subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    content
                        .padding(.top, 10)
                }
                .frame(maxWidth: step.isLesson ? 760 : 520, alignment: .leading)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .clipped()

            HStack {
                if step != .welcome {
                    Button("Back") { go(-1) }
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if step.isLesson {
                    Button("Skip the tour") { jump(to: .cards) }
                        .buttonStyle(.hoverable)
                }
                Button {
                    Task { await next() }
                } label: {
                    Text(nextTitle).frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .hoverGlow()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue || isWorking)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
            .background(.bar)
        }
        .background(Backdrop())
        .sheet(isPresented: $showingSignIn, onDismiss: {
            // Signed in (the download starts by itself), or cancelled: move on only if signed in.
            if sync.isSignedIn { go(1) }
        }) {
            SyncSignInSheet()
        }
        .onAppear {
            source = hasCards ? .keep : .ankiWeb
            let current = profiles.active.name
            name = current == "Me" || current == "New profile" ? "" : current
        }
    }

    private var lessonNumber: Int? {
        [Step.memory, .tryCard, .numbers, .decks, .cardTypes].firstIndex(of: step).map { $0 + 1 }
    }

    private var nextTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .done: "Start Studying"
        case .cards where source == .ankiWeb && !sync.isSignedIn: "Sign In…"
        default: "Next"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .aboutYou: !name.trimmingCharacters(in: .whitespaces).isEmpty && wantsTour != nil
        case .tryCard: triedCard
        default: true
        }
    }

    // MARK: Pages

    private var page: (symbol: String, title: String, subtitle: String) {
        let first = name.trimmingCharacters(in: .whitespaces)
        switch step {
        case .welcome:
            return ("hand.wave.fill", "Welcome to Animus",
                    "A friendlier way to use Anki, the flashcard app that helps you remember things for good. Setup takes about two minutes.")
        case .aboutYou:
            return ("person.crop.circle.fill", "First, a little about you",
                    "This makes your profile: your own cards, progress and settings.")
        case .memory:
            return ("brain.head.profile", "Why flashcards like these work",
                    "You forget most new things within days, unless you're reminded at the right moment.")
        case .tryCard:
            return ("rectangle.on.rectangle", "Try a card",
                    "Read the question, think of the answer, then reveal it and say how it went.")
        case .numbers:
            return ("number.square", "The three numbers",
                    "Every day, Home tells you what's waiting. Here's what each number means.")
        case .decks:
            return ("rectangle.stack", "Decks and sections",
                    "Cards live in decks, like folders. Big decks can have sections inside.")
        case .cardTypes:
            return ("square.grid.2x2", "Kinds of card",
                    "Different kinds suit different things. You pick one each time you add a card.")
        case .cards:
            return ("rectangle.stack.fill", "Where are your cards?",
                    "Bring your cards from AnkiWeb or the Anki app, open a deck file, or start fresh.")
        case .look:
            return ("paintpalette.fill", "Make it yours",
                    "Pick how the app looks. You'll see the changes straight away.")
        case .keys:
            return ("keyboard.fill", "Study without the mouse",
                    "A few keys are all you need. Buttons work too.")
        case .done:
            return ("checkmark.seal.fill", first.isEmpty ? "You're all set" : "You're all set, \(first)",
                    "Your cards are on Home. Study a little every day and the app plans the rest.")
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 12) {
                Explainer(symbol: "graduationcap.fill", color: .blue, title: "Built for students",
                          text: "Learn what spaced repetition is and how to use it, without the jargon.")
                Explainer(symbol: "arrow.triangle.2.circlepath", color: .green, title: "Works with Anki",
                          text: "Your cards stay in Anki's format and sync with AnkiWeb, the Anki app and your phone.")
            }
        case .aboutYou:
            aboutYou
        case .memory:
            MemoryLesson()
        case .tryCard:
            TryCardLesson(done: $triedCard)
        case .numbers:
            NumbersLesson()
        case .decks:
            DecksLesson()
        case .cardTypes:
            CardTypesLesson()
        case .cards:
            cardSources
        case .look:
            AppearancePicker()
        case .keys:
            VStack(alignment: .leading, spacing: 12) {
                KeyRow(keys: ["Space"], text: "Show the answer, then grade Good")
                KeyRow(keys: ["1", "2", "3", "4"], text: "Again, Hard, Good, Easy")
                KeyRow(keys: ["⌘", "Z"], text: "Undo the last grade")
                KeyRow(keys: ["Esc"], text: "Stop studying")
                KeyRow(keys: ["Return"], text: "Start studying the selected deck")
            }
        case .done:
            VStack(alignment: .leading, spacing: 12) {
                Explainer(symbol: "person.crop.circle", color: .purple, title: "Your profile: \(profiles.active.name)",
                          text: "Sharing this Mac, or keeping subjects apart? Add another profile from the name at the top of Home.")
                if sync.isSignedIn {
                    Explainer(symbol: "checkmark.icloud", color: .green, title: "Syncing with AnkiWeb",
                              text: "Your cards download in the background. Pictures can take a few minutes the first time.")
                }
                Explainer(symbol: "questionmark.circle", color: .blue, title: "Need a reminder?",
                          text: "Run this tour again any time from Preferences.")
            }
        }
    }

    private var aboutYou: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What should we call you?").font(.headline)
                TextField("Your name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .frame(maxWidth: 320)
                Text("Sharing this Mac, or want medicine and languages kept apart? You can add more profiles later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Have you used Anki before?").font(.headline)
                SourceRow(symbol: "sparkles", title: "I'm new to this",
                          subtitle: "Show me how it works. A 2-minute tour with a card to try",
                          selected: wantsTour == true) { wantsTour = true }
                SourceRow(symbol: "checkmark.circle", title: "I've used Anki before",
                          subtitle: "Skip the tour, I know the basics", selected: wantsTour == false) { wantsTour = false }
            }
        }
    }

    private var cardSources: some View {
        VStack(spacing: 8) {
            if hasCards {
                SourceRow(symbol: "checkmark.circle", title: "Keep the cards already here",
                          subtitle: "Carry on where you left off", selected: source == .keep) {
                    source = .keep
                }
            }
            SourceRow(symbol: "icloud.and.arrow.down",
                      title: sync.isSignedIn ? "Syncing with AnkiWeb as \(sync.username ?? "you")" : "Sign in to AnkiWeb",
                      subtitle: "Use the same account as Anki on your phone or computer, and stay in sync",
                      selected: source == .ankiWeb) {
                source = .ankiWeb
            }
            ForEach(ankiProfiles, id: \.self) { profile in
                SourceRow(symbol: "square.on.square",
                          title: "Copy “\(profile.lastPathComponent)” from the Anki app",
                          subtitle: "Your Anki files are only copied, never changed",
                          selected: source == .profile(profile)) {
                    source = .profile(profile)
                }
            }
            ForEach(downloadedDecks, id: \.self) { file in
                SourceRow(symbol: "arrow.down.doc",
                          title: "Add “\(file.name)” from Downloads",
                          subtitle: file.detail,
                          selected: source == .downloaded(file.url)) {
                    source = .downloaded(file.url)
                }
            }
            SourceRow(symbol: "square.and.arrow.down",
                      title: downloadedDecks.isEmpty ? "Open a deck file (.apkg)" : "Open a different deck file…",
                      subtitle: "A shared deck from a friend, a course or the internet", selected: source == .deckFile) {
                source = .deckFile
            }
            SourceRow(symbol: "plus.rectangle.on.rectangle", title: "Start fresh",
                      subtitle: "An empty collection; make your own cards", selected: source == .fresh) {
                source = .fresh
            }
            if isWorking {
                ProgressView("Copying your cards…").padding(.top, 6)
            }
        }
        .task {
            // Off the main thread: the first time, macOS asks before Animus can look in Downloads.
            downloadedDecks = await Task.detached(priority: .userInitiated) { Library.recentDeckFiles() }.value
        }
    }

    // MARK: Navigation

    private func go(_ delta: Int) {
        guard let index = steps.firstIndex(of: step) else { return }
        let target = index + delta
        guard steps.indices.contains(target) else { return }
        forward = delta > 0
        withAnimation(.spring(duration: 0.4)) { step = steps[target] }
    }

    private func jump(to target: Step) {
        forward = true
        withAnimation(.spring(duration: 0.4)) { step = target }
    }

    private func next() async {
        switch step {
        case .aboutYou:
            profiles.rename(profiles.activeID, to: name)
            go(1)
        case .cards:
            switch source {
            case .keep: break
            case .profile(let url): await library.importCopy(ofProfile: url)
            case .fresh: if !hasCards { await library.startFresh() }
            case .ankiWeb:
                if !sync.isSignedIn {
                    if !hasCards { await library.startFresh() }
                    sync.attach(library)
                    showingSignIn = true
                    return // carries on once the sign-in sheet closes
                }
            case .deckFile:
                guard let message = await library.chooseAndImport() else { return }
                library.notice = message
            case .downloaded(let url):
                library.notice = await library.importPackage(url)
            }
            go(1)
        case .done:
            finish()
        default:
            go(1)
        }
    }

    private func finish() {
        if !hasCards {
            Task { await library.startFresh() }
        }
        withAnimation { setupDone = true }
    }
}

// MARK: - Pieces

private struct Illustration: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    let symbol: String

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.color.gradient.opacity(0.18))
                .frame(width: 240, height: 240)
            Circle()
                .fill(accent.color.gradient.opacity(0.25))
                .frame(width: 170, height: 170)
            Image(systemName: symbol)
                .font(.system(size: 76))
                .foregroundStyle(accent.color.gradient)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

private struct Backdrop: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [accent.color.opacity(0.10), .clear, accent.color.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

struct Explainer: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SourceRow: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    let symbol: String
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? accent.color : .secondary)
            }
            .padding(14)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? accent.color.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? accent.color.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.02)
    }
}

private struct KeyRow: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.callout.weight(.medium).monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.35)))
                }
            }
            .frame(width: 150, alignment: .leading)
            Text(text)
        }
    }
}
