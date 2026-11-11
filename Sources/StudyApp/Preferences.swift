import StudyCore
import AppKit
import SwiftUI

/// The appearance controls, shared by Setup and the Settings window.
struct AppearancePicker: View {
    @AppStorage(Pref.appearance) private var appearance = AppearanceChoice.system
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    @AppStorage(Pref.cardTextSize) private var textSize = CardTextSize.normal
    @AppStorage(Pref.cardStyle) private var cardStyle = CardStyle.app
    @AppStorage(Pref.studyPane) private var paneStyle = CardPaneStyle.frosted

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Theme") {
                HStack(spacing: 12) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        ThemeTile(choice: choice, selected: appearance == choice) {
                            appearance = choice
                        }
                    }
                }
            }
            section("Accent colour") {
                HStack(spacing: 12) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button {
                            accent = choice
                        } label: {
                            Circle()
                                .fill(choice.color)
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(.white, lineWidth: accent == choice ? 3 : 0))
                                .overlay(Circle().strokeBorder(choice.color, lineWidth: accent == choice ? 1 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .hoverLift(scale: 1.03)
                        .tip(choice.rawValue.capitalized)
                    }
                }
            }
            section("Card text size") {
                Picker("Card text size", selection: $textSize) {
                    ForEach(CardTextSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            section("Card style") {
                Picker("Card style", selection: $cardStyle) {
                    ForEach(CardStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Text(cardStyle == .app
                     ? "Cards use the app's font and colours, so every deck looks consistent."
                     : "Cards keep the fonts and colours the deck's creator chose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            section("Pane behind the card") {
                Picker("Pane behind the card", selection: $paneStyle) {
                    ForEach(CardPaneStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Text(paneStyle == .none
                     ? "No pane: the card's words sit straight on your background."
                     : "How much of your background picture shows through the glass the card sits on while you study.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

private struct ThemeTile: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    let choice: AppearanceChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(width: 104, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? accent.color : .secondary.opacity(0.3),
                                      lineWidth: selected ? 3 : 1))
                Label(choice.title, systemImage: choice.symbol)
                    .font(.callout)
            }
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.03)
    }

    @ViewBuilder private var preview: some View {
        switch choice {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            HStack(spacing: 0) {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
            }
        }
    }
}

/// A tiny drawing of the app window, used as a theme preview.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let bg = dark ? Color(white: 0.16) : Color(white: 0.96)
        let card = dark ? Color(white: 0.24) : .white
        let line = dark ? Color(white: 0.45) : Color(white: 0.8)
        ZStack {
            bg
            RoundedRectangle(cornerRadius: 4)
                .fill(card)
                .padding(10)
                .overlay {
                    VStack(spacing: 4) {
                        Capsule().fill(line).frame(width: 34, height: 4)
                        Capsule().fill(line.opacity(0.6)).frame(width: 22, height: 4)
                    }
                }
        }
    }
}

/// The Settings window (⌘, or the Settings button on Home).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab {
                AnimusSettings()
            } label: {
                Label { Text("Animus") } icon: { Image(nsImage: AnimusGlyph.tabImage) }
            }
            Tab("General", systemImage: "paintbrush") { GeneralPreferences() }
            Tab("Studying", systemImage: "graduationcap") { StudyingPreferences() }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") { SyncPreferences() }
            Tab("Backups", systemImage: "clock.arrow.circlepath") { BackupPreferences() }
            Tab("Collection", systemImage: "wrench.and.screwdriver") { CollectionToolsView() }
            Tab("Pomodoro", systemImage: "timer") { PomodoroPreferences() }
        }
        .frame(width: 560)
    }
}

private struct GeneralPreferences: View {
    @AppStorage(Pref.setupDone) private var setupDone = false
    @AppStorage(Pref.slidesHint) private var slidesHint = true
    @AppStorage(Pref.studyGlow) private var studyGlow = true
    @AppStorage(Pref.perfMeter) private var perfMeter = false
    @AppStorage(Pref.connector) private var connectorOn = false
    @State private var connectorNote: String?
    @AppStorage(UpdateChecker.automaticKey, store: AppDefaults.base) private var autoUpdates = true

