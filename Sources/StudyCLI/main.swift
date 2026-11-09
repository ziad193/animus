// Developer tool (not shipped) for testing the engine from the terminal.
//   study-cli <collection.anki2>                  list decks
//   study-cli <collection.anki2> study <deck id>  grade 3 cards "Good", then undo one
import Foundation
import StudyCore

let args = CommandLine.arguments
guard args.count == 2 || (args.count == 4 && args[2] == "study") || (args.count == 3 && ["stats", "add-test"].contains(args[2])) || (args.count == 4 && args[2] == "import") || (args.count >= 3 && args[2] == "browse") || (args.count == 3 && args[2] == "deckmenu") || (args.count == 3 && args[2] == "stocktypes") || (args.count == 3 && args[2] == "filtered") || (args.count == 3 && args[2] == "backuptest") || (args.count == 3 && args[2] == "actions") || (args.count == 3 && args[2] == "bulk") || (args.count == 3 && args[2] == "gaps") || (args.count == 3 && args[2] == "stats2") || (args.count == 3 && args[2] == "types") || (args.count == 3 && args[2] == "fsrsundo") || (args.count == 4 && args[2] == "house") || (args.count == 4 && args[2] == "occlusion") || (args.count == 5 && args[2] == "synctest") || (args.count == 3 && args[1] == "synclogin") || (args.count == 4 && args[2] == "mkdeck") else {
    print("usage: study-cli <collection.anki2> [study <deck id>]")
    exit(2)
}

func show(_ decks: [Deck], indent: String = "") {
    for d in decks {
        let leaf = d.name.split(separator: "::").last.map(String.init) ?? d.name
        print("\(indent)[\(d.id)] \(leaf)  new \(d.newCount) · learn \(d.learnCount) · review \(d.reviewCount)  (\(d.totalCards) cards)")
        show(d.children, indent: indent + "  ")
    }
}

func findDeck(_ id: Int64, in decks: [Deck]) -> Deck? {
    for d in decks {
        if d.id == id { return d }
        if let f = findDeck(id, in: d.children) { return f }
    }
    return nil
}

func plain(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        .prefix(90).description
}

if args[1] == "synclogin" {
    // synclogin <server>: prints the test account's sign-in as JSON (developer testing only)
    let auth = try Engine.syncLogin(username: "test", password: "testpass", endpoint: args[2])
    print(String(decoding: try JSONEncoder().encode(auth), as: UTF8.self))
    exit(0)
}

