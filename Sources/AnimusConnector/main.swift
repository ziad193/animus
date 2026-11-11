import Foundation

// TEST ONLY: the helper Claude starts to reach Animus (see
// Sources/StudyApp/Connector.swift). It speaks Claude's connector language
// (the Model Context Protocol) on its input and output, and passes each tool
// call on to the running app: Animus itself, or Animus Dev's test copy when
// started with --dev. It never opens the collection itself.

let dev = CommandLine.arguments.contains("--dev")

let tools: [[String: Any]] = [
    tool("list_decks",
         "Every deck and section in Animus, with how many cards are new, being learned and due today, and its total.",
         [:]),
    tool("search_cards",
         "Find cards. `query` is plain words, or Anki's search language: deck:\"Name\", tag:name, is:due, is:new, is:suspended, added:7 (added in the last 7 days), rated:1:1 (answered Again today), \"an exact phrase\". An empty query matches every card. Returns the front and back of each match as plain text.",
         ["query": ["type": "string", "description": "What to look for."],
          "limit": ["type": "integer", "description": "How many cards to return (1 to 50, default 20)."]],
         required: ["query"]),
    tool("get_card",
         "One card in full: every field as written (HTML), its tags, card type, deck, and the question and answer as the student sees them.",
         ["card_id": ["type": "integer", "description": "A card_id from search_cards or current_card."]],
         required: ["card_id"]),
    tool("list_card_types",
         "The card types (note types) available, with each one's field names. Check this before add_cards.",
         [:]),
    tool("study_summary",
         "Today at a glance: cards waiting, cards studied and how many were right, minutes studied, last month's retention, and the make-up of the collection.",
         [:]),
    tool("current_card",
         "The card on screen in Animus right now while studying: its question, its answer, and whether the answer is showing. Use it to explain or quiz on the card being studied.",
         [:]),
    tool("add_cards",
         "Add new cards to a deck in Animus. Animus makes a backup before the first card is added. Field names must match the card type's fields; for a Cloze type put {{c1::hidden text}} in the Text field. Fields may contain simple HTML. Up to 50 cards a call. The student can undo with Cmd-Z in Animus.",
         ["deck": ["type": "string", "description": "A deck name from list_decks, e.g. \"Year 2 Anatomy › Thorax\" or just \"Thorax\"."],
          "card_type": ["type": "string", "description": "A name from list_card_types. Leave out for a plain front-and-back card."],
          "cards": ["type": "array", "description": "The cards to add.",
                    "items": ["type": "object",
                              "properties": ["fields": ["type": "object", "description": "Field name to its text, e.g. {\"Front\": \"…\", \"Back\": \"…\"}.",
                                                        "additionalProperties": ["type": "string"]],
                                             "tags": ["type": "array", "items": ["type": "string"]]],
                              "required": ["fields"]]]],
         required: ["deck", "cards"]),
]

// Ready-made ways to start a chat, shown in Claude's own menu. "Ask Animus" is
// the tutor the app will have built in later; for now, Claude plays the part.
let prompts: [(name: String, title: String, description: String, argument: (name: String, description: String)?, text: String)] = [
    ("ask_animus", "Ask Animus", "Chat with Ask Animus, your study tutor, about your cards, decks and studying.",
     ("question", "What you'd like to ask (optional)."),
     "Act as Ask Animus, the study tutor that belongs to the Animus flashcard app. I'm a medical student and these are my own cards. Use the Animus tools to look at my decks, cards and study numbers whenever that helps, rather than guessing or asking me to paste things. Keep answers short and in plain English. When you explain a card, say why the answer is right and give one way to remember it. Never change anything without asking: before adding cards, show me exactly what you'd add and wait for my OK."),
    ("explain_current_card", "Explain this card", "Explains the card you're studying in Animus right now.", nil,
     "Look at the card I'm studying in Animus right now (the current_card tool) and explain it: why the answer is right, the idea behind it, and one way to remember it. If the answer isn't showing yet, give me a hint first and let me try before you reveal it."),
    ("quiz_me", "Quiz me", "Quizzes you on a topic from your own cards, one question at a time.",
     ("topic", "A topic, deck or tag to be quizzed on (optional: otherwise today's due cards)."),
     "Quiz me from my own Animus cards. Find suitable cards with search_cards (if I gave no topic, use is:due), then ask me one question at a time in your own words, wait for my answer, and tell me whether I was right and what the card says. After five questions, tell me which ideas I should go over again."),
    ("make_cards", "Make cards from this", "Turns notes or text you give into cards, shown for you to check before they're added.",
     ("deck", "The deck to add them to (optional)."),
     "I'm going to give you some notes or lecture text. Turn them into flashcards for Animus: one fact per card, short questions, and use only facts from what I give you (copy numbers, doses and values exactly). First check list_decks and list_card_types, then show me the cards as a list and wait for my OK before adding them with add_cards."),
]

