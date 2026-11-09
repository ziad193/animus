#if os(macOS)
import AppKit
#endif
import Observation
import SwiftUI

/// The study timer: a stopwatch for timing a study session. Finishing a
/// session saves it, so you can see how long you studied today.
@MainActor
@Observable
final class SimpleTimer {
    struct Session: Codable, Identifiable, Hashable {
        var id = UUID()
        let ended: Date
        let seconds: Int
    }

    private(set) var isRunning = false
    /// Seconds counted so far in this session.
    private(set) var elapsed: TimeInterval = 0
    /// Finished sessions, newest first (the last two weeks).
    private(set) var sessions: [Session] = []

    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var banked: TimeInterval = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    private static let key = "studyTimer.sessions"

    init() {
        if let data = AppDefaults.current.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = saved
        }
    }

    var hasStarted: Bool { isRunning || elapsed > 0 }

    var text: String { Self.clock(Int(elapsed)) }

    var todaySessions: [Session] {
        sessions.filter { Calendar.current.isDateInToday($0.ended) }
    }

    var todayTotal: Int { todaySessions.reduce(0) { $0 + $1.seconds } }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startedAt = Date()
        banked = elapsed
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
        stop()
    }

    func toggle() { isRunning ? pause() : start() }

    /// Ends the session and saves how long it was.
    func finish() {
        pause()
        let seconds = Int(elapsed)
        elapsed = 0
        guard seconds >= 5 else { return }
        sessions.insert(Session(ended: Date(), seconds: seconds), at: 0)
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        sessions.removeAll { $0.ended < cutoff }
        if let data = try? JSONEncoder().encode(sessions) {
            AppDefaults.current.set(data, forKey: Self.key)
        }
    }

    /// Removes a saved session.
    func delete(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    /// Removes all of today's saved sessions.
    func clearToday() {
        sessions.removeAll { Calendar.current.isDateInToday($0.ended) }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sessions) {
            AppDefaults.current.set(data, forKey: Self.key)
        }
    }

    /// Throws the current session away without saving it.
    func discard() {
        stop()
        elapsed = 0
    }

    private func stop() {
        isRunning = false
        startedAt = nil
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = banked + Date().timeIntervalSince(startedAt)
    }

    /// e.g. "4:07" or "1:02:33".
    static func clock(_ s: Int) -> String {
        s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The study timer's side of the Timers panel.
struct StudyTimerPanel: View {
    @Environment(SimpleTimer.self) private var timer

    var body: some View {
        VStack(spacing: 16) {
            Text("Time your study session. Press Finish when you're done to save it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            ZStack {
                Circle().stroke(timer.isRunning ? Color.blue.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 8)
                VStack(spacing: 2) {
                    Label(timer.isRunning ? "Studying" : (timer.hasStarted ? "Paused" : "Ready"),
                          systemImage: timer.isRunning ? "stopwatch.fill" : "stopwatch")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(timer.text)
                        .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                }
            }
            .frame(width: 170, height: 170)

            HStack(spacing: 10) {
                Button(action: timer.discard) { Image(systemName: "trash") }
                    .tip("Throw this session away")
                    .disabled(!timer.hasStarted)
                Button(action: timer.toggle) {
                    Label(timer.isRunning ? "Pause" : (timer.hasStarted ? "Resume" : "Start"),
                          systemImage: timer.isRunning ? "pause.fill" : "play.fill")
                        .frame(width: 84)
                }
                .buttonStyle(.borderedProminent)
                .hoverGlow()
                Button(action: timer.finish) { Label("Finish", systemImage: "checkmark") }
                    .tip("End the session and save it")
                    .disabled(!timer.hasStarted)
            }
            .controlSize(.large)

            if !timer.todaySessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Today").font(.subheadline.weight(.semibold))
                        Text("\(StudyClock.format(timer.todayTotal)) in total")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { withAnimation { timer.clearToday() } }
                            .buttonStyle(.hoverable)
                            .font(.caption)
                            .tip("Delete all of today's sessions")
                    }
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(timer.todaySessions) { session in
                                SessionRow(session: session)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: timer.todaySessions.count < 5)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(SimpleTimer.self) private var timer
    let session: SimpleTimer.Session
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(session.ended.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
            Spacer()
            Text(SimpleTimer.clock(session.seconds)).monospacedDigit()
            Button { withAnimation { timer.delete(session) } } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.hoverable)
            .opacity(hovering ? 1 : 0.35)
            .tip("Delete this session")
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }
}
