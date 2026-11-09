#if os(macOS)
import AppKit
#else
import AudioToolbox
import UserNotifications
#endif
import Observation
import SwiftUI

/// A Pomodoro timer: focus for a while, take a short break, and after a few
/// rounds take a longer one. Every length is up to the student.
@MainActor
@Observable
final class Pomodoro {
    enum Phase: String {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus: "Focus"
            case .shortBreak: "Short break"
            case .longBreak: "Long break"
            }
        }
        var symbol: String {
            switch self {
            case .focus: "brain.head.profile"
            case .shortBreak: "cup.and.saucer.fill"
            case .longBreak: "figure.walk"
            }
        }
        var color: Color {
            switch self {
            case .focus: .red
            case .shortBreak: .green
            case .longBreak: .teal
            }
        }
        var isBreak: Bool { self != .focus }
    }

    private(set) var phase: Phase = .focus
    private(set) var isRunning = false
    private(set) var remaining: TimeInterval
    /// Focus rounds finished since the last long break.
    private(set) var roundsDone = 0
    /// Focus rounds finished today, for the little counter.
    private(set) var focusToday = 0

    private var endDate: Date?
    private var ticker: Task<Void, Never>?

    init() {
        remaining = Self.length(of: .focus)
    }

    // MARK: Settings (minutes)

    static func length(of phase: Phase) -> TimeInterval {
        let d = AppDefaults.current
        let minutes: Int
        switch phase {
        case .focus: minutes = d.object(forKey: PomodoroPref.focus) as? Int ?? 25
        case .shortBreak: minutes = d.object(forKey: PomodoroPref.shortBreak) as? Int ?? 5
        case .longBreak: minutes = d.object(forKey: PomodoroPref.longBreak) as? Int ?? 15
        }
        return TimeInterval(max(1, minutes) * 60)
    }

    private var roundsBeforeLong: Int {
        max(1, AppDefaults.current.object(forKey: PomodoroPref.rounds) as? Int ?? 4)
    }

    private func setting(_ key: String, default value: Bool) -> Bool {
        AppDefaults.current.object(forKey: key) as? Bool ?? value
    }

    var progress: Double {
        let total = Self.length(of: phase)
        return total > 0 ? 1 - remaining / total : 0
    }

    var timeText: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Controls

    func start() {
        guard !isRunning else { return }
        isRunning = true
        endDate = Date().addingTimeInterval(remaining)
        #if os(iOS)
        PhaseAlert.schedule(after: remaining, phase: phase)
        #endif
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    func pause() {
        guard isRunning else { return }
        tick()
        isRunning = false
        endDate = nil
        #if os(iOS)
        PhaseAlert.cancel()
        #endif
        ticker?.cancel()
        ticker = nil
    }

    func toggle() { isRunning ? pause() : start() }

    /// Back to the start of the current phase.
    func reset() {
        pause()
        remaining = Self.length(of: phase)
    }

    /// Jump straight to the next phase.
    func skip() {
        advance(playSound: false)
    }

    /// Called when the lengths change in Settings.
    func settingsChanged() {
        if !isRunning { remaining = Self.length(of: phase) }
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 { advance(playSound: true) }
    }

    private func advance(playSound: Bool) {
        let wasRunning = isRunning
        pause()
        if phase == .focus {
            roundsDone += 1
            focusToday += 1
            phase = roundsDone >= roundsBeforeLong ? .longBreak : .shortBreak
            if phase == .longBreak { roundsDone = 0 }
        } else {
            phase = .focus
        }
        remaining = Self.length(of: phase)
        if playSound, setting(PomodoroPref.sound, default: true) {
            #if os(macOS)
            NSSound(named: phase.isBreak ? "Glass" : "Hero")?.play()
            #else
            AudioServicesPlaySystemSound(phase.isBreak ? 1025 : 1005)
            #endif
        }
        let auto = phase.isBreak
            ? setting(PomodoroPref.autoBreaks, default: true)
            : setting(PomodoroPref.autoFocus, default: false)
        if auto && (wasRunning || playSound) { start() }
    }
}

#if os(iOS)
/// On iPhone and iPad the app may be closed when a phase ends, so the phone
/// shows an alert instead (asked for the first time the timer starts).
enum PhaseAlert {
    private static let id = "animus.pomodoro"

