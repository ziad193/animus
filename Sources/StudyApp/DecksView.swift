import AppKit
import SwiftUI
import StudyCore

/// Main window. Browser-style tabs along the top (Home, Add Cards, Browse,
/// Stats, plus one for an open deck), back / forward buttons, and a deck list
/// down the side only while you're in a deck.
struct DecksView: View {
    @Environment(Library.self) private var library
    let decks: [Deck]

    @State private var sidebar: SidebarItem? = .home
    @State private var path: [Route] = []
    @State private var browse = BrowseModel()
    @State private var deckActions = DeckActions()
    @State private var width: CGFloat = 1200

    /// In a narrow window the deck list steps aside so the page itself has room.
    private var roomForSidebar: Bool { width >= 1000 }
    @Environment(SyncManager.self) private var sync

    enum SidebarItem: Hashable {
        case home
        case addCards
        case browse
        case stats
        case deck(Int64)
    }

    /// Where you are: the tab plus any pages opened inside it.
    struct Place: Hashable {
        var tab: SidebarItem?
        var path: [Route]
    }

    @State private var backStack: [Place] = []
    @State private var forwardStack: [Place] = []
    /// Set while going back or forward, so that move isn't recorded as a new step.
    @State private var replaying = false
    /// The deck Add Cards should start on (the one you were looking at).
    @State private var addCardsDeck: Int64?

    private var place: Place { Place(tab: sidebar, path: path) }
    private var isHome: Bool { sidebar == .home && path.isEmpty }
    /// Hidden at launch (you start on Home); shown once you leave Home, and
    /// kept for 10 seconds after you come back.
    @State private var showTabs = false
    @State private var lingerTask: Task<Void, Never>?

