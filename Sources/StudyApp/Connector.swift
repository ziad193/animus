#if os(macOS)
import Foundation
import Network
import StudyCore

// TEST ONLY: lets Claude work with your cards, to try out how Animus's own AI
// features should behave before they're built on a model reached through its
// API. Always on in Animus Dev (the test copy); in the real app it's off until
// switched on in Settings › General. To remove it for the final
// release, delete this file, Sources/AnimusConnector, its target in Package.swift, the copy line in build-dev.sh,
// `.mcp.json`, and the two lines that mention `Connector` elsewhere (StudyApp.swift, StudyView.swift).
//
// How it fits together: Claude starts the little `animus-connector` helper,
// which passes each request to this listener over a local connection. Only
// Animus ever touches the collection, so nothing can write over it from outside.

/// The study screen tells the connector which session is on screen.
@MainActor
enum ConnectorHooks {
    static weak var studySession: StudySession?
}

@MainActor
final class Connector {
    static let shared = Connector()

    private var listener: NWListener?
    private weak var library: Library?
    private let token = UUID().uuidString
    /// The real collection gets a backup before the first card Claude adds.
    private var backedUp = false

    /// Where the helper finds the port and the pass-phrase for this run:
    /// the test folder for Animus Dev, Animus's own folder otherwise.
    private static var infoFile: URL {
        let folder = Library.isTestCollection
            ? URL(fileURLWithPath: ProcessInfo.processInfo.environment["ITERUM_DATA_FOLDER"] ?? "", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StudyApp", isDirectory: true)
        return folder.appendingPathComponent("connector.json")
    }

    /// Starts or stops listening. Animus Dev always listens; the real app only when switched on.
    func update(library: Library, switchedOn: Bool) {
        self.library = library
        if Library.isTestCollection || switchedOn { start() } else { stop() }
    }

    private func stop() {
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        try? FileManager.default.removeItem(at: Self.infoFile)
    }

    private func start() {
        guard listener == nil else { return }
        let infoFile = Self.infoFile
        do {
            let parameters = NWParameters.tcp
            // This Mac only: never reachable from the network.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard case .ready = state, let self, let port = listener.port?.rawValue else { return }
                    let info: [String: Any] = ["port": Int(port), "token": self.token]
                    if let data = try? JSONSerialization.data(withJSONObject: info) {
                        try? data.write(to: infoFile, options: .atomic)
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: infoFile.path)
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("Animus connector couldn't start: \(error.localizedDescription)")
        }
    }

    // MARK: One request

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, soFar: Data())
    }

    private func read(_ connection: NWConnection, soFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var all = soFar
                if let data { all.append(data) }
                if let request = Self.parse(all) {
                    self.handle(request, on: connection)
                } else if done || error != nil || all.count > 4 << 20 {
                    connection.cancel()
                } else {
                    self.read(connection, soFar: all)
                }
            }
        }
    }

    private struct Request {
        let headers: [String: String]
        let body: Data
    }

    /// A whole request, once all of it has arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[split.upperBound...]
        guard body.count >= length else { return nil }
        return Request(headers: headers, body: Data(body.prefix(length)))
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        // Only the helper knows this run's pass-phrase; web pages (which send an Origin) are refused.
        guard request.headers["x-animus-token"] == token, request.headers["origin"] == nil,
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let tool = object["tool"] as? String else {
            return reply(["text": "Not allowed.", "isError": true], status: "403 Forbidden", on: connection)
        }
        let arguments = object["arguments"] as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                let text = try await self.run(tool, arguments)
                self.reply(["text": text, "isError": false], on: connection)
            } catch {
                self.reply(["text": (error as? Problem)?.message ?? error.localizedDescription, "isError": true], on: connection)
            }
        }
    }

    private func reply(_ object: [String: Any], status: String = "200 OK", on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var message = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        message.append(body)
        connection.send(content: message, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: The tools

    private struct Problem: Error { let message: String }

    private func run(_ tool: String, _ arguments: [String: Any]) async throws -> String {
        guard let library, let engine = library.engine else { throw Problem(message: "Animus has no collection open yet.") }
        switch tool {
        case "list_decks":
            let decks = try await engine.decks()
            return Self.json(Self.flatten(decks).map { deck in
                ["id": deck.id, "name": deck.name.replacingOccurrences(of: "::", with: " › "),
                 "new": deck.newCount, "learning": deck.learnCount, "due": deck.reviewCount,
                 "cards": deck.totalCards] as [String: Any]
            })

        case "search_cards":
            let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let limit = min(max(arguments["limit"] as? Int ?? 20, 1), 50)
            let ids = try await engine.search(query)
            let rows = try await engine.browseRows(Array(ids.prefix(limit)))
            return Self.json(["matches": ids.count, "showing": rows.count, "cards": rows.map { row in
                ["card_id": row.id, "deck": Self.path(row.text(.deck)), "front": row.text(.front), "back": row.text(.back),
                 "state": row.state, "due": row.text(.due)] as [String: Any]
            }] as [String: Any])

        case "get_card":
            guard let id = Self.int64(arguments["card_id"]) else { throw Problem(message: "Give a card_id (from search_cards).") }
            let note = try await engine.note(forCard: id)
            let row = try await engine.browseRows([id]).first
            var fields: [String: String] = [:]
            for (name, value) in zip(note.fieldNames, note.fields) { fields[name] = value }
            return Self.json(["card_id": note.cardID, "note_id": note.noteID, "card_type": note.noteTypeName,
                              "deck": Self.path(row?.text(.deck) ?? ""), "state": row?.state ?? "", "due": row?.text(.due) ?? "",
                              "fields": fields, "tags": note.tags,
                              "question": Self.plain(note.question), "answer": Self.plain(note.answer)] as [String: Any])

        case "list_card_types":
            return Self.json(try await engine.noteTypes().map { type in
                ["name": type.name, "cloze": type.isCloze, "fields": type.fields] as [String: Any]
            })

        case "study_summary":
            let stats = try await engine.stats(days: 30)
            let decks = try await engine.decks()
            return Self.json([
                "waiting_today": ["new_available": decks.reduce(0) { $0 + Int($1.newCount) },
                                  "learning": decks.reduce(0) { $0 + Int($1.learnCount) },
                                  "due": decks.reduce(0) { $0 + Int($1.reviewCount) }],
                "studied_today": ["cards": stats.todayReviews, "correct": stats.todayCorrect, "minutes": stats.todaySeconds / 60],
                "remembered_last_month_percent": stats.retentionMonth.map { Int(($0 * 100).rounded()) } as Any,
                "collection": ["new": stats.cardsNew, "learning": stats.cardsLearning, "young": stats.cardsYoung,
                               "mature": stats.cardsMature, "suspended": stats.cardsSuspended],
            ] as [String: Any])

        case "current_card":
            guard let session = ConnectorHooks.studySession, let card = session.card else {
                throw Problem(message: "No card is on screen: Animus isn't on the study screen.")
            }
            let row = try await engine.browseRows([card.id]).first
            return Self.json(["card_id": card.id, "deck": Self.path(row?.text(.deck) ?? ""), "state": card.state,
                              "answer_showing": session.showingAnswer,
                              "question": Self.plain(card.question), "answer": Self.plain(card.answer)] as [String: Any])

        case "add_cards":
            return try await addCards(arguments, library: library, engine: engine)

        default:
            throw Problem(message: "Animus has no tool called \(tool).")
        }
    }

    private func addCards(_ arguments: [String: Any], library: Library, engine: Engine) async throws -> String {
        guard let cards = arguments["cards"] as? [[String: Any]], !cards.isEmpty else {
            throw Problem(message: "Give at least one card in `cards`.")
        }
        guard cards.count <= 50 else { throw Problem(message: "At most 50 cards at a time.") }

        let wanted = (arguments["deck"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let decks = Self.flatten(try await engine.decks())
        let tidy: (String) -> String = { $0.replacingOccurrences(of: " › ", with: "::").lowercased() }
        guard let deck = decks.first(where: { tidy($0.name) == tidy(wanted) })
                ?? decks.first(where: { $0.name.components(separatedBy: "::").last?.lowercased() == wanted.lowercased() }) else {
            throw Problem(message: "There's no deck called “\(wanted)”. Use a name from list_decks.")
        }
        guard !deck.filtered else { throw Problem(message: "“\(wanted)” is a filtered deck; cards can't be added to it.") }

        let types = try await engine.noteTypes()
        let type: NoteType
        if let typeName = arguments["card_type"] as? String, !typeName.isEmpty {
            guard let named = types.first(where: { $0.name.lowercased() == typeName.lowercased() }) else {
                throw Problem(message: "There's no card type called “\(typeName)”. Use a name from list_card_types.")
            }
            type = named
        } else {
            // No type asked for: a plain front-and-back one, whatever this collection calls it.
            guard let basic = types.first(where: { $0.name == "Basic" })
                    ?? types.first(where: { !$0.isCloze && $0.fields == ["Front", "Back"] }) else {
                throw Problem(message: "Say which card_type to use (see list_card_types): this collection has no plain Front/Back type.")
            }
            type = basic
        }

        if !Library.isTestCollection, !backedUp {
            backedUp = await library.backup(force: true)
        }
        var added = 0
        var problems: [String] = []
        for (index, card) in cards.enumerated() {
            let given = card["fields"] as? [String: Any] ?? [:]
            var lowered: [String: String] = [:]
            for (name, value) in given { lowered[name.lowercased()] = value as? String ?? "\(value)" }
            let unknown = lowered.keys.filter { key in !type.fields.contains { $0.lowercased() == key } }
            if !unknown.isEmpty {
                problems.append("Card \(index + 1): “\(type.name)” has no field called \(unknown.sorted().joined(separator: ", ")). Its fields are \(type.fields.joined(separator: ", ")).")
                continue
            }
            let fields = type.fields.map { lowered[$0.lowercased()] ?? "" }
            let tags = (card["tags"] as? [String] ?? []).map { $0.replacingOccurrences(of: " ", with: "_") }
            do {
                added += try await engine.addNote(noteType: type.id, deck: deck.id, fields: fields, tags: tags) > 0 ? 1 : 0
            } catch {
                problems.append("Card \(index + 1): \(error.localizedDescription)")
            }
        }
        await library.refresh()
        var result: [String: Any] = ["added": added, "deck": deck.name.replacingOccurrences(of: "::", with: " › "),
                                     "card_type": type.name]
        if !problems.isEmpty { result["not_added"] = problems }
        return Self.json(result)
    }

    // MARK: Setting it up in Claude

    /// The helper Claude starts: it comes inside the app.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/animus-connector").path
    }

    private static var claudeEntry: (name: String, value: [String: Any]) {
        Library.isTestCollection
            ? ("animus-dev", ["command": helperPath, "args": ["--dev"]])
            : ("animus", ["command": helperPath, "args": [String]()])
    }

    /// What to paste into Claude's settings by hand.
    static var setupText: String {
        json(["mcpServers": [claudeEntry.name: claudeEntry.value]], pretty: true)
    }

    /// Adds Animus to the Claude desktop app's list of connectors. Returns what to tell the student.
    static func addToClaude() -> String {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return "The Claude desktop app doesn't seem to be installed on this Mac."
        }
        let file = folder.appendingPathComponent("claude_desktop_config.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Claude's settings file couldn't be read, so nothing was changed. Use Copy Setup and add it by hand."
            }
            settings = existing
            // Keep a copy of the file as it was.
            try? data.write(to: folder.appendingPathComponent("claude_desktop_config.before-animus.json"), options: .atomic)
        }
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers[claudeEntry.name] = claudeEntry.value
        settings["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: file, options: .atomic)) != nil else {
            return "Couldn't save Claude's settings. Use Copy Setup and add it by hand."
        }
        return "Added. Quit Claude and open it again, and Animus's tools will be there."
    }

    // MARK: Helpers

    private static func flatten(_ decks: [Deck]) -> [Deck] {
        decks.flatMap { [$0] + flatten($0.children) }
    }

    /// A deck's full name, written the way Animus shows it.
    private static func path(_ name: String) -> String { name.replacingOccurrences(of: "::", with: " › ") }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    /// A card as plain words: no tags, styles or scripts.
    private static func plain(_ html: String) -> String {
        var text = html
        for pattern in ["<style[\\s\\S]*?</style>", "<script[\\s\\S]*?</script>"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|/div|/p|/li|hr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func json(_ value: Any, pretty: Bool = false) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