do {
    let engine = try Engine(collectionPath: URL(fileURLWithPath: args[1]))
    if args.count == 2 {
        show(try await engine.decks())
    } else if args[2] == "gaps" {
        // The Anki gaps: type-in answers, empty cards, tags, saved searches, descriptions, deck options.
        let types = try await engine.noteTypes()
        let deck = try await engine.decks().first!.id
        let typing = types.first { $0.kind == "typing" }!
        let made = try await engine.addNote(noteType: typing.id, deck: deck, fields: ["Capital of France", "Paris"] + Array(repeating: "", count: max(0, typing.fields.count - 2)), tags: ["gaptest::child", "gaptest"])
        print("typing note cards:", made)
        let card = try await engine.search("tag:gaptest \"Capital of France\"").first!
        for guess in ["Paris", "Pari", ""] {
            let r = try await engine.typedAnswer(card: card, typed: guess)
            let start = r.html.range(of: "typeans")
            print("typed \"\(guess)\" ->", start == nil ? "NO COMPARISON" : String(r.html[start!.lowerBound...].prefix(220)))
        }
        try await engine.selectDeck(deck)
        if let next = try await engine.nextCard().card { print("next card typeAnswer:", next.typeAnswer, "autoAdvance:", String(describing: next.autoAdvance)) }
        let empty = try await engine.emptyCards()
        print("empty cards:", empty.cardIDs.count, "report chars:", empty.report.count)
        for id in empty.cardIDs.prefix(3) {
            // An empty card's front is the card plus Anki's "No cloze N found" note, never "not fully rendered".
            let note = try await engine.note(forCard: id)
            print("  empty card front:", plain(note.question).suffix(70), "| back:", plain(note.answer).prefix(40))
        }
        print("rename gaptest -> gapdone:", try await engine.renameTag("gaptest", to: "gapdone"))
        print("tags now:", try await engine.allTags().filter { $0.hasPrefix("gap") })
        print("delete gapdone:", try await engine.deleteTag("gapdone"))
        print("clear unused:", try await engine.clearUnusedTags())
        print("tags after:", try await engine.allTags().filter { $0.hasPrefix("gap") })
        var saved = try await engine.savedSearches()
        print("saved before:", saved)
        saved["Gap test"] = "deck:current is:due"
        try await engine.setSavedSearches(saved)
        print("saved after:", try await engine.savedSearches())
        print("description:", try await engine.deckDescription(deck).prefix(120))
        let options = try await engine.deckOptions(deck)
        var settings = options.settings
        print("easy days before:", settings.easyDays, "auto:", settings.autoQuestionSeconds, settings.autoAnswerSeconds, settings.autoAnswerAction)
        settings.easyDays = [1, 1, 1, 1, 1, 0.5, 0]
        settings.autoQuestionSeconds = 8
        settings.autoAnswerSeconds = 5
        settings.autoAnswerAction = 3
        try await engine.saveDeckOptions(deck: deck, preset: options.presetID, settings: settings, fsrs: options.fsrs)
        let again = try await engine.deckOptions(deck).settings
        print("easy days after:", again.easyDays, "auto:", again.autoQuestionSeconds, again.autoAnswerSeconds, again.autoAnswerAction)
        if let next = try await engine.nextCard().card { print("next card autoAdvance:", String(describing: next.autoAdvance)) }
    } else if args[2] == "mkdeck" {
        // mkdeck "Name": a deck with three basic cards (for trying layouts).
        let deck = try await engine.addDeck(named: args[3])
        let basic = try await engine.noteTypes().first { $0.kind == "basic" }!
        for n in 1...3 {
            try await engine.addNote(noteType: basic.id, deck: deck,
                                     fields: ["\(args[3]) question \(n)", "Answer \(n)"] + Array(repeating: "", count: max(0, basic.fields.count - 2)))
        }
        show(try await engine.decks())
    } else if args[2] == "add-test" {
        let types = try await engine.noteTypes()
        print("card types:", types.map { "\($0.name) [\($0.kind)] \($0.fields)" })
        let deck = try await engine.decks().first!.id
        for t in types where ["basic", "reversed", "typing", "cloze"].contains(t.kind) {
            var fields = Array(repeating: "", count: t.fields.count)
            fields[0] = t.isCloze ? "The {{c1::heart}} pumps {{c2::blood}}" : "Test front for \(t.name)"
            if fields.count > 1, !t.isCloze { fields[1] = "Test back" }
            let cards = try await engine.addNote(noteType: t.id, deck: deck, fields: fields, tags: ["test"])
            print("added \(t.name): \(cards) card(s)")
        }
        do {
            let basic = types.first { $0.kind == "basic" }!
            _ = try await engine.addNote(noteType: basic.id, deck: deck, fields: ["", "x"])
            print("empty front: unexpectedly added")
        } catch { print("empty front rejected: \(error.localizedDescription)") }
        show(try await engine.decks())
    } else if args[2] == "synctest" {
        // synctest <collection B> <server>: two "devices" syncing through a test server
        let server = args[4]
        let auth = try Engine.syncLogin(username: "test", password: "testpass", endpoint: server)
        print("signed in, key \(auth.hkey.prefix(6))…")
        do { _ = try Engine.syncLogin(username: "test", password: "wrong", endpoint: server); print("wrong password: unexpectedly OK") }
        catch { print("wrong password: \(error.localizedDescription)") }
        let a = engine
        var r = try await a.sync(auth)
        print("A first sync: \(r.result) upload_ok \(r.uploadOK) download_ok \(r.downloadOK)")
        if r.result == "full_sync" { try await a.fullSync(auth, upload: true); print("A uploaded") }
        try a.syncMedia(auth); print("A media synced")
        let b = try Engine(collectionPath: URL(fileURLWithPath: args[3]))
        r = try await b.sync(auth)
        print("B first sync: \(r.result) upload_ok \(r.uploadOK) download_ok \(r.downloadOK)")
        if r.result == "full_sync" { try await b.fullSync(auth, upload: false); print("B downloaded") }
        let countA = try await a.search("").count, countB = try await b.search("").count
        print("cards A \(countA) B \(countB)")
        try b.syncMedia(auth); print("B media synced")
        let deck = try await b.decks().first { $0.dueToday > 0 }!
        try await b.selectDeck(deck.id)
        let before = try await b.nextCard().counts
        try await b.answer(.good, milliseconds: 3000)
        print("B studied one card in \(deck.name); counts before \(before) after \(try await b.nextCard().counts)")
        print("B reviews today per stats: \(try await b.stats(days: 1).todayReviews)")
        r = try await b.sync(auth); print("B sync after studying: \(r.result)")
        r = try await a.sync(auth); print("A sync: \(r.result)")
        try await a.selectDeck(deck.id)
        print("A counts now \(try await a.nextCard().counts) (should be one fewer than before)")
        r = try await a.sync(auth); print("A sync again: \(r.result)")
    } else if args[2] == "fsrsundo" {
        // FSRS optimise on the biggest deck, then undo/redo labels around a change.
        let decks = try await engine.decks()
        guard let deck = decks.max(by: { $0.totalCards < $1.totalCards }) else { fatalError("no decks") }
        let started = Date()
        let result = try await engine.optimizeFSRS(deck: deck.id)
        print("optimise \(deck.name): reviews=\(result.reviews) changed=\(result.changed) preset=\(result.presetName) in \(Int(Date().timeIntervalSince(started)))s")
        let again = try await engine.optimizeFSRS(deck: deck.id)
        print("optimise again: changed=\(again.changed)")
        print("status before:", try await engine.undoStatus())
        try await engine.renameDeck(deck.id, to: deck.name + " X")
        let s1 = try await engine.undoStatus()
        print("after rename:", s1)
        try await engine.undo()
        let s2 = try await engine.undoStatus()
        print("after undo:", s2, "name:", (try await engine.decks()).first { $0.id == deck.id }?.name ?? "?")
        try await engine.redo()
        print("after redo:", try await engine.undoStatus(), "name:", (try await engine.decks()).first { $0.id == deck.id }?.name ?? "?")
        try await engine.undo()
    } else if args[2] == "backuptest" {
        let colURL = URL(fileURLWithPath: args[1])
        let folder = colURL.deletingLastPathComponent().appendingPathComponent("backups")
        print("backup made:", try await engine.backup(to: folder, force: true))
        print("again (not forced, nothing changed):", try await engine.backup(to: folder))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        print("files:", files)
        let before = try await engine.search("").count
        let basic = try await engine.noteTypes().first { $0.kind == "basic" }!
        try await engine.addNote(noteType: basic.id, deck: try await engine.decks().first!.id, fields: ["Backup test front", "back"])
        print("cards before \(before), after adding \(try await engine.search("").count)")
        await engine.close()
        let dir = colURL.deletingLastPathComponent()
        try Engine.restoreBackup(folder.appendingPathComponent(files.sorted().last!), collection: colURL,
                                 mediaFolder: dir.appendingPathComponent("collection.media"),
                                 mediaDB: dir.appendingPathComponent("collection.mdb"))
        let reopened = try Engine(collectionPath: colURL)
        print("after restore: \(try await reopened.search("").count) cards; test card present: \(try await reopened.search("\"Backup test front\"").count > 0)")
    } else if args[2] == "occlusion" {
        let deck = try await engine.decks().first!
        let text = "{{c1::image-occlusion:rect:left=.1:top=.2:width=.3:height=.1:oi=1}}<br>{{c2::image-occlusion:ellipse:left=.5:top=.5:width=.2:height=.2:oi=1}}<br>{{c2::image-occlusion:rect:left=.7:top=.1:width=.1:height=.1:oi=1}}"
        let before = try await engine.search("").count
        try await engine.addOcclusion(deck: deck.id, image: URL(fileURLWithPath: args[3]), occlusions: text, header: "Test diagram", backExtra: "extra", tags: ["iotest"])
        let cards = try await engine.search("tag:iotest")
        print("cards before \(before), after \(try await engine.search("").count); new IO cards \(cards.count)")
        let note = try await engine.note(forCard: cards[0])
        print("note type \(note.noteTypeName) fields \(note.fieldNames); image field \(note.fields[1])")
        print("types:", try await engine.noteTypes().filter { $0.kind == "occlusion" }.map(\.name))
    } else if args[2] == "house" {
        print("check db problems:", try await engine.checkDatabase())
        let media = try await engine.checkMedia()
        print("media unused \(media.unused.count) missing \(media.missing.count) notes \(media.missingNotes) trash \(media.trashCount)")
        let lapsed = try await engine.search("prop:lapses>=1").first!
        print("leech state of a lapsed card:", try await engine.leechState(lapsed))
        let csv = URL(fileURLWithPath: args[3])
        let preview = try await engine.csvPreview(csv)
        print("csv preview rows \(preview.preview.count) delim \(preview.delimiter) labels \(preview.columnLabels) notetype \(preview.noteTypeID) map \(preview.fieldColumns)")
        let deck = try await engine.decks().first!
        let basic = try await engine.noteTypes().first { $0.kind == "basic" }!
        let before = try await engine.search("").count
        let r = try await engine.importCSV(csv, deck: deck.id, noteType: basic.id, duplicates: "update")
        print("import: \(r); cards \(before) -> \(try await engine.search("").count)")
        let r2 = try await engine.importCSV(csv, deck: deck.id, noteType: basic.id, duplicates: "skip")
        print("import again (skip):", r2)
        let out = csv.deletingLastPathComponent().appendingPathComponent("all.colpkg")
        try await engine.exportCollection(to: out, includeMedia: false)
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        print("exported colpkg bytes:", size, "still works:", try await engine.search("").count)
    } else if args[2] == "types" {
        let list = try await engine.noteTypeSummaries()
        print("types:", list.map { "\($0.name) (\($0.notes))" }.prefix(6))
        let basic = list.first { $0.name.hasPrefix("Basic") && $0.notes > 0 && !$0.isCloze }!
        var spec = try await engine.noteTypeSpec(basic.id)
        print("spec \(spec.name): fields \(spec.fields.map { "\($0.ord ?? -1):\($0.name)" }) templates \(spec.templates.count) css \(spec.css.count) chars")
        let card = try await engine.search("mid:\(basic.id)").first!
        let before = try await engine.note(forCard: card)
        // rename first field, swap order, add a field, change front layout and css
        let oldName = spec.fields[0].name
        spec.fields[0].name = "Question"
        spec.templates[0].front = spec.templates[0].front.replacingOccurrences(of: "{{\(oldName)}}", with: "{{Question}}")
        spec.templates[0].back = spec.templates[0].back.replacingOccurrences(of: "{{\(oldName)}}", with: "{{Question}}")
        spec.fields.swapAt(0, 1)
        spec.fields.append(.init(name: "Source"))
        spec.css += "\n.card { color: teal; }"
        try await engine.saveNoteType(spec)
        let after = try await engine.note(forCard: card)
        print("fields now \(after.fieldNames); question kept: \(after.fields[1] == before.fields[0]); answer kept: \(after.fields[0] == before.fields[1]); new empty: \(after.fields[2].isEmpty)")
        let respec = try await engine.noteTypeSpec(basic.id)
        print("front layout: \(respec.templates[0].front.prefix(60)) css teal: \(respec.css.contains("teal"))")
        let copy = try await engine.copyNoteType(basic.id, name: "Test copy")
        print("copy:", try await engine.noteTypeSummaries().first { $0.id == copy }.map { "\($0.name) \($0.notes) notes" } ?? "missing")
        try await engine.deleteNoteType(copy)
        print("after delete exists:", try await engine.noteTypeSummaries().contains { $0.id == copy })
        let io = try await engine.search("note:\"Image Occlusion*\"").first
        if let io {
            let n = try await engine.note(forCard: io)
            try await engine.updateOcclusion(note: n.noteID, occlusions: "{{c1::image-occlusion:rect:left=.1:top=.1:width=.2:height=.2:oi=1}}", header: "Edited", backExtra: "", tags: n.tags)
            let n2 = try await engine.note(forCard: io)
            print("IO updated: \(n2.fields[0]) header \(n2.fields[2]) ordinal \(n2.cardOrdinal)")
        }
    } else if args[2] == "stats2" {
        let st = try await engine.stats(days: 365)
        print("intervals buckets:", st.intervals.count, "max ivl:", st.intervals.keys.max() ?? 0)
        print("hours:", st.hours.map(\.total))
        print("buttons L/Y/M:", st.buttonsLearning, st.buttonsYoung, st.buttonsMature)
        print("true retention:", st.trueRetention)
        print("added days:", st.addedPerDay.count, "fsrs:", st.fsrs, "avgR:", st.averageRetrievability as Any)
        let allDecks = try await engine.decks()
        let deck: Deck = allDecks.flatMap { [$0] + $0.children }.first { $0.children.isEmpty && $0.newCount > 0 } ?? allDecks[0]
        let opts = try await engine.deckOptions(deck.id)
        var settings = opts.settings
        settings.newPerDay = 5
        try await engine.saveDeckOptions(deck: deck.id, preset: opts.presetID, settings: settings, fsrs: opts.fsrs, newPresetName: "CLI test cap")
        print("study more info for \(deck.name):", try await engine.studyMoreInfo(deck.id))
        try await engine.selectDeck(deck.id)
        let before = try await engine.nextCard().counts
        try await engine.studyMore(deck.id, newCards: 10)
        try await engine.selectDeck(deck.id)
        print("new before \(before.new) after +10:", try await engine.nextCard().counts.new)
    } else if args[2] == "bulk" {
        let all = try await engine.search("")
        let notes = try await engine.search("", notes: true)
        print("cards \(all.count), notes view rows \(notes.count)")
        let some = Array(try await engine.search("is:new").prefix(3))
        print("tagged notes:", try await engine.addTags("bulktest extra", toCards: some), "search hits:", try await engine.search("tag:bulktest").count)
        print("untag:", try await engine.removeTags("extra", fromCards: some), "extra left:", try await engine.search("tag:extra").count)
        let first = try await engine.note(forCard: some[0])
        let word = String(OcclusionWord.first(first.fields[0]))
        print("find word '\(word)':", try await engine.findAndReplace(cards: [some[0]], find: word, replace: "ZZREPLACED", field: nil, regex: false, matchCase: false),
              "now:", try await engine.search("ZZREPLACED").count)
        try await engine.undo()
        print("after undo:", try await engine.search("ZZREPLACED").count)
        print("reposition:", try await engine.reposition(some, start: 1, shiftOthers: true))
        let dupes = try await engine.findDuplicates(in: "")
        print("duplicate groups: \(dupes.count); biggest: \(dupes.first.map { "\($0.noteIDs.count)x \($0.text.prefix(40)) [\($0.noteType)]" } ?? "-")")
        let types = try await engine.noteTypes()
        let basic = types.first { $0.kind == "basic" }!, reversed = types.first { $0.kind == "reversed" }
        let card = try await engine.search("note:\"\(basic.name)\"").first!
        let before = try await engine.note(forCard: card)
        if let reversed {
            print("change type:", try await engine.changeNoteType(ofCards: [card], to: reversed.id))
            let after = try await engine.note(forCard: card)
            print("type \(before.noteTypeName) -> \(after.noteTypeName); front kept \(before.fields[0] == after.fields[0]); cards in note now", try await engine.search("nid:\(after.noteID)").count)
        }
        print("tags count:", try await engine.allTags().count)
    } else if args[2] == "actions" {
        let deck = try await engine.decks().first { $0.dueToday > 2 }!
        try await engine.selectDeck(deck.id)
        var state = try await engine.nextCard()
        let first = state.card!
        print("deck \(deck.name) counts \(state.counts); card \(first.id) flag \(first.flag) marked \(first.marked)")
        try await engine.setFlag([first.id], 3)
        print("flagged green: flag:3 search hits card =", try await engine.search("flag:3").contains(first.id))
        state = try await engine.nextCard()
        print("same card again \(state.card?.id == first.id) flag now \(state.card?.flag ?? -1)")
        let note = try await engine.note(forCard: first.id)
        try await engine.updateNote(note.noteID, fields: note.fields, tags: note.tags + ["marked"])
        print("marked now", try await engine.nextCard().card?.marked ?? false)
        try await engine.bury([first.id])
        state = try await engine.nextCard()
        print("after bury: next is different \(state.card?.id != first.id), is:buried hits = \(try await engine.search("is:buried").contains(first.id))")
        try await engine.undo()
        print("after undo, buried =", try await engine.search("is:buried").contains(first.id))
        try await engine.setDueDate([first.id], days: "7")
        print("set due 7: prop:due=7 hits", try await engine.search("prop:due=7").contains(first.id))
        try await engine.forget([first.id])
        print("forget: is:new hits", try await engine.search("is:new").contains(first.id))
        let info = try await engine.cardInfo(first.id)
        print("info: deck \(info.deck) type \(info.noteType)/\(info.cardType) reviews \(info.reviews) lapses \(info.lapses) history \(info.history.count) first kinds \(info.history.prefix(3).map(\.kind))")
        let reviewed = try await engine.search("-is:new").first!
        let info2 = try await engine.cardInfo(reviewed)
        print("reviewed card info: reviews \(info2.reviews) interval \(info2.intervalDays) ease \(info2.easePercent) R \(info2.retrievability.map { String($0) } ?? "nil") history \(info2.history.prefix(2).map { "\($0.kind)/\($0.button)/\($0.intervalDays)" })")
        do { try await engine.setDueDate([first.id], days: "abc"); print("bad due: accepted?") } catch { print("bad due message:", error.localizedDescription) }
    } else if args[2] == "filtered" {
        let before = try await engine.search("is:due").count
        let id = try await engine.createFilteredDeck(name: "Test Filtered", search: "is:due", limit: 25, order: "random", reschedule: true)
        let deck = findDeck(id, in: try await engine.decks())!
        print("made \(deck.name) filtered=\(deck.filtered) cards \(deck.totalCards) due \(deck.dueToday); due before \(before)")
        print("in deck:", try await engine.search("deck:\"Test Filtered\"").count)
        try await engine.selectDeck(id)
        let card = try await engine.nextCard()
        print("first card counts \(card.counts)")
        try await engine.answer(.good, milliseconds: 2000)
        print("after one answer, in deck:", try await engine.search("deck:\"Test Filtered\"").count)
        print("rebuilt holds:", try await engine.rebuildFilteredDeck(id))
        try await engine.emptyFilteredDeck(id)
        print("after empty, in deck:", try await engine.search("deck:\"Test Filtered\"").count)
        print("rebuilt holds:", try await engine.rebuildFilteredDeck(id))
        try await engine.deleteDeck(id)
        print("after delete: deck exists \(findDeck(id, in: try await engine.decks()) != nil), due cards \(try await engine.search("is:due").count)")
        do { _ = try await engine.createFilteredDeck(name: "Nothing", search: "tag:doesnotexist123", limit: 10, order: "due", reschedule: true) ; print("empty: unexpectedly made") }
        catch { print("no-match message: \(error.localizedDescription)") }
    } else if args[2] == "stocktypes" {
        print("before:", try await engine.noteTypes().map { "\($0.name) [\($0.kind)]" })
        let id = try await engine.addStockNoteType("typing")
        let added = try await engine.noteTypes().first { $0.id == id }!
        print("added: \(added.name) [\(added.kind)] fields \(added.fields)")
        let deck = try await engine.decks().first!.id
        print("cards from a typing note: \(try await engine.addNote(noteType: id, deck: deck, fields: ["Capital of France?", "Paris"]))")
    } else if args[2] == "deckmenu" {
        let deck = try await engine.decks().first { !$0.children.isEmpty }!
        let leaf = deck.children.first!
        var o = try await engine.deckOptions(leaf.id)
        print("options for \(o.deckName): preset \(o.presetID) of \(o.presets.map { "\($0.name)×\($0.useCount)" }) fsrs \(o.fsrs)")
        print("  settings: new \(o.settings.newPerDay)/day reviews \(o.settings.reviewsPerDay) steps \(o.settings.learnSteps) grad \(o.settings.graduatingIntervalGood) retention \(o.settings.desiredRetention)")
        var changed = o.settings; changed.newPerDay = 7; changed.learnSteps = [2, 15, 60]
        try await engine.saveDeckOptions(deck: leaf.id, preset: o.presetID, settings: changed, fsrs: o.fsrs, newPresetName: "Animus test copy")
        o = try await engine.deckOptions(leaf.id)
        print("after own copy: preset \(o.presetID) name \(o.presets.first { $0.id == o.presetID }!.name) new \(o.settings.newPerDay) steps \(o.settings.learnSteps)")
        let p = try await engine.preferences()
        print("prefs: \(p)")
        var p2 = p; p2.nextDayStartsAt = 5; p2.timeLimitMinutes = 20
        try await engine.setPreferences(p2)
        print("prefs after: \(try await engine.preferences().nextDayStartsAt) \(try await engine.preferences().timeLimitMinutes)")
        try await engine.renameDeck(leaf.id, to: deck.name + "::Renamed Test")
        print("renamed: \(findDeck(leaf.id, in: try await engine.decks()).map { $0.name } ?? "?")")
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iterum-export-test.apkg")
        let notes = try await engine.exportDeck(leaf.id, to: out, withProgress: true, withMedia: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        print("exported \(notes) notes, \(size) bytes")
        print("deleted cards: \(try await engine.deleteDeck(leaf.id))")
        print("deck still there: \(findDeck(leaf.id, in: try await engine.decks()) != nil)")
    } else if args[2] == "browse" {
        // browse [query]: search, show rows, open/edit/suspend/move/delete the first hit
        let query = args.count > 3 ? args[3...].joined(separator: " ") : ""
        let start = Date()
        let ids = try await engine.search(query, sort: .due)
        print("\(ids.count) cards for \"\(query)\" in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        let t2 = Date()
        let rows = try await engine.browseRows(Array(ids.prefix(60)))
        print("60 rows in \(Int(Date().timeIntervalSince(t2) * 1000))ms")
        for r in rows.prefix(5) {
            print("  [\(r.id)] \(r.state) flag \(r.flag) | " + BrowseColumn.allCases.map { "\($0): \(r.text($0).prefix(30))" }.joined(separator: " | "))
        }
        guard let first = rows.first else { exit(0) }
        var note = try await engine.note(forCard: first.id)
        print("note \(note.noteID) type \(note.noteTypeName) fields \(note.fieldNames) tags \(note.tags)")
        print("  Q: \(plain(note.question))")
        note.fields[0] += " EDITED"
        try await engine.updateNote(note.noteID, fields: note.fields, tags: note.tags + ["edited"])
        let again = try await engine.note(forCard: first.id)
        print("after edit: \(again.fields[0].suffix(20)) tags \(again.tags)")
        try await engine.setSuspended([first.id], true)
        print("after suspend: \(try await engine.browseRows([first.id]).first!.state)")
        try await engine.setSuspended([first.id], false)
        print("after unsuspend: \(try await engine.browseRows([first.id]).first!.state)")
        let newDeck = try await engine.addDeck(named: "Animus Test::Moved")
        try await engine.moveCards([first.id], toDeck: newDeck)
        print("after move: \(try await engine.browseRows([first.id]).first!.text(.deck))")
        print("deleted notes: \(try await engine.deleteNotes(ofCards: [first.id]))")
        print("rows after delete: \(try await engine.browseRows([first.id]).count)")
        for bad in ["deck:\"unclosed", "is:new", "added:1", "heart"] {
            do { print("search \(bad): \(try await engine.search(bad).count)") }
            catch { print("search \(bad): \(error.localizedDescription)") }
        }
    } else if args[2] == "import" {
        let r = try await engine.importPackage(URL(fileURLWithPath: args[3]))
        print("imported: new \(r.new), updated \(r.updated), duplicate \(r.duplicate)")
        show(try await engine.decks())
    } else if args[2] == "stats" {
        let s = try await engine.stats()
        let active = s.reviewsPerDay.filter { $0.value > 0 }
        print("days studied in last year: \(active.count), total reviews: \(active.values.reduce(0, +))")
        print("busiest day: \(active.max { $0.value < $1.value }.map { "\($0.key) → \($0.value)" } ?? "-")")
        print("today: \(s.todayReviews) reviews, \(s.todaySeconds)s, correct \(s.todayCorrect)")
        print("cards: new \(s.cardsNew) learning \(s.cardsLearning) young \(s.cardsYoung) mature \(s.cardsMature) suspended \(s.cardsSuspended)")
        print("retention month: \(s.retentionMonth.map { String(format: "%.1f%%", $0 * 100) } ?? "-")  due next 30 days: \(s.dueAhead.values.reduce(0, +))")
    } else {
        try await engine.selectDeck(Int64(args[3])!)
        for _ in 0..<3 {
            let state = try await engine.nextCard()
            print("counts: new \(state.counts.new) learn \(state.counts.learn) review \(state.counts.review)")
            guard let card = state.card else { print("done for today"); break }
            print("  Q: \(plain(card.question))")
            print("  A: \(plain(card.answer))")
            print("  buttons: \(card.intervals)  audio q/a: \(card.questionAudio.count)/\(card.answerAudio.count)")
            try await engine.answer(.good, milliseconds: 4000)
        }
        try await engine.undo()
        let after = try await engine.nextCard()
        print("after undo: new \(after.counts.new) learn \(after.counts.learn) review \(after.counts.review)")
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}


enum OcclusionWord {
    static func first(_ html: String) -> Substring {
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return text.split(whereSeparator: { !$0.isLetter }).first { $0.count > 3 } ?? "the"
    }
}
