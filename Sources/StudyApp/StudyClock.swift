import AppKit
import Observation
import SwiftUI

/// Times how long you actually study. It runs while a deck is open on the
/// study screen, and stops counting when you switch to another app, take a
/// Pomodoro break, or leave it untouched for a few minutes.
@MainActor
@Observable
final class StudyClock {
    /// Seconds counted in the current study session.
    private(set) var sessionSeconds = 0
    private(set) var isRunning = false
    /// True while counting is held back (idle, on a break, or app in the background).
    private(set) var isPaused = false
    /// Bumped whenever totals change, so Home refreshes.
    private(set) var revision = 0

    var onBreak = false

    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var unsaved = 0

    /// No answer or key press for this long and the clock stops counting.
    static let idleLimit: TimeInterval = 3 * 60
    private static let key = "studySeconds"

    func start() {
        sessionSeconds = 0
        lastActivity = Date()
        isRunning = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        isRunning = false
        isPaused = false
        save()
    }

    /// Something happened (a card shown, an answer, a key press).
    func activity() {
        lastActivity = Date()
    }

    private func tick() {
        let idle = Date().timeIntervalSince(lastActivity) > Self.idleLimit
        let paused = idle || onBreak || !NSApplication.shared.isActive
        if paused != isPaused { isPaused = paused }
        guard !paused else { return }
        sessionSeconds += 1
        unsaved += 1
        if unsaved >= 15 { save() }
    }

    private func save() {
        guard unsaved > 0 else { return }
        var all = Self.all()
        all[Self.dayKey(Date()), default: 0] += unsaved
        AppDefaults.current.set(all, forKey: Self.key)
        unsaved = 0
        revision += 1
    }

    // MARK: Totals

    private static func all() -> [String: Int] {
        AppDefaults.current.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Seconds studied on a given day, including what hasn't been saved yet today.
    func seconds(on date: Date) -> Int {
        let saved = Self.all()[Self.dayKey(date)] ?? 0
        return saved + (Calendar.current.isDateInToday(date) ? unsaved : 0)
    }

    var todaySeconds: Int { seconds(on: Date()) }

    /// The last seven days, today included.
    var weekSeconds: Int {
        (0..<7).reduce(0) { total, back in
            let day = Calendar.current.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            return total + seconds(on: day)
        }
    }

    /// e.g. "0 min", "24 min", "1 h 05 min".
    static func format(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// e.g. "4:07" or "1:02:33", for the running clock.
    static func clock(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The running clock on the study screen.
struct StudyClockBadge: View {
    @Environment(StudyClock.self) private var clock

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: clock.isPaused ? "pause.circle" : "stopwatch")
            Text(clock.isPaused ? "Paused" : StudyClock.clock(clock.sessionSeconds))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .tip(clock.isPaused
              ? "The study timer pauses during breaks, when you switch apps, or after 3 minutes without a card"
              : "Time studied this session")
    }
}