    enum Route: Hashable {
        case deck(Int64)
        case study(Int64)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Home has its own big buttons, so the tabs only show once you've left it.
            // Coming back Home, they stay for a few seconds, then slide away.
            if showTabs && !(studying && !studyShowTabs) {
                VStack(spacing: 0) {
                    TabStrip(selection: sidebar, decks: decks, select: select)
                    Divider()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            pages
        }
        .animation(.easeInOut(duration: 0.25), value: studyShowTabs)
        .onChange(of: isHome) { _, home in
            lingerTask?.cancel()
            guard home else {
                withAnimation(.easeInOut(duration: 0.25)) { showTabs = true }
                return
            }
            // Still showing; hide after 10 seconds unless you leave Home again.
            lingerTask = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.6)) { showTabs = false }
            }
        }
        .onChange(of: place) { old, _ in
            // Every move is a step you can go back to, like a web browser.
            if replaying {
                replaying = false
            } else {
                backStack.append(old)
                if backStack.count > 50 { backStack.removeFirst() }
                forwardStack.removeAll()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .iterumShowAddCards)) { _ in openAddCards() }
        // A filtered deck you just made opens straight into studying.
        // Test collections only: open a deck's Options straight away, for on-screen checks.
        .task(id: decks.first?.id) {
            if Library.isTestCollection, ProcessInfo.processInfo.environment["ITERUM_TEST_OPTIONS"] != nil,
               deckActions.options == nil, let first = decks.first {
                deckActions.options = first
            }
        }
        .onChange(of: deckActions.openDeck) { _, id in
            if let id { select(.deck(id)); deckActions.openDeck = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .iterumGoBack)) { _ in goBack() }
        .onReceive(NotificationCenter.default.publisher(for: .iterumGoForward)) { _ in goForward() }
    }

    /// The deck list only shows inside a deck (its page, or studying);
    /// everywhere else the page is full width.
    /// (Drawn by hand rather than with a split view, which forgot its width when hidden.)
    private var pages: some View {
        HStack(spacing: 0) {
            if wantsSidebar && roomForSidebar {
                sidebarList
                    .frame(width: 260)
                    .background(SidebarMaterial())
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            NavigationStack(path: $path) {
                root
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .deck(let id):
                            if let deck = Deck.find(id, in: decks) {
                                // Its own solid background: the page it opened from stays
                                // underneath, and would show through a see-through one.
                                DeckPage(deck: deck, open: open, study: study, browse: browseDeck)
                                    .screenBackground(plain: Color(nsColor: .windowBackgroundColor))
                            }
                        case .study(let id):
                            if let deck = Deck.find(id, in: decks) {
                                StudyView(deck: deck) { path.removeLast() }
                                    .navigationBarBackButtonHidden()
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.22), value: wantsSidebar && roomForSidebar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .environment(deckActions)
        .deckActions(deckActions, decks: decks)
        // Counts change when the study day rolls over (e.g. 4am); refresh whenever you come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await library.refresh() }
        }

        .syncSheets(sync)
        // If the open deck was deleted, go back Home.
        .onChange(of: decks.map(\.id)) {
            if case .deck(let id) = sidebar, Deck.find(id, in: decks) == nil { select(.home) }
            path.removeAll { route in
                switch route {
                case .deck(let id), .study(let id): Deck.find(id, in: decks) == nil
                }
            }
        }

        // Always in the toolbar: typing here searches every card from any page.

        .onChange(of: browse.query) {
            if !browse.query.isEmpty, sidebar != .browse { select(.browse) }
        }
        .environment(browse)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: goBack) { Label("Back", systemImage: "chevron.left") }
                    .tip("Back (⌘[)")
                    .disabled(backStack.isEmpty)
                    .buttonStyle(.automatic)
                Button(action: goForward) { Label("Forward", systemImage: "chevron.right") }
                    .tip("Forward (⌘])")
                    .disabled(forwardStack.isEmpty)
                    .buttonStyle(.automatic)
            }
            ToolbarItem(placement: .primaryAction) {
                SyncButton()
            }
            ToolbarItem(placement: .primaryAction) {
                TimersButton()
            }
            // Always in the toolbar: typing here searches every card from any page.
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $browse.query)
            }
        }
    }

    @ViewBuilder private var root: some View {
        switch sidebar {
        case .stats:
            StatsPage()
        case .browse:
            BrowsePage(decks: decks)
        case .addCards:
            AddCardsView(initialDeckID: addCardsDeck)
        case .deck(let id):
            if let deck = Deck.find(id, in: decks) {
                if deck.children.isEmpty {
                    // No sections to choose from, so go straight to the cards.
                    StudyView(deck: deck) { select(.home) }
                        .id(deck.id)
                } else {
                    DeckPage(deck: deck, open: open, study: study, browse: browseDeck)
                }
            }
        default:
            TodayPage(decks: decks,
                      open: { deck in select(.deck(deck.id)) },  // a deck without sections opens straight into studying
                      study: { deck in
                          if deck.children.isEmpty {
                              select(.deck(deck.id))
                          } else {
                              sidebar = .deck(deck.id)
                              path = [.study(deck.id)]
                          }
                      },
                      openStats: { select(.stats) },
                      openBrowse: { select(.browse) },
                      openAddCards: { openAddCards() })
        }
    }

    private var sidebarList: some View {
        List(selection: Binding(get: { sidebar }, set: { if let new = $0 { select(new) } })) {
            Section("Decks") {
                ForEach(decks) { deck in
                    HStack(spacing: 8) {
                        DeckIcon(deck: deck, size: 22)
                        Text(deck.shortName).lineLimit(1)
                        Spacer(minLength: 4)
                        CountPills(deck: deck, compact: true)
                    }
                    .tag(SidebarItem.deck(deck.id))
                    .contextMenu {
                        Button("Rename…") { deckActions.renaming = deck }
                        Button("Options…") { deckActions.options = deck }
                        Button("Export…") { deckActions.exporting = deck }
                        Divider()
                        Button("Delete…", role: .destructive) { deckActions.deleting = deck }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var wantsSidebar: Bool {
        // Studying: tucked away unless you ask for it, so the card has the room.
        if studying { return studyShowDecks }
        if case .deck = sidebar { return true }
        return !path.isEmpty
    }

    @AppStorage(Pref.studyShowDecks) private var studyShowDecks = false
    @AppStorage(Pref.studyShowTabs) private var studyShowTabs = true

    /// True while a card is being studied (either way of getting there).
    private var studying: Bool {
        if case .study = path.last { return true }
        if path.isEmpty, case .deck(let id) = sidebar, let deck = Deck.find(id, in: decks) {
            return deck.children.isEmpty
        }
        return false
    }

    /// Switches tab (always back to that tab's first page).
    private func select(_ tab: SidebarItem) {
        sidebar = tab
        path = []
    }

    private func openAddCards() {
        // Start on the deck you were looking at, if any.
        if case .deck(let id) = sidebar {
            addCardsDeck = path.last.map { route -> Int64 in
                switch route { case .deck(let d), .study(let d): d }
            } ?? id
        }
        select(.addCards)
    }

    private func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(place)
        replaying = true
        sidebar = target.tab
        path = target.path
    }

    private func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(place)
        replaying = true
        sidebar = target.tab
        path = target.path
    }

    /// Opens a deck's page, or goes straight to studying when it has no sections.
    private func open(_ deck: Deck) {
        path.append(deck.children.isEmpty ? .study(deck.id) : .deck(deck.id))
    }
    private func browseDeck(_ deck: Deck) {
        browse.deckID = deck.id
        browse.filter = .all
        select(.browse)
    }
    private func study(_ deck: Deck) { path.append(.study(deck.id)) }
}

// MARK: - Today

private struct TodayPage: View {
    @Environment(Library.self) private var library
    @Environment(DeckActions.self) private var deckActions
    let decks: [Deck]
    let open: (Deck) -> Void
    let study: (Deck) -> Void
    let openStats: () -> Void
    let openBrowse: () -> Void
    let openAddCards: () -> Void

    @State private var stats: Stats?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(SyncManager.self) private var sync
    @Environment(ProfileStore.self) private var profiles

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var totals: (new: UInt32, learn: UInt32, review: UInt32) {
        decks.reduce((0, 0, 0)) { ($0.0 + $1.newCount, $0.1 + $1.learnCount, $0.2 + $1.reviewCount) }
    }

    @AppStorage(Pref.lastStudiedDeck) private var lastStudiedDeck = 0

    /// The deck you studied last, for "Continue" — only while it still has cards waiting.
    private var continueDeck: Deck? {
        guard let deck = Deck.find(Int64(lastStudiedDeck), in: decks), deck.dueToday > 0 else { return nil }
        return deck
    }

    @AppStorage(AppBackground.key) private var background = AppBackground.none
    @AppStorage(BackgroundStyle.key) private var backgroundStyle = BackgroundStyle.banner
    @State private var backgroundStore = BackgroundStore.shared
    @Environment(\.colorScheme) private var colorScheme

    /// The picture sits behind the greeting and today's ring, as a banner.
    private var showsBanner: Bool {
        let _ = backgroundStore.generation
        return backgroundStyle == .banner && background.isShowing
    }

    /// The greeting and today's ring: on the banner, or at the top of the page.
    private var header: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(greeting), \(profiles.active.name)")
                        .font(.largeTitle.weight(.semibold))
                }
                .frostedOnPicture(cornerRadius: 14, padding: 10)
                .bannerShadow()
                Spacer()
                ProfileButton()
                    .frostedOnPicture(cornerRadius: 22, padding: 2, alsoOnBanner: true)
            }

            TodayProgress(left: Int(totals.learn + totals.review), newCards: Int(totals.new),
                          done: stats?.todayReviews ?? 0)
                .bannerShadow()
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            // The greeting, today's ring and the buttons: the same layout with or
            // without a background; on a picture the text turns white.
                VStack(alignment: .leading, spacing: 26) {
                    header
                    quickActions
                }
                    .padding(.horizontal, 36)
                    .padding(.top, 36)
                    .padding(.bottom, 30)
                    .frame(maxWidth: 1280, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    // White text and a light ring straight on the picture, in light or dark mode.
                    // (Either style: the banner, or the picture behind the whole window.)
                    .environment(\.colorScheme, background.isShowing ? .dark : colorScheme)
                    .environment(\.onBanner, background.isShowing)
            VStack(alignment: .leading, spacing: 26) {

                ForEach(layout.order, id: \.self) { section in
                    if arranging {
                        ArrangeFrame(section: section, layout: layout,
                                     moveUp: { move(section, by: -1) }, moveDown: { move(section, by: 1) },
                                     toggle: { toggleHidden(section) }) { EmptyView() }
                            .homeDragging(section, onDrop: drop)
                    } else if !layout.hidden.contains(section) {
                        content(for: section)
                    }
                }

                // Page controls, at the bottom so they don't crowd the top.
                HStack(spacing: 10) {
                    Spacer()
                    HStack(spacing: 10) {
                    Button {
                        arranging.toggle()
                    } label: {
                        Label(arranging ? "Done Arranging" : "Arrange Home", systemImage: arranging ? "checkmark" : "rectangle.3.group")
                    }
                    .tip("Change the order of the sections above, or hide ones you don't use")
                    .frostedOnPicture(cornerRadius: 7)
                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tip("Appearance, when your study day starts, the timer and more (⌘,)")
                    .frostedOnPicture(cornerRadius: 7)
                    Button {
                        openWindow(id: HelpWindow.id)
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    .tip("A short guide to studying, adding cards, syncing and shortcuts (⌘?)")
                    .frostedOnPicture(cornerRadius: 7)
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        Label(sync.isSignedIn ? sync.summary : "Sync with AnkiWeb", systemImage: "arrow.triangle.2.circlepath")
                            .lineLimit(1)
                    }
                    .tip(sync.isSignedIn ? "Sync now" : "Sign in to keep this Mac, Anki and your phone in step")
                    .frostedOnPicture(cornerRadius: 7)
                    }
                    Spacer()
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
            .padding(36)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
            // Below the greeting, each block keeps frosted glass over the picture
            // (in either style: as a banner on Home, or behind the whole window).
            .environment(\.onPicture, background.isShowing)
            }
        }
        // The picture fills the whole of Home, behind everything.
        .background {
            if showsBanner {
                BannerBackdrop(background: background).ignoresSafeArea()
            }
        }
        .screenBackground()
        .task(id: decks.map(\.dueToday)) {
            stats = try? await library.engine?.stats(days: Heatmap.historyDays)
        }
    }

    // MARK: Arranging Home

    @AppStorage(HomeLayout.key) private var layoutText = HomeLayout.standard.text
    @State private var arranging = false

    private var layout: HomeLayout { HomeLayout(text: layoutText) }

    private func move(_ section: HomeSection, by step: Int) {
        var l = layout
        guard let i = l.order.firstIndex(of: section) else { return }
        let j = i + step
        guard l.order.indices.contains(j) else { return }
        withAnimation(.snappy) {
            l.order.swapAt(i, j)
            layoutText = l.text
        }
    }

    /// A section dragged onto another takes its place (the rest shift along).
    private func drop(_ dragged: HomeSection, onto target: HomeSection) {
        var l = layout
        guard dragged != target, let from = l.order.firstIndex(of: dragged),
              let to = l.order.firstIndex(of: target) else { return }
        withAnimation(.snappy) {
            l.order.remove(at: from)
            l.order.insert(dragged, at: to)
            layoutText = l.text
        }
    }

    private func toggleHidden(_ section: HomeSection) {
        var l = layout
        if l.hidden.contains(section) { l.hidden.remove(section) } else { l.hidden.insert(section) }
        withAnimation(.snappy) { layoutText = l.text }
    }

    @ViewBuilder
    private func content(for section: HomeSection) -> some View {
        switch section {
        case .exams:
            ExamCountdowns(decks: decks, study: study)
        case .studyDays:
            HomePanel(title: "Your study days", action: ("See all stats", openStats)) {
                if let stats {
                    Heatmap(stats: stats)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        case .decks:
            if decks.isEmpty {
                ContentUnavailableView {
                    Label("No decks yet", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Make a deck, add cards, or import a deck file to get started.")
                } actions: {
                    Button("New Deck…") { deckActions.creatingDeck = true }
                }
            } else {
                TileGrid(title: "Your decks", decks: decks, open: open) {
                    deckActions.creatingDeck = true
                }
                .frostedOnPicture(cornerRadius: 18, padding: 16)
            }
        }
    }

    /// Everything important, one click away.
    private var quickActions: some View {
        FlowRow(spacing: 10) {
            if let continueDeck {
                ActionButton(title: "Continue", symbol: "play.fill", prominent: true,
                             help: "Carry on studying \(continueDeck.displayPath)") {
                    study(continueDeck)
                }
            }
            ActionButton(title: "Add Cards", symbol: "plus.rectangle.on.rectangle", help: "Make new cards (⌘N)") {
                openAddCards()
            }
            ActionButton(title: "Import", symbol: "square.and.arrow.down", help: "Add a shared deck (.apkg) or a spreadsheet of cards (.csv, .txt) (⌘I)") {
                Task {
                    if let message = await library.chooseAndImport() { library.notice = message }
                }
            }
            ActionButton(title: "Filtered Deck", symbol: "line.3.horizontal.decrease.circle",
                         help: "Study just some cards (e.g. ones you forgot, or before an exam); they go back afterwards") {
                deckActions.filtering = .init(deck: nil)
            }
            ActionButton(title: "Browse", symbol: "magnifyingglass", help: "Find, edit and organise your cards", action: openBrowse)
            ActionButton(title: "Stats", symbol: "chart.bar.xaxis", help: "Your heatmap, streaks and progress", action: openStats)
        }
    }
}

/// A large, labelled button for the home screen's quick actions. All the
/// same size; what each does shows in a note when you hover over it.
private struct ActionButton: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    let title: String
    let symbol: String
    var prominent = false
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.onPicture) private var onPicture
    @Environment(\.onBanner) private var onBanner

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(prominent ? Color.white : accent.color)
                    .frame(width: 24)
                Text(title).font(.headline)
                    .foregroundStyle(prominent ? Color.white : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: FlowRow<EmptyView>.itemWidth, maxWidth: .infinity, minHeight: 46, maxHeight: 46)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(prominent ? AnyShapeStyle(accent.color.gradient)
                      : (onPicture || onBanner) ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.primary.opacity(0.05))))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(hovering && !prominent ? 0.05 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(prominent ? Color.white.opacity(hovering ? 0.35 : 0) : Color.secondary.opacity(hovering ? 0.4 : 0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        // Continue (the blue one) brightens; the rest get a soft fill. All lift a little.
        .hoverLift(scale: 1.02)
        .onHover { hovering = $0 }
        .tip(help)
    }
}

/// A white panel with a title and an optional link on the right.
private struct HomePanel<Content: View>: View {
    let title: String
    var action: (String, () -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                if let action {
                    Button(action: action.1) {
                        Label(action.0, systemImage: "chevron.right")
                            .labelStyle(TrailingIconLabel())
                    }
                    .buttonStyle(.hoverable)
                }
            }
            content
        }
        .padding(20)
        .background(BlockFill(cornerRadius: 16, plain: AnyShapeStyle(.background)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5)))
    }
}

