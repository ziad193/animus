import AppKit
import Foundation
import PDFKit
import Vision

// The one place Animus+ talks to an AI. Every Plus workflow (lecture → cards,
// fill-in-the-blank from notes, Ask Animus, automatic picture labels) calls
// `PlusAI.current`, so plugging in real models later means writing one new
// type that follows `PlusAIProvider`. Nothing in the screens changes.
//
// Until then `StandInAI` does the job with what the Mac can do on its own:
// it reads the lecture's real text, blanks real key terms, finds labels with
// the Mac's built-in text recognition, and gives clearly-marked placeholder
// answers. It never goes online.

// MARK: - What the workflows pass in and get back

/// A card the AI suggests, for you to check, edit, keep or drop.
struct DraftCard: Identifiable, Equatable {
    let id = UUID()
    /// Front, or the cloze text ("The {{c1::mitral}} valve…") for fill-in-the-blank.
    var front: String
    /// Back, or the extra info under a fill-in-the-blank card.
    var back: String
    /// The slide (page, from 0) it came from, so it can be shown beside it.
    var source: Int?
    var keep = true
    /// A note shown on the card, e.g. "You may already have this".
    var note: String?
}

/// A lecture's text, slide by slide.
struct LectureText {
    let url: URL
    /// One entry per slide or page, in order.
    let pages: [String]

    var title: String { url.deletingPathExtension().lastPathComponent }

    /// Reads a PDF's text. (PowerPoint and Keynote: export as PDF first.)
    static func load(_ url: URL) -> LectureText? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        return LectureText(url: url, pages: pages)
    }
}

/// What Ask Animus is asked about.
struct AskContext: Equatable {
    var question: String
    var answer: String
    var deck: String?
}

struct AskMessage: Identifiable, Equatable {
    enum Role { case you, animus }
    let id = UUID()
    let role: Role
    var text: String
}

/// A card's text, for the AI to read.
struct CardText: Equatable {
    var front: String
    var back: String
}

/// One exam-style question: pick the single best answer.
struct PracticeQuestion: Identifiable, Equatable {
    let id = UUID()
    var stem: String
    var options: [String]
    var correct: Int
    var explanation: String
}

/// Written pieces of advice the AI produces from your numbers.
enum AdviceRequest {
    /// Facts about an exam (days left, cards to go, weakest sections).
    case examPlan(facts: String)
    /// Facts about the past week of studying.
    case weeklyReport(facts: String)
}

/// A label found on a diagram: where it is (fractions of the picture, top-left
/// origin) and what it says.
struct FoundLabel: Equatable {
    var frame: CGRect
    var text: String
}

// MARK: - The connection point

protocol PlusAIProvider: Sendable {
    /// Shown in Animus Dev, e.g. "Stand-in (no AI connected)".
    var name: String { get }
    /// True for the stand-in, so screens can say the results are placeholders.
    var isStandIn: Bool { get }

    /// Suggested cards from a lecture, as they're made.
    func cards(from lecture: LectureText) -> AsyncThrowingStream<DraftCard, Error>
    /// Suggested cards from a picture: a whole slide, or the part you captured.
    func cards(fromPicture image: CGImage) -> AsyncThrowingStream<DraftCard, Error>
    /// Fill-in-the-blank cards from pasted notes, as they're made.
    func clozeCards(from notes: String) -> AsyncThrowingStream<DraftCard, Error>
    /// A reply to a question about a card, word by word.
    func answer(_ question: String, about context: AskContext, history: [AskMessage]) -> AsyncThrowingStream<String, Error>
    /// The text labels on a diagram.
    func labels(in image: CGImage) async throws -> [FoundLabel]
    /// A messy card, rewritten or split into several (Fix my card).
    func improve(_ card: CardText) -> AsyncThrowingStream<DraftCard, Error>
    /// Why you might have got a card wrong, and a way to remember it.
    func explainMistake(_ context: AskContext) -> AsyncThrowingStream<String, Error>
    /// Exam-style questions from your cards.
    func practiceQuestions(from cards: [CardText]) -> AsyncThrowingStream<PracticeQuestion, Error>
    /// Plan or report text, written from your numbers.
    func advice(_ request: AdviceRequest) -> AsyncThrowingStream<String, Error>
}

enum PlusAI {
    /// Swap this for the real provider once the models are chosen.
    static var current: PlusAIProvider { StandInAI() }
}

// MARK: - The stand-in

struct StandInAI: PlusAIProvider {
    let name = "Stand-in (no AI connected)"
    let isStandIn = true

    /// A small pause between results, so the screens behave as they will with
    /// a real AI that streams.
    private static let pace: Duration = .milliseconds(120)

