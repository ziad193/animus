import SwiftUI

/// Help › Animus Help (⌘?), also the Help button on Home: a short guide.
enum HelpWindow {
    static let id = "help"
}

private struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let intro: String
    let points: [(String, String)]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#if os(iOS)
private let topics = phoneTopics
#else
private let topics = macTopics
#endif

private let macTopics: [HelpTopic] = [
    HelpTopic(
        id: "start", title: "Getting started", symbol: "sparkles",
        intro: "Animus shows you each card just before you'd forget it. A few minutes every day beats a long session once a week.",
        points: [
            ("Home", "Shows what's waiting today, your decks, your study days and any exam countdowns. Click a deck's Study button to begin."),
            ("Decks and sections", "A deck can hold sections (subdecks). Studying a deck includes all of its sections."),
            ("New, Learning, Review", "Blue cards are new, orange ones you're still learning, green ones are coming back for review."),
            ("Getting cards", "Make your own in Add Cards, open a deck file (.apkg or .colpkg) with File › Import, or sign in to AnkiWeb to bring over your Anki cards."),
        ]),
    HelpTopic(
        id: "study", title: "Studying", symbol: "graduationcap",
        intro: "Look at the question, try to remember the answer, then show it and say how it went.",
        points: [
            ("Show the answer", "Press Space or Return, or click Show Answer."),
            ("Again (1)", "You forgot. You'll see it again in a few minutes."),
            ("Hard (2)", "You got it, but it was a struggle. It comes back a little sooner."),
            ("Good (3)", "You remembered. Space or Return picks this too."),
            ("Easy (4)", "Too easy. It waits much longer before coming back."),
            ("Changed your mind?", "⌘Z undoes your last answer."),
            ("Finish", "Press Esc or click Done at any time. Your progress is saved as you go."),
        ]),
    HelpTopic(
        id: "cards", title: "While a card is showing", symbol: "rectangle.on.rectangle",
        intro: "The bar above the card has buttons for the card in front of you. Each also has a key.",
        points: [
            ("Edit (E)", "Fix a typo or change the card."),
            ("Flag (⌘1–⌘7)", "Colour-code a card to find it later in Browse. ⌘0 removes the flag."),
            ("Mark (*)", "Star a card to look at later."),
            ("Bury (-)", "Skip it until tomorrow."),
            ("Suspend (@)", "Stop showing it until you unsuspend it in Browse."),
            ("Info (I)", "The card's history: when you saw it and how it went."),
            ("Delete (⌘⌫)", "Delete the note and its cards. You'll be asked first."),
        ]),
    HelpTopic(
        id: "add", title: "Adding cards", symbol: "plus.rectangle.on.rectangle",
        intro: "Open Add Cards from Home or press ⌘N.",
        points: [
            ("Front and back", "Type the question on the front and the answer on the back, then press ⌘Return to add it."),
            ("Choose a deck", "Pick which deck the card goes into at the top."),
            ("Pictures and maths", "Paste or drag in pictures. Write maths between \\( and \\) and it's drawn as a formula."),
            ("Image occlusion", "Hide parts of a diagram and test yourself on each label."),
            ("Slides & Notes", "Open your lecture slides beside the editor while you make cards from them."),
        ]),
    HelpTopic(
        id: "browse", title: "Finding cards", symbol: "magnifyingglass",
        intro: "Type in the search box at the top of the window, from any page, to search every card.",
        points: [
            ("Browse", "Lists your cards. Select some to edit, move, flag, tag, suspend or delete them."),
            ("More tools", "Right-click selected cards to set a due date, reset them to new, or find and replace text."),
            ("Undo", "Edit › Undo (⌘Z) takes back most changes, like a delete or a suspend."),
        ]),
    HelpTopic(
        id: "decks", title: "Decks and options", symbol: "slider.horizontal.3",
        intro: "Right-click a deck to rename, export or delete it, or to change its options.",
        points: [
            ("New cards a day", "How many new cards you meet each day. Start small: 10 to 20 is plenty."),
            ("Reviews a day", "A daily limit on reviews. Anything over waits until tomorrow."),
            ("Fit to my memory", "Once you've done a few hundred reviews, Optimise tunes the schedule to how you remember."),
            ("When the day starts", "Settings › Studying sets the hour your new study day begins, 4am by default."),
        ]),
    HelpTopic(
        id: "sync", title: "Syncing", symbol: "arrow.triangle.2.circlepath",
        intro: "Sign in with a free AnkiWeb account to keep this Mac, Anki on other computers and AnkiMobile or AnkiDroid on your phone in step.",
        points: [
            ("Sync now", "Click the sync button in the toolbar or on Home."),
            ("Pictures and sounds", "These sync after your cards. A bar at the bottom shows how far along it is."),
            ("If it goes wrong", "Animus tries again by itself after a brief hiccup and explains any problem in plain English. Your cards on this Mac stay as they are."),
        ]),
    HelpTopic(
        id: "home", title: "Home, timers and stats", symbol: "house",
        intro: "Make Home your own.",
        points: [
            ("Arrange Home", "Click Arrange Home at the bottom, then drag sections by their ☰ handle, or hide ones you don't use."),
            ("Exam countdown", "Add your exam dates to see how many days are left."),
            ("Timers", "The timer button in the toolbar starts a Pomodoro or a simple timer."),
            ("Stats", "See how many cards you've studied. Click a day on the heatmap to list that day's cards."),
            ("Backgrounds", "Settings › General › Background puts a painting or a colour wash behind Home and studying."),
        ]),
    HelpTopic(
        id: "profiles", title: "Profiles and backups", symbol: "person.2",
        intro: "Each profile has its own cards, settings and AnkiWeb account.",
        points: [
            ("Switch profile", "Click your name at the top right of Home."),
            ("Delete a profile", "Use the bin button beside it. Its files go to the Bin, so they can be recovered until you empty it."),
            ("Backups", "Animus keeps automatic backups. Settings › Backups lets you restore one."),
        ]),
    HelpTopic(
        id: "keys", title: "Keyboard shortcuts", symbol: "keyboard",
        intro: "Everywhere in Animus:",
        points: [
            ("⌘N", "Add Cards"),
            ("⌘I", "Import a deck file"),
            ("⌘[ and ⌘]", "Back and forward"),
            ("⌘Z and ⇧⌘Z", "Undo and redo"),
            ("⌘,", "Settings"),
            ("⌘?", "This guide"),
            ("Space or Return", "Show the answer, then answer Good"),
            ("1 2 3 4", "Again, Hard, Good, Easy"),
            ("Esc", "Stop studying"),
        ]),
]