private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

/// Today at a glance: a ring that fills as you work through what's due,
/// with the number left in the middle and what you've done beside it.
private struct TodayProgress: View {
    @Environment(StudyClock.self) private var clock
    @Environment(\.onBanner) private var onBanner
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    /// Reviews (and cards you're learning) still waiting today, across all decks.
    let left: Int
    /// New cards on offer today; optional, so they don't count towards the ring.
    let newCards: Int
    /// Cards studied today.
    let done: Int

    private var progress: Double {
        let total = left + done
        return total == 0 ? 1 : Double(done) / Double(total)
    }

    var body: some View {
        let _ = clock.revision
        // The ring in the middle, the words under it, no box.
        VStack(spacing: 14) {
            ring
            VStack(spacing: 6) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                details
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(onBanner ? Color.white.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(left == 0 ? Color.green.gradient : accent.color.gradient,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.8), value: progress)
            VStack(spacing: 0) {
                if left == 0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text("\(left)")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6)
                    Text("to go").font(.caption.weight(.medium))
                        .foregroundStyle(onBanner ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                }
            }
            .padding(18)
        }
        .frame(width: 118, height: 118)
    }

    private var details: some View {
        HStack(spacing: 16) {
            Label(done == 1 ? "1 card studied" : "\(done) cards studied", systemImage: "checkmark.circle")
            Label("\(StudyClock.format(clock.todaySeconds)) today", systemImage: "stopwatch")
                .tip("This week: \(StudyClock.format(clock.weekSeconds)). The timer pauses on breaks, when you switch apps, or after 3 idle minutes.")
        }
        .font(.callout)
        .foregroundStyle(onBanner ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.secondary))
    }

    private var headline: String {
        if left == 0 { return done == 0 ? "Nothing due today" : "All reviews done" }
        return left == 1 ? "1 card due today" : "\(left.formatted()) cards due today"
    }

}