    static func schedule(after seconds: TimeInterval, phase: Pomodoro.Phase) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = phase.isBreak ? "Break's over" : "Time for a break"
            content.body = phase.isBreak ? "Back to your cards when you're ready." : "Nice focus. Take a few minutes off."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
#endif

enum PomodoroPref {
    static let focus = "pomodoro.focus"
    static let shortBreak = "pomodoro.short"
    static let longBreak = "pomodoro.long"
    static let rounds = "pomodoro.rounds"
    static let autoBreaks = "pomodoro.autoBreaks"
    static let autoFocus = "pomodoro.autoFocus"
    static let sound = "pomodoro.sound"
}

// MARK: - Toolbar button

/// The one "Timers" button in the toolbar: Pomodoro and the study timer.
/// While one is running, the button shows its time.
struct TimersButton: View {
    @Environment(Pomodoro.self) private var pomodoro
    @Environment(SimpleTimer.self) private var studyTimer
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            if pomodoro.isRunning || pomodoro.progress > 0 {
                TimerPill(symbol: pomodoro.phase.symbol, text: pomodoro.timeText,
                          color: pomodoro.isRunning ? pomodoro.phase.color : .secondary, countsDown: true)
            } else if studyTimer.hasStarted {
                TimerPill(symbol: "stopwatch", text: studyTimer.text,
                          color: studyTimer.isRunning ? .blue : .secondary)
            } else {
                TimerPill(symbol: "timer", text: "Timers")
            }
        }
        .buttonStyle(.plain)
        .tip("Pomodoro and study timer")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TimersPanel()
        }
    }
}

/// The popover: pick Pomodoro or the study timer at the top.
struct TimersPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case pomodoro, studyTimer
        var id: String { rawValue }
        var title: String { self == .pomodoro ? "Pomodoro" : "Study timer" }
    }

    @AppStorage("timers.tab") private var tab = Tab.pomodoro

    var body: some View {
        VStack(spacing: 16) {
            Picker("Timer", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .pomodoro: PomodoroPanel()
            case .studyTimer: StudyTimerPanel()
            }
        }
        .padding(20)
        .frame(width: 310)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The labelled capsule used by the toolbar timers.
struct TimerPill: View {
    let symbol: String
    let text: String
    /// Coloured while running; nil = idle.
    var color: Color?
    var countsDown = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color ?? .secondary)
            Text(text)
                .font(.callout.weight(.medium).monospacedDigit())
                .contentTransition(.numericText(countsDown: countsDown))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill((color ?? .primary).opacity(color == nil ? (hovering ? 0.12 : 0.07) : 0.18)))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}

/// The popover: a ring, the controls, and your own lengths.
struct PomodoroPanel: View {
    @Environment(Pomodoro.self) private var timer
    @State private var editing = false

    @State private var explaining = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(explaining ? "What is a Pomodoro timer?" : "Focus in blocks, with breaks between")
                    .font(explaining ? .headline : .callout)
                    .foregroundStyle(explaining ? .primary : .secondary)
                Spacer()
                Button {
                    explaining.toggle()
                } label: {
                    Image(systemName: explaining ? "xmark.circle.fill" : "questionmark.circle")
                }
                .buttonStyle(.hoverable)
                .tip(explaining ? "Back to the timer" : "What is a Pomodoro timer?")
            }
            if explaining {
                // Takes the timer's place (a pop-up from a pop-up would close this one,
                // and stacking both made the panel too tall).
                PomodoroExplainer()
                Button("Got it") { explaining = false }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                    .controlSize(.large)
            } else {
                timerFace
            }
        }
    }

    @ViewBuilder private var timerFace: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
            Circle()
                .trim(from: 0, to: timer.progress)
                .stroke(timer.phase.color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: timer.progress)
            VStack(spacing: 4) {
                Label(timer.phase.title, systemImage: timer.phase.symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(timer.timeText)
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .frame(width: 180, height: 180)

        HStack(spacing: 10) {
            Button(action: timer.reset) { Image(systemName: "arrow.counterclockwise") }
                .tip("Restart this phase")
            Button(action: timer.toggle) {
                Label(timer.isRunning ? "Pause" : "Start", systemImage: timer.isRunning ? "pause.fill" : "play.fill")
                    .frame(width: 90)
            }
            .buttonStyle(.borderedProminent)
            .hoverGlow()
            .tint(timer.phase.color)
            Button(action: timer.skip) { Image(systemName: "forward.end.fill") }
                .tip(timer.phase.isBreak ? "Skip the break" : "Skip to the break")
        }
        .controlSize(.large)

        Text(timer.focusToday == 1 ? "1 focus session today" : "\(timer.focusToday) focus sessions today")
            .font(.caption)
            .foregroundStyle(.secondary)

        PomodoroTaskList()

        DisclosureGroup("Customise", isExpanded: $editing) {
            PomodoroSettings()
                .padding(.top, 8)
        }
    }
}