struct HelpGuideView: View {
    @State private var selection: HelpTopic? = topics.first

    var body: some View {
        NavigationSplitView {
            List(topics, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            if let topic = selection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(topic.title, systemImage: topic.symbol)
                            .font(.largeTitle.weight(.semibold))
                        Text(topic.intro)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(topic.points, id: \.0) { point in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(point.0).font(.headline)
                                    Text(point.1)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
                    }
                    .padding(28)
                    .frame(maxWidth: 680, alignment: .leading)
                }
                .id(topic.id)
            }
        }
    }
}

/// The same guide for iPhone and iPad: tap and swipe instead of keys and clicks.
private let phoneTopics: [HelpTopic] = [
    HelpTopic(
        id: "start", title: "Getting started", symbol: "sparkles",
        intro: "Animus shows you each card just before you'd forget it. A few minutes every day beats a long session once a week.",
        points: [
            ("Home", "Shows what's waiting today, your decks and your study days. Tap Continue to carry on where you left off."),
            ("Decks", "Swipe sideways through your decks on Home. Tap one to see its sections, study it, browse its cards or change its options."),
            ("New, Learning, Review", "Blue cards are new, orange ones you're still learning, green ones are coming back for review."),
            ("Getting cards", "Make your own with Add Cards, tap Import to open a deck file (.apkg), open one from Files, Mail or AirDrop, or sign in to AnkiWeb to bring over your Anki cards."),
        ]),
    HelpTopic(
        id: "study", title: "Studying", symbol: "graduationcap",
        intro: "Look at the question, try to remember the answer, then show it and say how it went.",
        points: [
            ("Show the answer", "Tap the card or Show Answer."),
            ("Again, Hard, Good, Easy", "Tap how well you remembered. Each button shows when you'll see the card next."),
            ("Changed your mind?", "The arrow at the top right undoes your last answer."),
            ("Under the card", "Edit fixes a typo, Mark stars a card, Flag colour-codes it, Bury hides it until tomorrow and Suspend puts it away until you bring it back in Browse."),
            ("Finish", "Tap Done at any time. Your progress is saved as you go."),
        ]),
    HelpTopic(
        id: "browse", title: "Finding cards", symbol: "magnifyingglass",
        intro: "Browse finds any card in your collection.",
        points: [
            ("Search", "Type words from the card. The buttons under the search box show just new, due, suspended or flagged cards."),
            ("Edit", "Tap a card to change its text or tags."),
            ("Swipe", "Swipe left to suspend or delete a card, right to flag it."),
            ("Filtered decks", "Tap Filtered Deck on Home to study just some cards, like the ones you keep forgetting, before an exam. They go back to their own decks afterwards."),
        ]),
    HelpTopic(
        id: "decks", title: "Deck options", symbol: "slider.horizontal.3",
        intro: "Open a deck and tap Options.",
        points: [
            ("New cards a day", "How many new cards you meet each day. Start small: 10 to 20 is plenty."),
            ("Reviews a day", "A daily limit on reviews. Anything over waits until tomorrow."),
            ("Fit to my memory", "Once you've done a few hundred reviews, Optimise tunes the schedule to how you remember."),
        ]),
    HelpTopic(
        id: "sync", title: "Syncing", symbol: "arrow.triangle.2.circlepath",
        intro: "Sign in with a free AnkiWeb account to keep this device, Animus on your Mac and Anki everywhere else in step.",
        points: [
            ("Sync now", "Tap Sync on Home, or pull Home down."),
            ("Automatically", "Animus syncs when you open it and after you finish studying."),
            ("If it goes wrong", "Animus explains any problem in plain English. Your cards on this device stay as they are."),
        ]),
    HelpTopic(
        id: "home", title: "Timers and settings", symbol: "timer",
        intro: "Make Animus your own.",
        points: [
            ("Timers", "Tap Timers at the top of Home or while studying for a Pomodoro or a study timer. Animus can alert you when a break starts or ends, even when it's closed."),
            ("Stats", "Tap Stats or See all stats. Tap a day on the heatmap to see its numbers."),
            ("Settings", "The gear at the top of Home: your name, theme, accent colour, background picture, card text size and sync."),
        ]),
]

/// Help › Animus Help (⌘?).
struct HelpGuideCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Animus Help") { openWindow(id: HelpWindow.id) }
            .keyboardShortcut("?", modifiers: .command)
    }
}