/// One number with a label under it, on a soft coloured tile.
struct StatTile: View {
    let value: String
    let title: String
    let color: Color
    var dim = false
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(dim ? Color.secondary : color)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: FlowRow<EmptyView>.itemWidth)
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(dim ? 0.04 : 0.1)))
        .tip(help)
    }
}

// MARK: - A deck

private struct DeckPage: View {
    let deck: Deck
    let open: (Deck) -> Void
    let study: (Deck) -> Void
    let browse: (Deck) -> Void
    @Environment(Library.self) private var library
    @State private var plusStore = PlusStore.shared
    @State private var practising = false
    @State private var description = ""
    @State private var showWholeDescription = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !description.isEmpty { descriptionBox }
                DueSummary(new: deck.newCount, learn: deck.learnCount, review: deck.reviewCount)
                if !deck.children.isEmpty {
                    TileGrid(title: "Sections", decks: deck.children, open: open)
                }
            }
            .padding(36)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(deck.shortName)
        .task(id: deck.id) {
            showWholeDescription = false
            let html = (try? await library.engine?.deckDescription(deck.id)) ?? ""
            description = HTMLText.plain(html).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The deck's description, as written by whoever made it (shared decks
    /// often explain their tags and sources here).
    private var descriptionBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About this deck").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(description)
                .textSelection(.enabled)
                .lineLimit(showWholeDescription ? nil : 4)
                .frame(maxWidth: 820, alignment: .leading)
            if description.count > 280 || description.filter({ $0 == "\n" }).count > 3 {
                Button(showWholeDescription ? "Show less" : "Show more") {
                    withAnimation(.easeOut(duration: 0.2)) { showWholeDescription.toggle() }
                }
                .buttonStyle(.link)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            DeckIcon(deck: deck, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                if deck.path.count > 1 {
                    Text(deck.path.dropLast().joined(separator: " › "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(deck.shortName)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)
                Text(deck.summary)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            Button {
                browse(deck)
            } label: {
                Label("Browse Cards", systemImage: "magnifyingglass")
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .tip("See, search and edit every card in this deck")
            // Animus+ (Animus Dev only until it's ready): exam-style questions.
            if plusStore.showsPreviews && plusStore.showsPrompts {
                PlusFeatureButton(feature: .practiceQuestions) { practising = true } label: {
                    Label("Practice", systemImage: PlusFeature.practiceQuestions.symbol)
                        .padding(.vertical, 4)
                }
                .controlSize(.large)
                .sheet(isPresented: $practising) { PracticeSheet(deck: deck) }
            }
            DeckMenu(deck: deck, size: 17)
            if deck.dueToday > 0 {
                Button {
                    study(deck)
                } label: {
                    Label("Study Now", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .hoverGlow()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .tip(deck.children.isEmpty ? "Study this deck (Return)" : "Study this deck and all its sections (Return)")
            } else {
                Label("All caught up", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            }
        }
    }
}

// MARK: - Tiles

private struct TileGrid: View {
    let title: String
    let decks: [Deck]
    let open: (Deck) -> Void
    var newDeck: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                if let newDeck {
                    Button(action: newDeck) {
                        Label("New Deck", systemImage: "plus")
                    }
                    .buttonStyle(.hoverable)
                    .tip("Make a new, empty deck (or a section inside another deck)")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 14)], spacing: 14) {
                ForEach(decks) { deck in
                    DeckTile(deck: deck) { open(deck) }
                        .overlay(alignment: .bottomTrailing) {
                            DeckMenu(deck: deck)
                                .padding(.trailing, 8)
                                .padding(.bottom, 24)
                        }
                }
            }
        }
    }
}

private struct DeckTile: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    let deck: Deck
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    DeckIcon(deck: deck, size: 36)
                    if deck.filtered {
                        Label("Filtered", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .tip("A filtered deck: it borrows cards, which go back when you finish it")
                    }
                    Spacer()
                    if deck.dueToday > 0 {
                        CountPills(deck: deck, compact: false)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(deck.shortName)
                        .font(.headline)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Text(deck.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DueBar(deck: deck)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.background)
                    .shadow(color: .black.opacity(hovering ? 0.14 : 0.06), radius: hovering ? 10 : 4, y: hovering ? 4 : 2)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5)))
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { over in
            withAnimation(.easeOut(duration: 0.15)) { hovering = over }
        }
        .tip(deck.name.replacingOccurrences(of: "::", with: " › "))
    }
}

