import SwiftUI
import StudyCore

/// On the "All done" screen: one click to keep going past today's limits.
struct StudyMoreOffer: View {
    @Environment(Library.self) private var library
    let deck: Deck
    let restarted: () -> Void
    @State private var extra: (extraNew: Int, extraReviews: Int)?

    var body: some View {
        Group {
            if let extra, extra.extraNew > 0 || extra.extraReviews > 0 {
                VStack(spacing: 8) {
                    Text("Want to keep going?").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if extra.extraNew > 0 {
                            boost("+\(min(10, extra.extraNew)) new cards", "sparkles") {
                                try await $0.studyMore(deck.id, newCards: min(10, extra.extraNew))
                            }
                        }
                        if extra.extraReviews > 0 {
                            boost("+\(min(50, extra.extraReviews)) reviews", "arrow.clockwise") {
                                try await $0.studyMore(deck.id, reviews: min(50, extra.extraReviews))
                            }
                        }
                    }
                    Text("Raises today's limit only; tomorrow goes back to normal.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .task { extra = try? await library.engine?.studyMoreInfo(deck.id) }
    }

    private func boost(_ title: String, _ symbol: String, _ work: @escaping (Engine) async throws -> Void) -> some View {
        Button {
            Task {
                guard let engine = library.engine else { return }
                do {
                    try await work(engine)
                    restarted()
                } catch {
                    library.notice = error.localizedDescription
                }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .hoverGlow()
    }
}

/// From the deck's cog: raise today's limits by any amount.
struct StudyMoreSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let deck: Deck
    @State private var extra: (extraNew: Int, extraReviews: Int)?
    @State private var newCards = 10
    @State private var reviews = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Study more today", systemImage: "plus.circle").font(.title2.weight(.semibold))
            Text("Adds extra cards to “\(deck.shortName)” for today only. Your normal daily limits come back tomorrow.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let extra {
                Stepper(value: $newCards, in: 0...max(0, extra.extraNew), step: 5) {
                    Text("\(newCards) extra new cards").monospacedDigit()
                    Text("\(extra.extraNew) available").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(extra.extraNew == 0)
                Stepper(value: $reviews, in: 0...max(0, extra.extraReviews), step: 10) {
                    Text("\(reviews) extra reviews").monospacedDigit()
                    Text(extra.extraReviews == 0 ? "No reviews are waiting past today's limit"
                                                 : "\(extra.extraReviews) waiting past today's limit")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(extra.extraReviews == 0)
                Text("To study cards early, practise ones you forgot, or preview new ones, use “Filtered Deck From This…” in the same menu.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView()
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add for Today") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                    .keyboardShortcut(.defaultAction)
                    .disabled(newCards == 0 && reviews == 0)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task {
            let info = try? await library.engine?.studyMoreInfo(deck.id)
            extra = info ?? (0, 0)
            newCards = min(10, extra?.extraNew ?? 0)
        }
    }

    private func save() async {
        guard let engine = library.engine else { return }
        do {
            try await engine.studyMore(deck.id, newCards: newCards, reviews: reviews)
            await library.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
