import Foundation
import Observation
import SwiftUI
import StudyCore

/// An exam you're counting down to, optionally tied to the deck you revise it with.
struct Exam: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date: Date
    var deckID: Int64?

    /// Whole days from today to the exam (0 = today).
    var daysLeft: Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                       to: calendar.startOfDay(for: date)).day ?? 0
    }
}

/// Saved exams, kept on this Mac.
@MainActor
@Observable
final class ExamStore {
    private(set) var exams: [Exam] = []
    private static let key = "exams"

    init() {
        if let data = AppDefaults.current.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Exam].self, from: data) {
            exams = saved
        }
    }

    /// Exams from today onwards, soonest first. Past ones drop off the next day.
    var upcoming: [Exam] {
        exams.filter { $0.daysLeft >= 0 }.sorted { $0.date < $1.date }
    }

    func save(_ exam: Exam) {
        if let index = exams.firstIndex(where: { $0.id == exam.id }) {
            exams[index] = exam
        } else {
            exams.append(exam)
        }
        persist()
    }

    func delete(_ exam: Exam) {
        exams.removeAll { $0.id == exam.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(exams) {
            AppDefaults.current.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Home panel

/// The exam countdowns on Home, with a button to add one.
struct ExamCountdowns: View {
    @Environment(ExamStore.self) private var store
    let decks: [Deck]
    let study: (Deck) -> Void

    @State private var editing: Exam?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Exam countdown").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    editing = Exam(name: "", date: Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date())
                } label: {
                    Label("Add Exam", systemImage: "plus")
                }
                .buttonStyle(.hoverable)
            }
            if store.upcoming.isEmpty {
                Button {
                    editing = Exam(name: "", date: Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date())
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add your next exam").font(.headline)
                            Text("See how many days you have left, right here on Home.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.separator))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift(scale: 1.005)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(store.upcoming) { exam in
                        ExamCard(exam: exam, deck: exam.deckID.flatMap { Deck.find($0, in: decks) },
                                 edit: { editing = exam }, study: study)
                    }
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5)))
        .sheet(item: $editing) { exam in
            ExamEditor(exam: exam, decks: decks, isNew: !store.exams.contains { $0.id == exam.id })
        }
    }
}

private struct ExamCard: View {
    let exam: Exam
    let deck: Deck?
    let edit: () -> Void
    let study: (Deck) -> Void

    /// Turns orange in the last fortnight and red in the last three days.
    private var color: Color {
        switch exam.daysLeft {
        case ...3: .red
        case ...14: .orange
        default: .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(exam.daysLeft == 0 ? "Today" : "\(exam.daysLeft)")
                    .font(.system(size: exam.daysLeft == 0 ? 22 : 32, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                if exam.daysLeft > 0 {
                    Text(exam.daysLeft == 1 ? "day" : "days")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 64)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))

            VStack(alignment: .leading, spacing: 4) {
                Text(exam.name).font(.headline).lineLimit(2)
                Text(exam.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let deck {
                    Button {
                        study(deck)
                    } label: {
                        Label(deck.dueToday > 0 ? "Study \(deck.shortName) · \(deck.dueToday)" : "\(deck.shortName) · all done",
                              systemImage: deck.dueToday > 0 ? "play.fill" : "checkmark")
                            .lineLimit(1)
                    }
                    .buttonStyle(.hoverable)
                    .disabled(deck.dueToday == 0)
                    .font(.callout)
                }
            }
            Spacer(minLength: 0)
            Button(action: edit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.hoverable)
            .help("Edit or remove this exam")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
    }
}

private struct ExamEditor: View {
    @Environment(ExamStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var exam: Exam
    let decks: [Deck]
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "Add an exam" : "Edit exam").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline.weight(.medium))
                TextField("e.g. Anatomy OSCE", text: $exam.name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Date").font(.subheadline.weight(.medium))
                DatePicker("Date", selection: $exam.date, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Deck to revise with (optional)").font(.subheadline.weight(.medium))
                DeckPickerButton(decks: decks, selection: $exam.deckID, emptyTitle: "No deck", allowsAll: true)
            }
            HStack {
                if !isNew {
                    Button("Remove", role: .destructive) {
                        store.delete(exam)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    exam.name = exam.name.trimmingCharacters(in: .whitespaces)
                    store.save(exam)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .hoverGlow()
                .keyboardShortcut(.defaultAction)
                .disabled(exam.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