/// New / Learning / Review counts as three soft tiles.
private struct DueSummary: View {
    let new: UInt32
    let learn: UInt32
    let review: UInt32

    var body: some View {
        HStack(spacing: 12) {
            StatTile(value: "\(new)", title: "New", color: Palette.new, dim: new == 0, help: "Cards you haven't seen yet")
            StatTile(value: "\(learn)", title: "Learning", color: Palette.learning, dim: learn == 0, help: "Seen recently, still sticking")
            StatTile(value: "\(review)", title: "Due", color: Palette.review, dim: review == 0, help: "Cards due for a check-up today")
        }
        .frame(maxWidth: 600, alignment: .leading)
    }
}

// MARK: - Helpers

/// The frosted background macOS uses behind sidebars.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = ToolbarBackdrop.PassThroughEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The search box in the toolbar, on every page.
private struct ToolbarSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your cards", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .tip("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(focused ? 0.1 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear))
    }
}

// MARK: - Home layout

/// The movable sections of Home.
enum HomeSection: String, CaseIterable {
    case exams, studyDays, decks

    var title: String {
        switch self {
        case .exams: "Exam countdown"
        case .studyDays: "Your study days"
        case .decks: "Your decks"
        }
    }
}

/// The order of Home's sections and which are hidden, saved as text like
/// "decks,exams,studyDays|exams" (order, then hidden ones).
struct HomeLayout {
    static let key = "homeLayout"
    static let standard = HomeLayout(order: HomeSection.allCases, hidden: [])