func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
    ["name": name, "description": description,
     "inputSchema": ["type": "object", "properties": properties, "required": required]]
}

/// Asks the running Animus Dev to do one tool call.
func callAnimus(_ name: String, _ arguments: [String: Any]) -> (text: String, isError: Bool) {
    let notOpen = dev
        ? "Animus Dev isn't open. Open it and try again."
        : "Animus isn't open, or its Claude connector is switched off. Open Animus, switch on Settings › General › Claude connector, and try again."
    let folder = ProcessInfo.processInfo.environment["ANIMUS_DATA_FOLDER"]
        ?? NSHomeDirectory() + "/Library/Application Support/" + (dev ? "Animus Dev" : "StudyApp")
    guard let data = FileManager.default.contents(atPath: folder + "/connector.json"),
          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = info["port"] as? Int, let token = info["token"] as? String,
          let url = URL(string: "http://127.0.0.1:\(port)/call") else { return (notOpen, true) }

    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(token, forHTTPHeaderField: "X-Animus-Token")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["tool": name, "arguments": arguments])

    var result: (String, Bool) = (notOpen, true)
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, _, _ in
        if let data, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = reply["text"] as? String {
            result = (text, reply["isError"] as? Bool ?? false)
        }
        done.signal()
    }.resume()
    done.wait()
    return result
}

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

// One request per line in, one answer per line out.
while let line = readLine(strippingNewline: true) {
    guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let method = message["method"] as? String else { continue }
    // Messages without an id are notices: nothing to answer.
    guard let id = message["id"] else { continue }
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any](), "prompts": [String: Any]()],
            "serverInfo": ["name": dev ? "animus-dev" : "animus", "title": dev ? "Animus Dev (test copy)" : "Animus", "version": "0.1"],
            "instructions": dev
                ? "Animus is a flashcard app. These tools work on Animus Dev's test copy of the student's cards, so nothing here changes their real collection. Animus Dev must be open."
                : "Animus is a flashcard app. These tools work on the student's own cards, in the Animus app, which must be open. Adding cards changes their collection (Animus backs it up first, and they can undo with Cmd-Z), so say what you're about to add before adding it.",
        ] as [String: Any]])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
    case "prompts/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["prompts": prompts.map { prompt -> [String: Any] in
            var entry: [String: Any] = ["name": prompt.name, "title": prompt.title, "description": prompt.description]
            if let argument = prompt.argument {
                entry["arguments"] = [["name": argument.name, "description": argument.description, "required": false]]
            }
            return entry
        }]])
    case "prompts/get":
        guard let prompt = prompts.first(where: { $0.name == params["name"] as? String }) else {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Animus has no prompt with that name."]])
            continue
        }
        var text = prompt.text
        if let argument = prompt.argument, let given = (params["arguments"] as? [String: Any])?[argument.name] as? String,
           !given.trimmingCharacters(in: .whitespaces).isEmpty {
            text += "\n\n\(argument.name.capitalized): \(given)"
        }
        send(["jsonrpc": "2.0", "id": id, "result": [
            "description": prompt.description,
            "messages": [["role": "user", "content": ["type": "text", "text": text]]],
        ] as [String: Any]])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let reply = callAnimus(name, params["arguments"] as? [String: Any] ?? [:])
        send(["jsonrpc": "2.0", "id": id, "result": [
            "content": [["type": "text", "text": reply.text]], "isError": reply.isError,
        ] as [String: Any]])
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Animus doesn't know “\(method)”."]])
    }
}