    func cards(from lecture: LectureText) -> AsyncThrowingStream<DraftCard, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for (index, page) in lecture.pages.enumerated() {
                    for card in Self.cards(fromPage: page).prefix(4) {
                        try await Task.sleep(for: Self.pace)
                        continuation.yield(DraftCard(front: card.0, back: card.1, source: index))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads the picture's text (on-device), then makes cards from it as from
    /// a slide. If nothing looks like a fact, one card asks about the picture.
    func cards(fromPicture image: CGImage) -> AsyncThrowingStream<DraftCard, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let found = try await labels(in: image)
                    // Rebuild lines: Vision gives text pieces top to bottom.
                    let text = found.sorted { $0.frame.minY < $1.frame.minY }.map(\.text).joined(separator: "\n")
                    var made = Self.cards(fromPage: text)
                    if made.isEmpty, !text.isEmpty {
                        made = [("What does this slide show?", text)]
                    }
                    for card in made.prefix(8) {
                        try await Task.sleep(for: Self.pace)
                        continuation.yield(DraftCard(front: card.0, back: card.1, source: nil))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func clozeCards(from notes: String) -> AsyncThrowingStream<DraftCard, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for line in Self.lines(notes) {
                    guard let cloze = Self.cloze(line) else { continue }
                    try await Task.sleep(for: Self.pace)
                    continuation.yield(DraftCard(front: cloze, back: "", source: nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func answer(_ question: String, about context: AskContext, history: [AskMessage]) -> AsyncThrowingStream<String, Error> {
        let reply = """
        This is a stand-in reply: no AI is connected yet, so I can't really answer "\(question)". \
        Once Animus+ is switched on, the answer will appear here, word by word. \
        For now, here's the card you're on. Question: \(context.question.isEmpty ? "(none)" : context.question) \
        Answer: \(context.answer.isEmpty ? "(none)" : context.answer)
        """
        return AsyncThrowingStream { continuation in
            let task = Task {
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    try await Task.sleep(for: .milliseconds(25))
                    continuation.yield(String(word) + " ")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Real, on-device: the Mac's own text recognition finds the labels.
    func labels(in image: CGImage) async throws -> [FoundLabel] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { observation -> FoundLabel? in
                guard let text = observation.topCandidates(1).first?.string,
                      text.trimmingCharacters(in: .whitespaces).count >= 2 else { return nil }
                // Vision measures from the bottom left; the editor from the top left.
                let box = observation.boundingBox
                let pad = 0.006
                let frame = CGRect(x: box.minX - pad, y: 1 - box.maxY - pad,
                                   width: box.width + pad * 2, height: box.height + pad * 2)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                return FoundLabel(frame: frame, text: text)
            }
        }.value
    }

    // MARK: The newer requests

    /// Splits a list answer into one card per item; otherwise tidies the card.
    func improve(_ card: CardText) -> AsyncThrowingStream<DraftCard, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let items = Self.listItems(card.back)
                var front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
                if !front.hasSuffix("?"), front.lowercased().hasPrefix("what") || front.lowercased().hasPrefix("which") {
                    front += "?"
                }
                if items.count >= 3 {
                    // One fill-in-the-blank card per item, so each is learnt on its own.
                    var base = front.replacingOccurrences(of: "?", with: "")
                    for prefix in ["What is ", "What are ", "Name the ", "List the "] where base.hasPrefix(prefix) {
                        base = String(base.dropFirst(prefix.count))
                    }
                    for item in items {
                        try await Task.sleep(for: Self.pace)
                        let others = items.filter { $0 != item }.joined(separator: ", ")
                        continuation.yield(DraftCard(front: "\(base): {{c1::\(item)}} (also: \(others))", back: "", source: nil))
                    }
                } else {
                    let firstSentence = card.back.split(separator: ".").first.map(String.init) ?? card.back
                    try await Task.sleep(for: Self.pace)
                    continuation.yield(DraftCard(front: front, back: firstSentence.trimmingCharacters(in: .whitespaces), source: nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func explainMistake(_ context: AskContext) -> AsyncThrowingStream<String, Error> {
        let answer = context.answer.isEmpty ? "(see the card)" : context.answer
        return words("Stand-in note (no AI connected yet): a real explanation of why this one is easy to mix up will appear here. "
            + "The answer was: \(answer). Try saying it out loud once and linking it to the key word in the question.")
    }

    /// Single-best-answer questions: each card's answer is the right option,
    /// and other cards' answers from the same deck are the wrong ones.
    func practiceQuestions(from cards: [CardText]) -> AsyncThrowingStream<PracticeQuestion, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let usable = cards.filter { !$0.front.isEmpty && (2...140).contains($0.back.count) }
                let answers = Array(Set(usable.map(\.back)))
                for card in usable.shuffled().prefix(10) {
                    let wrong = answers.filter { $0 != card.back }.shuffled().prefix(4)
                    guard wrong.count >= 2 else { continue }
                    var options = Array(wrong) + [card.back]
                    options.shuffle()
                    try await Task.sleep(for: Self.pace)
                    continuation.yield(PracticeQuestion(stem: card.front, options: options,
                                                        correct: options.firstIndex(of: card.back) ?? 0,
                                                        explanation: "From your card: \(card.front) → \(card.back)"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func advice(_ request: AdviceRequest) -> AsyncThrowingStream<String, Error> {
        switch request {
        case .examPlan(let facts):
            return words("Stand-in plan (no AI connected yet). Here are your numbers, which a real plan would be written from: \(facts)")
        case .weeklyReport(let facts):
            return words("Stand-in report (no AI connected yet). Your week in numbers: \(facts)")
        }
    }

    /// Streams text a word at a time, as a real AI reply would arrive.
    private func words(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for word in text.split(separator: " ") {
                    try await Task.sleep(for: .milliseconds(20))
                    continuation.yield(String(word) + " ")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// "a, b and c" / "a; b; c" / one per line → ["a", "b", "c"].
    static func listItems(_ text: String) -> [String] {
        let separators = text.contains("\n") ? ["\n"] : text.contains(";") ? [";"] : [",", " and "]
        var items = [text]
        for separator in separators {
            items = items.flatMap { $0.components(separatedBy: separator) }
        }
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }
    }

    // MARK: How the stand-in makes cards

    /// The lines of a slide or of notes, tidied: bullets and numbering removed.
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { line in
                var line = line.trimmingCharacters(in: .whitespaces)
                while let first = line.first, "•-–—*·▪◦‣>".contains(first) {
                    line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                if let match = line.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                    line.removeSubrange(match)
                }
                return line
            }
            .filter { $0.count >= 8 }
    }

    /// "Term: explanation" → What is Term? / explanation.
    /// "X is/are Y" → What is X? / Y. Otherwise none.
    static func cards(fromPage page: String) -> [(String, String)] {
        var cards: [(String, String)] = []
        for line in lines(page) {
            if let colon = line.firstIndex(of: ":") {
                let term = line[..<colon].trimmingCharacters(in: .whitespaces)
                let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if (2...60).contains(term.count), rest.count >= 3 {
                    cards.append(("\(Self.isPlural(term) ? "What are" : "What is") \(term)?", rest))
                    continue
                }
            }
            for verb in [" is ", " are ", " causes ", " leads to "] {
                if let range = line.range(of: verb) {
                    let subject = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if (2...60).contains(subject.count), rest.count >= 3 {
                        let ask = verb == " are " ? "What are" : verb == " is " ? "What is"
                            : "What does \(subject)\(verb.trimmingCharacters(in: .whitespaces) == "causes" ? " cause" : " lead to")"
                        cards.append(ask.hasPrefix("What does") ? ("\(ask)?", rest) : ("\(ask) \(subject)?", rest))
                        break
                    }
                }
            }
        }
        return cards
    }

    /// "Inferior leads" → plural; "Aortic stenosis", "Mitral valve" → not.
    static func isPlural(_ term: String) -> Bool {
        guard let last = term.split(separator: " ").last?.lowercased(), last.count > 3 else { return false }
        return last.hasSuffix("s") && !["ss", "is", "us", "sis", "xis"].contains(where: { last.hasSuffix($0) })
    }

    /// Blanks the key term of a line: **bold** words, a term before a colon,
    /// a number with a unit, or else the longest word.
    static func cloze(_ line: String) -> String? {
        if let range = line.range(of: #"\*\*(.+?)\*\*"#, options: .regularExpression) {
            let term = line[range].dropFirst(2).dropLast(2)
            return line.replacingCharacters(in: range, with: "{{c1::\(term)}}")
        }
        if let colon = line.firstIndex(of: ":") {
            let term = line[..<colon].trimmingCharacters(in: .whitespaces)
            if (2...60).contains(term.count) {
                return "{{c1::\(term)}}" + line[colon...]
            }
        }
        if let range = line.range(of: #"\b\d+(\.\d+)?\s?(%|mg|g|kg|ml|mL|L|mmHg|mmol|bpm|cm|mm|days?|hours?|years?)\b"#,
                                  options: .regularExpression) {
            return line.replacingCharacters(in: range, with: "{{c1::\(line[range])}}")
        }
        let words = line.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard let longest = words.max(by: { $0.count < $1.count }), longest.count >= 6,
              let range = line.range(of: longest) else { return nil }
        return line.replacingCharacters(in: range, with: "{{c1::\(longest)}}")
    }
}

// MARK: - Small helpers the workflows share

extension String {
    /// Card HTML → plain text, for showing a card's text to the AI or in a chat.
    var plainText: String {
        var text = replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text → safe card HTML (line breaks kept).
    var cardHTML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