    var order: [HomeSection]
    var hidden: Set<HomeSection>

    init(order: [HomeSection], hidden: Set<HomeSection>) {
        self.order = order
        self.hidden = hidden
    }

    init(text: String) {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        var order = (parts.first ?? "").split(separator: ",").compactMap { HomeSection(rawValue: String($0)) }
        // Keep any section missing from an older saved order.
        order += HomeSection.allCases.filter { !order.contains($0) }
        self.order = order
        hidden = Set((parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { HomeSection(rawValue: String($0)) })
    }

    var text: String {
        order.map(\.rawValue).joined(separator: ",") + "|" + hidden.map(\.rawValue).sorted().joined(separator: ",")
    }
}

/// While arranging Home, a section can be picked up (by its handle or anywhere
/// on it) and dropped on another section to take its place.
private struct HomeDragging: ViewModifier {
    let section: HomeSection
    let onDrop: (HomeSection, HomeSection) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .draggable(section.rawValue) {
                Label(section.title, systemImage: "line.3.horizontal")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let dragged = HomeSection(rawValue: raw) else { return false }
                onDrop(dragged, section)
                return true
            } isTargeted: { targeted = $0 }
            // Where it will land.
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .opacity(targeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

private extension View {
    func homeDragging(_ section: HomeSection, onDrop: @escaping (HomeSection, HomeSection) -> Void) -> some View {
        modifier(HomeDragging(section: section, onDrop: onDrop))
    }
}

/// Wraps a Home section while arranging: a bar with up / down and show / hide.
private struct ArrangeFrame<Content: View>: View {
    let section: HomeSection
    let layout: HomeLayout
    let moveUp: () -> Void
    let moveDown: () -> Void
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        let isHidden = layout.hidden.contains(section)
        let index = layout.order.firstIndex(of: section) ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Drag handle: pick the section up here (or anywhere on it) and drop it on another.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    .tip("Drag to move “\(section.title)”")
                Text(section.title).font(.headline)
                if isHidden {
                    Text("Hidden").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: moveUp) { Label("Move up", systemImage: "arrow.up") }
                    .disabled(index == 0)
                Button(action: moveDown) { Label("Move down", systemImage: "arrow.down") }
                    .disabled(index == layout.order.count - 1)
                Button(action: toggle) {
                    Label(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.hoverable)
            content
        }
        .padding(14)
        .opacity(isHidden ? 0.55 : 1)
        .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        .transition(.opacity)
    }
}


/// Equal-width items on one line when they fit, otherwise wrapped evenly
/// onto more rows, so a row never ends with an empty gap.
struct FlowRow<Content: View>: View {
    static var itemWidth: CGFloat { 140 }
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.itemWidth), spacing: spacing)], spacing: spacing) { content }
        }
    }
}


