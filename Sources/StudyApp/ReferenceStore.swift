import AppKit
import Foundation

/// The slides and notes attached to each deck.
///
/// Files are copied into the app's own folder when attached. That way they
/// still open after the original is moved or renamed, and macOS doesn't
/// block reading them from Documents or Downloads on the next launch.
enum ReferenceStore {
    /// ~/Library/Application Support/StudyApp/References/
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StudyApp/References", isDirectory: true)

    /// File types the panel can show.
    static let extensions = ["pdf", "pptx", "ppt", "key", "docx", "doc", "rtf", "txt"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    private static func key(_ deck: Int64) -> String { "references.\(deck)" }

    /// The deck's attached files, oldest first. Missing files are skipped.
    static func files(for deck: Int64) -> [URL] {
        migrateOldSetting(for: deck)
        let paths = AppDefaults.current.stringArray(forKey: key(deck)) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Copies `url` in (unless the same file is already attached) and returns the copy.
    static func attach(_ url: URL, to deck: Int64) async -> URL {
        let existing = files(for: deck)
        if let same = existing.first(where: { sameFile($0, url) }) { return same }
        let stored = await Task.detached { () -> URL in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let target = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: target)
                return target
            } catch {
                // Couldn't copy (e.g. no permission): fall back to the original.
                try? FileManager.default.removeItem(at: dir)
                return url
            }
        }.value
        var paths = AppDefaults.current.stringArray(forKey: key(deck)) ?? []
        paths.append(stored.path)
        AppDefaults.current.set(paths, forKey: key(deck))
        return stored
    }

