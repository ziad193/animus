import SwiftUI
import StudyCore

/// Make a filtered deck: a temporary deck that borrows cards matching what
/// you pick. When you finish studying it, the cards go back where they came from.
struct FilteredDeckSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// The deck to borrow from (nil = all decks).
    let startDeck: Int64?
    let created: (Int64) -> Void

    enum Preset: String, CaseIterable, Identifiable {
        case forgotten, ahead, struggling, preview, tagged, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .forgotten: "Cards I forgot recently"
            case .ahead: "Study ahead"
            case .struggling: "Cards I keep forgetting"
            case .preview: "Preview new cards"
            case .tagged: "Cards with a tag"
            case .custom: "My own search"
            }
        }

        var subtitle: String {
            switch self {
            case .forgotten: "Ones you pressed Again on in the last week"
            case .ahead: "Reviews coming up in the next few days, done early (e.g. before an exam)"
            case .struggling: "Forgotten 3 or more times; worth extra practice"
            case .preview: "New cards you haven't seen yet"
            case .tagged: "Everything with a tag you choose"
            case .custom: "Type an Anki search, for experts"
            }
        }

        var symbol: String {
            switch self {
            case .forgotten: "arrow.uturn.backward.circle"
            case .ahead: "calendar.badge.clock"
            case .struggling: "exclamationmark.triangle"
            case .preview: "sparkles"
            case .tagged: "tag"
            case .custom: "magnifyingglass"
            }
        }
    }

    @State private var preset: Preset = .forgotten
    @State private var deckID: Int64?
    @State private var aheadDays = 3
    @State private var tag = ""
    @State private var custom = ""
    @State private var limit = 50
    @State private var order = "random"
    @State private var reschedule = true
    @State private var matches: Int?
    @State private var error: String?
    @State private var working = false

    private var decks: [Deck] {
        if case .ready(let decks) = library.state { return decks }
        return []
    }

    /// The Anki search the choices above add up to.
    private var search: String {
        var parts: [String] = []
        switch preset {
        case .forgotten: parts.append("rated:7:1")
        case .ahead: parts.append("prop:due<=\(aheadDays)")
        case .struggling: parts.append("prop:lapses>=3")
        case .preview: parts.append("is:new")
        case .tagged: parts.append(tag.isEmpty ? "tag:none-chosen" : "tag:\(tag.replacingOccurrences(of: " ", with: "_"))")
        case .custom: parts.append(custom.isEmpty ? "deck:none-chosen" : "(\(custom))")
        }
        if let deckID, let deck = Deck.find(deckID, in: decks) {
            parts.append("did:" + deck.idsIncludingSections.map(String.init).joined(separator: ","))
        }
        // Cards already in another filtered deck, suspended or buried can't be borrowed.
        parts.append("-is:suspended -is:buried")
        return parts.joined(separator: " ")
    }

    private var name: String {
        let from = deckID.flatMap { Deck.find($0, in: decks)?.shortName }
        return from.map { "\(preset.title) · \($0)" } ?? preset.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Make a filtered deck", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.title2.weight(.semibold))
                Text("A temporary deck that borrows the cards you pick. Study it like any other deck. When you're done, it disappears and the cards go back to their own decks.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Which cards?").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Preset.allCases) { option in
                        presetTile(option)
                    }
                }
                switch preset {
                case .ahead:
                    Stepper("Due in the next \(aheadDays) day\(aheadDays == 1 ? "" : "s")", value: $aheadDays, in: 1...60)
                case .tagged:
                    TextField("Tag, e.g. cardiology", text: $tag).textFieldStyle(.roundedBorder)
                case .custom:
                    TextField("e.g. heart is:review prop:ivl>30", text: $custom).textFieldStyle(.roundedBorder)
                default:
                    EmptyView()
                }
            }

            HStack(spacing: 12) {
                Text("From").font(.headline)
                DeckPickerButton(decks: decks, selection: $deckID, emptyTitle: "All decks", allowsAll: true)
            }

            HStack(spacing: 18) {
                Stepper("Up to \(limit) cards", value: $limit, in: 1...9999, step: limit < 50 ? 5 : 25)
                Picker("Order", selection: $order) {
                    Text("Random").tag("random")
                    Text("Due first").tag("due")
                    Text("Most forgotten first").tag("lapses")
                    Text("Oldest reviewed first").tag("oldest_reviewed")
                    Text("Recently added first").tag("added")
                }
                .fixedSize()
            }

            Toggle(isOn: $reschedule) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Count my answers towards normal reviews")
                    Text(reschedule ? "Studying here moves cards along their schedule, as usual."
                                    : "Practice only: cards go back exactly as they were.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Group {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if let matches {
                        Label(matches == 0 ? "No cards match yet" : "\(min(matches, limit)) of \(matches.formatted()) matching cards",
                              systemImage: matches == 0 ? "tray" : "checkmark.circle")
                            .foregroundStyle(matches == 0 ? Color.secondary : Color.green)
                    }
                }
                .font(.callout)
                .lineLimit(2)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await create() }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Make & Study") }
                }
                .buttonStyle(.borderedProminent)
                .hoverGlow()
                .keyboardShortcut(.defaultAction)
                .disabled(working || matches == 0)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { deckID = startDeck }
        .task(id: search) { await count() }
    }

    private func presetTile(_ option: Preset) -> some View {
        let isOn = preset == option
        return Button {
            preset = option
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: option.symbol)
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.white : Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(.callout.weight(.semibold))
                        .foregroundStyle(isOn ? Color.white : .primary)
                    Text(option.subtitle).font(.caption)
                        .foregroundStyle(isOn ? Color.white.opacity(0.85) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.05))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.02)
    }

    /// How many cards the choices match, updated as you change them.
    private func count() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let engine = library.engine else { return }
        do {
            matches = try await engine.search(search).count
            error = nil
        } catch {
            matches = nil
            self.error = "That search doesn't look right."
        }
    }

    private func create() async {
        guard let engine = library.engine else { return }
        working = true
        defer { working = false }
        do {
            let id = try await engine.createFilteredDeck(name: name, search: search, limit: limit,
                                                         order: order, reschedule: reschedule)
            await library.refresh()
            dismiss()
            created(id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