// MARK: - Tabs

extension Notification.Name {
    static let iterumShowAddCards = Notification.Name("iterum.showAddCards")
    static let iterumGoBack = Notification.Name("iterum.goBack")
    static let iterumGoForward = Notification.Name("iterum.goForward")
}

/// Browser-style tabs along the top of the window.
private struct TabStrip: View {
    let selection: DecksView.SidebarItem?
    let decks: [Deck]
    let select: (DecksView.SidebarItem) -> Void

    var body: some View {
        // Tabs share the full width equally and shrink with the window, like a browser.
        HStack(spacing: 4) {
            tab(.home, "Home", "house")
            tab(.addCards, "Add Cards", "plus.rectangle.on.rectangle")
            tab(.browse, "Browse", "magnifyingglass")
            tab(.stats, "Stats", "chart.bar.xaxis")
            // An open deck gets its own tab, which you can close.
            if case .deck(let id) = selection, let deck = Deck.find(id, in: decks) {
                TabButton(title: deck.shortName, symbol: nil, deck: deck, selected: true,
                          close: { select(.home) }) { select(.deck(id)) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func tab(_ item: DecksView.SidebarItem, _ title: String, _ symbol: String) -> some View {
        TabButton(title: title, symbol: symbol, deck: nil, selected: selection == item, close: nil) {
            select(item)
        }
    }
}

private struct TabButton: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    let title: String
    let symbol: String?
    let deck: Deck?
    let selected: Bool
    let close: (() -> Void)?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let deck {
                DeckIcon(deck: deck, size: 16)
            } else if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? accent.color : .secondary)
            }
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip("Close this deck")
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 60, maxWidth: .infinity, minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Color.primary.opacity(0.08) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
        .tip(title)
    }
}