    /// Files attached before copies were made are copied in now, if they can
    /// still be read, so they keep working after the original moves.
    static func adoptOutsideFiles(for deck: Int64) async -> Bool {
        let paths = AppDefaults.current.stringArray(forKey: key(deck)) ?? []
        let outside = paths.filter { !$0.hasPrefix(folder.path) && FileManager.default.isReadableFile(atPath: $0) }
        guard !outside.isEmpty else { return false }
        var updated = paths
        for path in outside {
            let copy = await Task.detached { () -> String? in
                let source = URL(fileURLWithPath: path)
                let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let target = dir.appendingPathComponent(source.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: target)
                    return target.path
                } catch {
                    try? FileManager.default.removeItem(at: dir)
                    return nil
                }
            }.value
            if let copy, let index = updated.firstIndex(of: path) {
                updated[index] = copy
                if lastShown(for: deck) == path { setLastShown(URL(fileURLWithPath: copy), for: deck) }
            }
        }
        AppDefaults.current.set(updated, forKey: key(deck))
        return updated != paths
    }

    /// Takes the file off this deck, and deletes our copy if no deck uses it.
    static func detach(_ url: URL, from deck: Int64) {
        var paths = AppDefaults.current.stringArray(forKey: key(deck)) ?? []
        paths.removeAll { $0 == url.path }
        AppDefaults.current.set(paths, forKey: key(deck))
        guard url.path.hasPrefix(folder.path) else { return }
        let stillUsed = AppDefaults.current.dictionaryRepresentation().contains { name, value in
            name.hasPrefix("references.") && (value as? [String])?.contains(url.path) == true
        }
        if !stillUsed { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    /// The file last shown for this deck.
    static func lastShown(for deck: Int64) -> String? {
        AppDefaults.current.string(forKey: "referenceShown.\(deck)")
    }

    static func setLastShown(_ url: URL, for deck: Int64) {
        AppDefaults.current.set(url.path, forKey: "referenceShown.\(deck)")
    }

    /// The page you were on in a PDF, so it reopens there.
    static func page(for url: URL) -> Int {
        AppDefaults.current.integer(forKey: "referencePage.\(url.path)")
    }

    static func setPage(_ page: Int, for url: URL) {
        AppDefaults.current.set(page, forKey: "referencePage.\(url.path)")
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard a.lastPathComponent == b.lastPathComponent else { return false }
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        return size(a) == size(b)
    }

    /// Earlier versions kept one path per deck under "reference.<id>".
    private static func migrateOldSetting(for deck: Int64) {
        let old = "reference.\(deck)"
        guard let path = AppDefaults.current.string(forKey: old) else { return }
        AppDefaults.current.removeObject(forKey: old)
        var paths = AppDefaults.current.stringArray(forKey: key(deck)) ?? []
        if !paths.contains(path) { paths.append(path) }
        AppDefaults.current.set(paths, forKey: key(deck))
    }
}

// MARK: - Text from Office files

/// Pulls readable text out of Word and PowerPoint files, for the Text view
/// (search, select and copy into cards).
enum OfficeText {
    static func canExtract(_ url: URL) -> Bool {
        ["pptx", "docx", "doc", "rtf", "txt"].contains(url.pathExtension.lowercased())
    }

    /// Formatted text for the document. Slow for big files; call off the main thread.
    static func extract(_ url: URL) -> NSAttributedString? {
        switch url.pathExtension.lowercased() {
        case "pptx": return slidesText(url)
        case "docx": return read(url, as: .officeOpenXML)
        case "doc": return read(url, as: .docFormat)
        case "rtf": return read(url, as: .rtf)
        case "txt": return read(url, as: .plain)
        default: return nil
        }
    }

    private static func read(_ url: URL, as type: NSAttributedString.DocumentType) -> NSAttributedString? {
        try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    }

    /// Each slide's text, plus its speaker notes, under a "Slide N" heading.
    private static func slidesText(_ url: URL) -> NSAttributedString? {
        // Unpack just the slides and notes once, into a temporary folder.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("iterum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard unzip(["-q", "-o", url.path, "ppt/slides/*", "ppt/notesSlides/*", "-d", temp.path]) else { return nil }
        let slidesDir = temp.appendingPathComponent("ppt/slides")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: slidesDir.path)) ?? [])
            .filter { $0.hasPrefix("slide") && $0.hasSuffix(".xml") }
            .sorted { number(in: $0) < number(in: $1) }
        guard !names.isEmpty else { return nil }

        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .bold), .foregroundColor: NSColor.black,
        ]
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black,
        ]
        let notesStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray,
        ]
        let out = NSMutableAttributedString()
        for (index, name) in names.enumerated() {
            out.append(NSAttributedString(string: (index == 0 ? "" : "\n") + "Slide \(index + 1)\n", attributes: heading))
            let text = (try? Data(contentsOf: slidesDir.appendingPathComponent(name))).map(paragraphs) ?? []
            out.append(NSAttributedString(string: (text.isEmpty ? "(no text on this slide)" : text.joined(separator: "\n")) + "\n", attributes: body))
            if let notes = notesFile(for: name, in: temp),
               let lines = (try? Data(contentsOf: notes)).map(paragraphs),
               // The notes page repeats the slide number as its own paragraph.
               case let real = lines.filter({ Int($0) == nil }), !real.isEmpty {
                out.append(NSAttributedString(string: "Notes: " + real.joined(separator: "\n") + "\n", attributes: notesStyle))
            }
        }
        return out
    }

    /// The speaker-notes file linked from a slide, if it has one.
    private static func notesFile(for slide: String, in root: URL) -> URL? {
        let rels = root.appendingPathComponent("ppt/slides/_rels/\(slide).rels")
        guard let xml = try? String(contentsOf: rels, encoding: .utf8),
              let range = xml.range(of: #"notesSlides/notesSlide\d+\.xml"#, options: .regularExpression) else { return nil }
        return root.appendingPathComponent("ppt/" + xml[range])
    }

    private static func number(in path: String) -> Int {
        Int(path.filter(\.isNumber)) ?? 0
    }

    /// Paragraphs of text in a slide's XML (`<a:p>` holding `<a:t>` runs).
    private static func paragraphs(_ data: Data) -> [String] {
        final class Collector: NSObject, XMLParserDelegate {
            var paragraphs: [String] = []
            var current = ""
            var inText = false
            func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                if name == "a:t" { inText = true }
                if name == "a:br" { current += "\n" }
            }
            func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if name == "a:t" { inText = false }
                if name == "a:p" {
                    let line = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { paragraphs.append(line) }
                    current = ""
                }
            }
            func parser(_ p: XMLParser, foundCharacters string: String) {
                if inText { current += string }
            }
        }
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.paragraphs
    }

    /// Runs the system `unzip` tool; true if it worked.
    private static func unzip(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        // 11 = "no files matched", e.g. a deck without speaker notes; that's fine.
        return process.terminationStatus == 0 || process.terminationStatus == 11
    }
}