/// The lengths and options. Also shown in Settings (⌘,).
struct PomodoroSettings: View {
    @Environment(Pomodoro.self) private var timer
    @AppStorage(PomodoroPref.focus) private var focus = 25
    @AppStorage(PomodoroPref.shortBreak) private var shortBreak = 5
    @AppStorage(PomodoroPref.longBreak) private var longBreak = 15
    @AppStorage(PomodoroPref.rounds) private var rounds = 4
    @AppStorage(PomodoroPref.autoBreaks) private var autoBreaks = true
    @AppStorage(PomodoroPref.autoFocus) private var autoFocus = false
    @AppStorage(PomodoroPref.sound) private var sound = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pillRow("Focus", NumberPill(value: $focus, range: 1...180, unit: "min"))
            pillRow("Short break", NumberPill(value: $shortBreak, range: 1...60, unit: "min"))
            pillRow("Long break", NumberPill(value: $longBreak, range: 1...120, unit: "min"))
            pillRow("Long break every", NumberPill(value: $rounds, range: 1...12, unit: "rounds"))
            Toggle("Start breaks automatically", isOn: $autoBreaks).toggleStyle(.row)
            Toggle("Start focus automatically after a break", isOn: $autoFocus).toggleStyle(.row)
            Toggle("Play a sound when time's up", isOn: $sound).toggleStyle(.row)
        }
        .onChange(of: focus) { timer.settingsChanged() }
        .onChange(of: shortBreak) { timer.settingsChanged() }
        .onChange(of: longBreak) { timer.settingsChanged() }
    }
}

// MARK: - Break screen

/// Covers the study screen during a running break, so you actually take it.
struct BreakOverlay: View {
    @Environment(Pomodoro.self) private var timer

    var body: some View {
        if timer.phase.isBreak && timer.isRunning {
            VStack(spacing: 16) {
                Image(systemName: timer.phase.symbol)
                    .font(.system(size: 54))
                    .foregroundStyle(timer.phase.color)
                    .symbolRenderingMode(.hierarchical)
                Text(timer.phase == .longBreak ? "Time for a proper break" : "Time for a quick break")
                    .font(.title.weight(.semibold))
                Text("Stand up, stretch, grab some water. Your cards will be here.")
                    .foregroundStyle(.secondary)
                Text(timer.timeText)
                    .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
                Button("Skip break and keep studying", action: timer.skip)
                    .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .transition(.opacity)
        }
    }
}

/// The "?" in the Pomodoro panel: what the technique is and why it helps.
struct PomodoroExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A simple way to study in focused bursts. It's named after the tomato-shaped kitchen timer its inventor used.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step("1", "Focus for 25 minutes. No phone, no new tabs.")
                step("2", "Take a 5-minute break. Stand up, stretch, get water.")
                step("3", "Repeat. After 4 rounds, take a longer 15-minute break.")
            }
            Text("Short breaks keep your concentration fresh, so you remember more and burn out less. In Animus, a break covers the study screen so you actually rest. Change the lengths under Customise.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.red.gradient))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Tasks

/// A short to-do list for your Pomodoro sessions: what you mean to get done.
@MainActor
@Observable
final class PomodoroTasks {
    struct Item: Codable, Identifiable, Hashable {
        var id = UUID()
        var title: String
        var done = false
    }

    private(set) var items: [Item] = []
    private static let key = "pomodoro.tasks"

    init() {
        if let data = AppDefaults.current.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        items.append(Item(title: trimmed))
        save()
    }

    func toggle(_ item: Item) {
        guard let i = items.firstIndex(of: item) else { return }
        items[i].done.toggle()
        save()
    }

    func delete(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearDone() {
        items.removeAll(where: \.done)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            AppDefaults.current.set(data, forKey: Self.key)
        }
    }
}

/// The task list shown under the Pomodoro timer.
struct PomodoroTaskList: View {
    @Environment(PomodoroTasks.self) private var tasks
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasks").font(.subheadline.weight(.semibold))
                Spacer()
                if tasks.items.contains(where: \.done) {
                    Button("Clear done") { withAnimation { tasks.clearDone() } }
                        .buttonStyle(.hoverable)
                        .font(.caption)
                }
            }
            HStack(spacing: 6) {
                TextField("Add a task, e.g. Cardiology deck", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }
                    .buttonStyle(.hoverable)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .tip("Add task")
            }
            if !tasks.items.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tasks.items) { item in
                            TaskRow(item: item)
                        }
                    }
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: tasks.items.count < 5)
            }
        }
    }

    private func add() {
        withAnimation { tasks.add(draft) }
        draft = ""
    }
}

private struct TaskRow: View {
    @Environment(PomodoroTasks.self) private var tasks
    let item: PomodoroTasks.Item
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button { withAnimation { tasks.toggle(item) } } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Color.green : .secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .tip(item.done ? "Mark as not done" : "Mark as done")
            Text(item.title)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button { withAnimation { tasks.delete(item) } } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.hoverable)
            .opacity(hovering ? 1 : 0.35)
            .tip("Delete task")
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }
}


/// A label on the left and a number chooser on the right edge.
func pillRow(_ title: String, _ pill: NumberPill) -> some View {
    HStack {
        Text(title)
        Spacer(minLength: 12)
        pill
    }
}
