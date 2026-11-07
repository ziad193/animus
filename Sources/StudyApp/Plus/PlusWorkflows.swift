import AppKit
import PDFKit
import StudyCore
import SwiftUI
import UniformTypeIdentifiers

// The Animus+ workflows' first steps. Each hands over to `DraftReviewView`
// (lecture, notes, slide capture) or runs on its own (Ask Animus). All of them
// go through `PlusAI.current`, so they work with the stand-in today and the
// real models later, unchanged.

// MARK: - 1. Make cards from a lecture

struct LectureCardsSheet: View {
    var deckID: Int64?
    @Environment(\.dismiss) private var dismiss
    @State private var lecture: LectureText?
    @State private var document: PDFDocument?
    @State private var targeted = false
    @State private var problem: String?

    var body: some View {
        if let lecture, let document {
            DraftReviewView(title: "Cards from “\(lecture.title)”", feature: .lectureToCards,
                            source: .lecture(document), cloze: false, checkDeck: true,
                            make: { PlusAI.current.cards(from: lecture) },
                            deckID: deckID) { dismiss() }
        } else {
            chooser
        }
    }

    private var chooser: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Text(PlusFeature.lectureToCards.title).font(.title2.weight(.semibold))
                PlusBadge()
            }
            Text(PlusFeature.lectureToCards.detail)
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            VStack(spacing: 12) {
                Image(systemName: "doc.richtext").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Drop your lecture PDF here").font(.headline)
                Button { choose() } label: { Label("Choose PDF…", systemImage: "folder") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Text("PowerPoint or Keynote? Use File › Export as PDF first.")
                    .font(.caption).foregroundStyle(.secondary)
                // Test copies only: a sample lecture, for trying the workflow.
                if let sample = Self.sampleLecture {
                    Button("Use the sample lecture (test copy)") { open(sample) }
                        .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return open(url)
            } isTargeted: { targeted = $0 }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    /// <test folder>/TestFiles/lecture.pdf, on a test copy only.
    static var sampleLecture: URL? {
        guard Library.isTestCollection, let folder = ProcessInfo.processInfo.environment["ITERUM_DATA_FOLDER"] else { return nil }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("TestFiles/lecture.pdf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose a lecture PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = open(url)
    }

    @discardableResult private func open(_ url: URL) -> Bool {
        guard let text = LectureText.load(url), let pdf = PDFDocument(url: url) else {
            problem = "That doesn't look like a PDF Animus can read."
            return false
        }
        guard text.pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            problem = "This PDF has no text in it (it may be scanned). Use “Cards from this slide” in Slides & Notes instead."
            return false
        }
        document = pdf
        lecture = text
        return true
    }
}

// MARK: - 2. Fill-in-the-blank from your notes

struct ClozeNotesSheet: View {
    var deckID: Int64?
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var making = false

    var body: some View {
        if making {
            let text = notes
            DraftReviewView(title: "Fill-in-the-blank from your notes", feature: .clozeFromNotes,
                            source: .notes, cloze: true,
                            make: { PlusAI.current.clozeCards(from: text) },
                            deckID: deckID) { dismiss() }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(PlusFeature.clozeFromNotes.title).font(.title2.weight(.semibold))
                    PlusBadge()
                }
                Text("Paste your notes. Each line becomes a card with its key term blanked out; you check them before anything is added.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    .overlay(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("e.g.  Mitral regurgitation: pansystolic murmur heard at the apex")
                                .foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 260)
                HStack {
                    Text("Tip: put **two stars** around a word to choose what's blanked.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Make Cards") { making = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 640)
        }
    }
}

// MARK: - 3. Ask Animus

struct AskAnimusSheet: View {
    let context: AskContext
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [AskMessage] = []
    @State private var draft = ""
    @State private var replying: Task<Void, Never>?

    private let suggestions = ["Explain this simply", "Why is this the answer?", "Give me a way to remember it"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: PlusFeature.askAnimus.symbol).foregroundStyle(Color.accentColor)
                Text("Ask Animus").font(.title3.weight(.semibold))
                PlusBadge()
                Spacer()
                Button("Done") { replying?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // What it's about.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("About this card").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(context.question).font(.callout.weight(.medium))
                            if !context.answer.isEmpty {
                                Text(context.answer).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))

                        if messages.isEmpty {
                            Text("Try one of these, or type your own question:")
                                .font(.callout).foregroundStyle(.secondary)
                            FlowRow(spacing: 8) {
                                ForEach(suggestions, id: \.self) { suggestion in
                                    Button(suggestion) { send(suggestion) }
                                }
                            }
                        }
                        ForEach(messages) { message in
                            Bubble(message: message).id(message.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.last?.text) {
                    if let last = messages.last { scroller.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if PlusAI.current.isStandIn {
                Text("Stand-in replies: no AI is connected yet.")
                    .font(.caption2).foregroundStyle(.orange).padding(.bottom, 4)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask about this card…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { send(draft) }
                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || replying != nil)
                .tip("Send (Return)")
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
        .onDisappear { replying?.cancel() }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, replying == nil else { return }
        draft = ""
        let history = messages
        messages.append(AskMessage(role: .you, text: question))
        let reply = AskMessage(role: .animus, text: "")
        messages.append(reply)
        replying = Task {
            do {
                for try await piece in PlusAI.current.answer(question, about: context, history: history) {
                    if let index = messages.firstIndex(where: { $0.id == reply.id }) { messages[index].text += piece }
                }
            } catch {
                if let index = messages.firstIndex(where: { $0.id == reply.id }) {
                    messages[index].text += "\n(Couldn't finish: \(error.localizedDescription))"
                }
            }
            replying = nil
        }
    }

    private struct Bubble: View {
        let message: AskMessage
        var body: some View {
            HStack {
                if message.role == .you { Spacer(minLength: 60) }
                Text(message.text.isEmpty ? "…" : message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(message.role == .you ? Color.accentColor : Color.primary.opacity(0.07)))
                    .foregroundStyle(message.role == .you ? Color.white : Color.primary)
                if message.role == .animus { Spacer(minLength: 60) }
            }
        }
    }
}

extension AskContext {
    /// What Ask Animus needs from the card you're studying.
    init(card: StudyCard, deck: String?) {
        let question = card.question.plainText
        var answer = card.answer.plainText
        // Answers usually repeat the question above a line; keep only what's new.
        if answer.hasPrefix(question) { answer = String(answer.dropFirst(question.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        self.init(question: question, answer: answer, deck: deck)
    }
}

// MARK: - 5. Cards from a slide (Slides & Notes)

struct SlideCaptureSheet: View {
    let picture: NSImage
    var deckID: Int64?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DraftReviewView(title: "Cards from your slide", feature: .lectureToCards,
                        source: .picture(picture), cloze: false, checkDeck: true,
                        make: {
                            guard let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                                return AsyncThrowingStream { $0.finish() }
                            }
                            return PlusAI.current.cards(fromPicture: cg)
                        },
                        deckID: deckID) { dismiss() }
    }
}
