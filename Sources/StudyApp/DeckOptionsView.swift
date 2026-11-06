import SwiftUI
import StudyCore

/// A deck's study settings, explained in plain words.
///
/// Like Anki, settings live in a "preset" that several decks can share;
/// the screen says how many decks a change will affect and offers to give
/// this deck settings of its own.
struct DeckOptionsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let deck: Deck

    @State private var options: DeckOptions?
    @State private var settings: DeckSettings?
    @State private var fsrs = false
    @State private var separateName: String?
    @State private var learnText = ""
    @State private var relearnText = ""
    @State private var error: String?
    @State private var saving = false

    private var preset: DeckPreset? {
        options.flatMap { o in o.presets.first { $0.id == o.presetID } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let binding = Binding($settings) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        presetBox
                        form(binding)
                    }
                    .padding(24)
                }
            } else if let error {
                ContentUnavailableView("Couldn't open the options", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 680)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            DeckIcon(deck: deck, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Options").font(.title2.weight(.semibold))
                Text(deck.displayPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: Preset

    @ViewBuilder private var presetBox: some View {
        if let options, let preset {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Settings group").font(.headline)
                    Spacer()
                    Picker("Settings group", selection: Binding(
                        get: { separateName == nil ? options.presetID : -1 },
                        set: { id in if id != options.presetID, id != -1 { Task { await switchPreset(to: id) } } })) {
                        ForEach(options.presets) { p in
                            Text("\(p.name) · \(p.useCount) deck\(p.useCount == 1 ? "" : "s")").tag(p.id)
                        }
                        if let separateName { Text("\(separateName) (new)").tag(Int64(-1)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let separateName {
                    Label("Saving will give this deck its own settings, called “\(separateName)”. Other decks won't change.",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else if preset.useCount > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(preset.useCount) decks share these settings, so changes here apply to all of them.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        Button("Give this deck its own settings") {
                            separateName = "\(deck.shortName) settings"
                        }
                    }
                } else {
                    Text("Only this deck uses these settings.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        }
    }

    // MARK: Form

    private func form(_ s: Binding<DeckSettings>) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            group("Daily limits", "calendar") {
                number("New cards a day", "How many cards you haven't seen before to introduce each day.", s.newPerDay, 0...9999)
                number("Reviews a day", "The most reviews shown in a day. Anything over waits until tomorrow.", s.reviewsPerDay, 0...99999)
            }

            group("New cards", "sparkles") {
                steps("Learning steps", "When you see a new card again while learning it, e.g. “1m 10m” means after 1 minute, then 10 minutes.", $learnText)
                if !fsrs {
                    number("Graduating interval (days)", "Days until you see it again after finishing the steps.", s.graduatingIntervalGood, 1...365)
                    number("Easy interval (days)", "Days until you see it again if you press Easy while learning.", s.graduatingIntervalEasy, 1...365)
                }
                row("Order", "Which new cards come first.") {
                    Picker("Order", selection: s.newRandom) {
                        Text("In the order added").tag(false)
                        Text("Random").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            group("Forgotten cards", "arrow.uturn.backward.circle") {
                steps("Relearning steps", "When you see a card again after pressing Again on a review, e.g. “10m”.", $relearnText)
                number("Leech threshold", "After forgetting a card this many times it's marked as a “leech”, a card worth rewriting.", s.leechThreshold, 1...99)
                row("When a card becomes a leech", "Suspending stops it appearing until you fix it.") {
                    Picker("Leech action", selection: s.leechSuspend) {
                        Text("Suspend it").tag(true)
                        Text("Just tag it").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            group("Scheduler", "brain") {
                toggle("Use FSRS", "A modern scheduler that predicts when you'll forget each card. It usually means fewer reviews for the same memory. This switch applies to all decks.", $fsrs)
                if fsrs {
                    row("Desired retention: \(Int((s.wrappedValue.desiredRetention * 100).rounded()))%",
                        "How likely you want to be to remember a card when it comes up. Higher means more reviews.") {
                        Slider(value: s.desiredRetention, in: 0.7...0.99, step: 0.01)
                            .frame(width: 180)
                    }
                    optimizeRow
                } else {
                    row("Starting ease: \(Int((s.wrappedValue.initialEase * 100).rounded()))%",
                        "How fast intervals grow when you press Good. 250% is the usual.") {
                        Slider(value: s.initialEase, in: 1.31...5.0, step: 0.05)
                            .frame(width: 180)
                    }
                }
                number("Maximum interval (days)", "The longest gap between reviews, however well you know a card.", s.maximumReviewInterval, 1...36500)
            }

            group("Burying", "moon.zzz") {
                Text("Cards made from the same note (like the two sides of a Both Ways card) can give each other away. Burying holds the others back until tomorrow.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                toggle("Bury related new cards", nil, s.buryNew)
                toggle("Bury related review cards", nil, s.buryReviews)
                toggle("Bury related learning cards from earlier days", nil, s.buryInterdayLearning)
            }
        }
    }

    private func group<Content: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Control: View>(_ title: String, _ help: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let help {
                    Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
    }

    private func number(_ title: String, _ help: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        row(title, help) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Stepper("", value: value, in: range).labelsHidden()
            }
        }
    }

    private func toggle(_ title: String, _ help: String?, _ value: Binding<Bool>) -> some View {
        row(title, help) {
            Toggle("", isOn: value).toggleStyle(.switch).labelsHidden()
        }
    }

    private func steps(_ title: String, _ help: String, _ text: Binding<String>) -> some View {
        row(title, help) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField("1m 10m", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                if Steps.parse(text.wrappedValue) == nil {
                    Text("Use numbers with m, h or d").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let error, settings != nil {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await save() }
            } label: {
                if saving { ProgressView().controlSize(.small) } else { Text("Save") }
            }
            .buttonStyle(.borderedProminent)
            .hoverGlow()
            .keyboardShortcut(.defaultAction)
            .disabled(settings == nil || saving || Steps.parse(learnText) == nil || Steps.parse(relearnText) == nil)
        }
        .padding(16)
    }

    // MARK: FSRS optimise

    @State private var optimizing = false
    @State private var optimizeResult: String?

    /// Fits FSRS to how you actually remember, from your past reviews.
    private var optimizeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Fit to my memory",
                "Looks at your past reviews in every deck using these settings and tunes FSRS to how you actually remember. Worth doing about once a month.") {
                Button {
                    Task { await optimize() }
                } label: {
                    if optimizing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…") }
                    } else {
                        Label("Optimise", systemImage: "wand.and.stars")
                    }
                }
                .disabled(optimizing)
            }
            if let optimizeResult {
                Label(optimizeResult, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func optimize() async {
        guard let engine = library.engine else { return }
        optimizing = true
        optimizeResult = nil
        defer { optimizing = false }
        await library.backup(force: false)
        do {
            let result = try await engine.optimizeFSRS(deck: deck.id)
            let reviews = result.reviews.formatted()
            if result.reviews < 400 {
                optimizeResult = result.changed
                    ? "Tuned from \(reviews) reviews. It gets more accurate once you have a few hundred."
                    : "Only \(reviews) reviews so far. Keep studying and try again once you have a few hundred."
            } else {
                optimizeResult = result.changed
                    ? "Tuned to your memory from \(reviews) reviews (all decks using “\(result.presetName)”)."
                    : "Checked \(reviews) reviews: your current settings already fit you best."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Logic

    private func load() async {
        guard let engine = library.engine else { return }
        do {
            let loaded = try await engine.deckOptions(deck.id)
            options = loaded
            settings = loaded.settings
            fsrs = loaded.fsrs
            learnText = Steps.format(loaded.settings.learnSteps)
            relearnText = Steps.format(loaded.settings.relearnSteps)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func switchPreset(to id: Int64) async {
        guard let engine = library.engine, let settings else { return }
        do {
            try await engine.saveDeckOptions(deck: deck.id, preset: id, settings: settings, fsrs: fsrs, switchOnly: true)
            separateName = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let engine = library.engine, let options, var settings,
              let learn = Steps.parse(learnText), let relearn = Steps.parse(relearnText) else { return }
        settings.learnSteps = learn
        settings.relearnSteps = relearn
        saving = true
        defer { saving = false }
        do {
            try await engine.saveDeckOptions(deck: deck.id, preset: options.presetID, settings: settings,
                                             fsrs: fsrs, newPresetName: separateName)
            await library.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Learning steps written like "1m 10m 1h 2d", stored as minutes.
enum Steps {
    static func parse(_ text: String) -> [Double]? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        var minutes: [Double] = []
        for part in parts {
            let lower = part.lowercased()
            let unit = lower.last.flatMap { $0.isLetter ? $0 : nil } ?? "m"
            let number = Double(lower.filter { $0.isNumber || $0 == "." })
            guard let number, number > 0 else { return nil }
            switch unit {
            case "s": minutes.append(number / 60)
            case "m": minutes.append(number)
            case "h": minutes.append(number * 60)
            case "d": minutes.append(number * 1440)
            default: return nil
            }
        }
        return minutes
    }

    static func format(_ minutes: [Double]) -> String {
        minutes.map { m in
            if m < 1 { return "\(Int((m * 60).rounded()))s" }
            if m >= 1440, m.truncatingRemainder(dividingBy: 1440) == 0 { return "\(Int(m / 1440))d" }
            if m >= 60, m.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(m / 60))h" }
            return m == m.rounded() ? "\(Int(m))m" : "\(m)m"
        }
        .joined(separator: " ")
    }
}