    var body: some View {
        // Scrolls, so the window still fits a laptop screen.
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            AppearancePicker()
            BackgroundPicker()
            HeatmapColorPicker()
            Divider()
            Toggle(isOn: $autoUpdates) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for updates automatically")
                    Text("Once a day, Animus asks GitHub whether there's a newer version. Nothing about you or your cards is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.row)
            Toggle(isOn: $studyGlow) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glow when you answer")
                    Text("The card glows red, orange, green or blue for Again, Hard, Good or Easy, and softly while you hover over a button.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.row)
            Toggle(isOn: $perfMeter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Performance meter")
                    Text("A small box in the bottom-left corner showing frames per second, the slowest frame, and how much processor, memory and graphics power is in use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.row)
            Toggle(isOn: $connectorOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude connector (test)")
                    Text("Lets the Claude app on this Mac read your decks and cards and add new cards, while Animus is open. For trying out Animus's AI features; it will be removed later. A backup is made before Claude adds anything.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.row)
            if connectorOn {
                HStack(spacing: 8) {
                    Button("Add to Claude") { connectorNote = Connector.addToClaude() }
                        .tip("Adds Animus to the Claude desktop app's connectors for you")
                    Button("Copy Setup") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Connector.setupText, forType: .string)
                        connectorNote = "Copied. Paste it into Claude's connector settings file."
                    }
                    .tip("Copies the settings to add by hand, e.g. for Claude Code")
                    if let connectorNote {
                        Text(connectorNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle(isOn: $slidesHint) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Slides & Notes hint in Add Cards")
                    Text("A one-line reminder that you can open lecture slides beside the card you're making.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.row)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup and tour")
                    Text("Go through setup again, including the “How it works” tour.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Setup Again…") { setupDone = false }
                    .tip("Your cards stay as they are")
            }
        }
        .padding(24)
        }
        .frame(height: 640)
    }
}

private struct PomodoroPreferences: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pomodoro timer").font(.headline)
            Text("Focus for a while, then take a short break. After a few rounds, take a longer one.")
                .font(.callout).foregroundStyle(.secondary)
            PomodoroSettings()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}

/// Anki's collection-wide preferences, explained. Saved as you change them.
private struct StudyingPreferences: View {
    @Environment(Library.self) private var library
    @State private var prefs: CollectionPreferences?
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let binding = Binding($prefs) {
                form(binding)
            } else if let error {
                Text(error).foregroundStyle(.secondary).padding(24)
            } else if library.engine == nil {
                Text("Open or create a collection first.").foregroundStyle(.secondary).padding(24)
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
        .onChange(of: prefs) { old, new in
            guard old != nil, let new else { return }
            // Save shortly after the last change.
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                do { try await library.savePreferences(new) } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func form(_ p: Binding<CollectionPreferences>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your day").font(.headline)
            row("Next day starts at", "When yesterday's cards stop counting and today's become due. Pick a time you're usually asleep.") {
                NumberPill(value: p.nextDayStartsAt, range: 0...23, wraps: true, text: Self.hourText)
            }
            row("Learn ahead limit", "If nothing else is left, show learning cards that are due within this many minutes instead of making you wait.") {
                stepper(p.learnAheadMinutes, 0...240, suffix: "min")
            }
            row("Study time limit", "Get a gentle nudge after studying this long in one go. 0 turns it off.") {
                stepper(p.timeLimitMinutes, 0...240, suffix: "min")
            }

            Divider()
            Text("Card order").font(.headline)
            row("New cards", "Where new cards go among your reviews.") {
                Picker("New card order", selection: p.newReviewMix) {
                    Text("Mixed in").tag("mix")
                    Text("After reviews").tag("reviews_first")
                    Text("Before reviews").tag("new_first")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            toggleRow("Learning cards first", "Show cards you were learning on earlier days before other reviews.", p.dayLearnFirst)
            toggleRow("Spread reviews evenly", "Nudges due dates so you don't get a huge pile on one day (needs FSRS).", p.loadBalancer)

            Divider()
            Text("Study screen").font(.headline)
            toggleRow("Show next review time on buttons", "The “10m”, “4d” under Again, Hard, Good and Easy.", p.showIntervalsOnButtons)
            toggleRow("Show remaining card counts", "The New, Learning and Due numbers at the top while you study.", p.showRemainingDueCounts)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding(24)
    }

    private func row<Control: View>(_ title: String, _ help: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
    }

    private func toggleRow(_ title: String, _ help: String, _ value: Binding<Bool>) -> some View {
        row(title, help) { Toggle("", isOn: value).toggleStyle(.switch).labelsHidden() }
    }

    private func stepper(_ value: Binding<Int>, _ range: ClosedRange<Int>, suffix: String) -> some View {
        NumberPill(value: value, range: range, unit: suffix)
    }

    static func hourText(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour)) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private func load() async {
        guard let engine = library.engine else { return }
        do { prefs = try await engine.preferences() } catch { self.error = error.localizedDescription }
    }
}

/// The heatmap's colour. Lives here only, so the heatmap itself stays clean.
struct HeatmapColorPicker: View {
    @AppStorage(HeatmapColor.key) private var choice = HeatmapColor.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heatmap colour").font(.headline)
            HStack(spacing: 10) {
                ForEach(HeatmapColor.allCases) { option in
                    Button {
                        choice = option
                    } label: {
                        HStack(spacing: 2) {
                            ForEach(Array(option.ramp(dark: false).enumerated()), id: \.offset) { _, color in
                                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 14)
                            }
                        }
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(choice == option ? Color.accentColor : Color.secondary.opacity(0.25),
                                          lineWidth: choice == option ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .tip(option.title)
                }
            }
        }
    }
}

/// Backups: made automatically; restore any of them from here.
private struct BackupPreferences: View {
    @Environment(Library.self) private var library
    @State private var backups: [Library.Backup] = []
    @State private var restoring: Library.Backup?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backups").font(.headline)
            Text("Animus backs up your cards when it opens, every 30 minutes while you study, and before any big sync change. Older backups are thinned to daily, weekly and monthly copies.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    Task {
                        working = true
                        await library.backup(force: true)
                        backups = Library.backups()
                        working = false
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Label("Back Up Now", systemImage: "plus.circle") }
                }
                .disabled(working || library.engine == nil)
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: Library.backupFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Library.backupFolder)
                }
            }
            if backups.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(backups) { backup in
                            HStack {
                                Image(systemName: "archivebox").foregroundStyle(.secondary)
                                Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                                Text(ByteCountFormatter.string(fromByteCount: Int64(backup.bytes), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore…") { restoring = backup }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { backups = Library.backups() }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            presenting: restoring) { backup in
            Button("Restore") { Task { await library.restore(backup); backups = Library.backups() } }
        } message: { backup in
            Text("Your cards go back to how they were on \(backup.date.formatted(date: .complete, time: .shortened)). Your current cards are backed up first, so you can undo this by restoring that one. If you sync, choose which copy to keep afterwards.")
        }
    }
}
