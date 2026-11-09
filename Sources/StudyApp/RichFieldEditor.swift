import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Lets the formatting buttons reach the editor they sit above.
@MainActor
final class RichEditorHandle {
    weak var webView: WKWebView?

    /// Runs a formatting command such as "bold", "insertUnorderedList" or ("foreColor", "#d33").
    func format(_ command: String, _ value: String? = nil) {
        let arg = value.map { ", " + Self.js($0) } ?? ""
        webView?.evaluateJavaScript("format(\(Self.js(command))\(arg)); true", completionHandler: nil)
    }

    /// Inserts HTML where the cursor is (e.g. a picture or a sound).
    func insertHTML(_ html: String) {
        webView?.evaluateJavaScript("insertAtCursor(\(Self.js(html))); true", completionHandler: nil)
    }

    /// Wraps the selected words in a {{cN::…}} blank (or starts an empty one).
    func cloze(_ number: Int) {
        webView?.evaluateJavaScript("cloze(\(number)); true", completionHandler: nil)
    }

    func focus() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("focusEnd(); true", completionHandler: nil)
    }

    /// A string as a JavaScript literal.
    static func js(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}

/// Puts pictures and sounds into the collection's media folder, the way Anki does.
enum MediaFiles {
    /// Saves pasted data, named by its contents so the same picture is only stored once.
    static func add(_ data: Data, ext: String) throws -> String {
        let hash = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "paste-\(hash).\(ext.lowercased())"
        let url = Library.mediaFolder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
        return name
    }

    /// Copies a file in, keeping its name (adding a short code if a different file has it).
    static func add(fileAt source: URL) throws -> String {
        let data = try Data(contentsOf: source)
        let folder = Library.mediaFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = source.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        var url = folder.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: url) {
            if existing == data { return name }
            let hash = Insecure.SHA1.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
            name = source.deletingPathExtension().lastPathComponent + "-\(hash)." + source.pathExtension
            url = folder.appendingPathComponent(name)
        }
        try data.write(to: url)
        return name
    }

    /// The HTML that shows a file on a card: a picture, or a sound/video to play.
    static func html(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
        let escaped = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        return isImage ? "<img src=\"\(escaped)\">" : "[sound:\(name)]"
    }

    static let pickableTypes: [UTType] = [.image, .audio, .movie]
}

/// Edits a field the way it looks on the card: bold stays bold, pictures
/// show as pictures. The note's HTML is kept as-is underneath; only what
/// you change is changed.
struct RichFieldEditor: NSViewRepresentable {
    let html: String
    let dark: Bool
    let handle: RichEditorHandle
    @Binding var height: CGFloat
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MediaSchemeHandler(folder: Library.mediaFolder), forURLScheme: "study-media")
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "field")
        let view = FieldWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.parent = self
        context.coordinator.pending = html
        handle.webView = view
        view.loadHTMLString(Self.page(dark: dark), baseURL: URL(string: "study-media://media/"))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        handle.webView = view
        // Only replace the content when it changed from outside (e.g. after
        // editing the HTML directly), never while you're typing in it.
        if html != context.coordinator.lastHTML {
            context.coordinator.set(html)
        }
        view.evaluateJavaScript("document.body.classList.toggle('dark', \(dark)); true", completionHandler: nil)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "field")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RichFieldEditor?
        weak var webView: WKWebView?
        var lastHTML: String?
        var pending: String?
        private var loaded = false

        func set(_ html: String) {
            lastHTML = html
            guard loaded else {
                pending = html
                return
            }
            guard let data = try? JSONSerialization.data(withJSONObject: [html]),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("setContent(\(json)[0]); true", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !loaded else { return }
            loaded = true
            if let pending {
                self.pending = nil
                set(pending)
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if !loaded { return decisionHandler(.allow) }
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? ""),
               action.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "html":
                if let html = body["value"] as? String {
                    lastHTML = html
                    parent?.onChange(html)
                }
            case "file":
                // A picture or sound pasted or dropped in: save it, then show it.
                guard let base64 = body["data"] as? String, let data = Data(base64Encoded: base64) else { return }
                let original = body["name"] as? String ?? ""
                let mime = body["mime"] as? String ?? ""
                var ext = (original as NSString).pathExtension
                if ext.isEmpty { ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "png" }
                if let name = try? MediaFiles.add(data, ext: ext) {
                    let html = MediaFiles.html(for: name)
                    webView?.evaluateJavaScript("insertAtCursor(\(RichEditorHandle.js(html))); true", completionHandler: nil)
                }
            case "height":
                if let value = body["value"] as? Double {
                    (webView as? FieldWebView)?.contentHeight = CGFloat(value)
                    let height = max(44, min(CGFloat(value), 600))
                    if abs((parent?.height ?? 0) - height) > 1 { parent?.height = height }
                }
            default:
                break
            }
        }
    }

    static func page(dark: Bool) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; background: transparent; }
          body { font: 14px -apple-system, BlinkMacSystemFont, sans-serif; color: #1d1d1f;
                 -webkit-font-smoothing: antialiased; }
          body.dark { color: #ececee; }
          body.dark #f [style*="color: rgb(0, 0, 0)"], body.dark #f [style*="color:#000"],
          body.dark #f [style*="color: black"] { color: inherit !important; }
          #f { outline: none; padding: 9px 11px; min-height: 24px; word-wrap: break-word; line-height: 1.45; }
          #f:empty::before { content: "Empty"; color: #999; }
          img { max-width: 100%; height: auto; border-radius: 4px; }
          a { color: #0a84ff; }
        </style></head>
        <body class="\(dark ? "dark" : "")"><div id="f" contenteditable="true"></div>
        <script>
          const f = document.getElementById("f");
          const post = (type, value) => webkit.messageHandlers.field.postMessage({ type, value });
          const report = () => post("height", Math.ceil(f.getBoundingClientRect().height));
          let saved = null;
          document.addEventListener("selectionchange", () => {
            const s = getSelection();
            if (s.rangeCount && f.contains(s.getRangeAt(0).commonAncestorContainer)) saved = s.getRangeAt(0).cloneRange();
          });
          // Buttons outside the page take focus away; put the cursor back where it was.
          function restore() {
            const s = getSelection();
            const inside = s.rangeCount && f.contains(s.getRangeAt(0).commonAncestorContainer);
            f.focus();
            if (!inside && saved) { s.removeAllRanges(); s.addRange(saved); }
          }
          function changed() { post("html", f.innerHTML); report(); }
          function setContent(html) { f.innerHTML = html; saved = null; report(); }
          function format(cmd, value) { restore(); document.execCommand(cmd, false, value ?? null); changed(); }
          function insertAtCursor(html) { restore(); document.execCommand("insertHTML", false, html); changed(); }
          function focusEnd() {
            f.focus();
            const r = document.createRange(); r.selectNodeContents(f); r.collapse(false);
            const s = getSelection(); s.removeAllRanges(); s.addRange(r);
            saved = r.cloneRange();
          }
          function cloze(n) {
            restore();
            const s = getSelection();
            if (!s.rangeCount) return;
            const r = s.getRangeAt(0);
            const box = document.createElement("div");
            box.appendChild(r.cloneContents());
            if (box.textContent.trim()) {
              document.execCommand("insertHTML", false, "{{c" + n + "::" + box.innerHTML + "}}");
            } else {
              document.execCommand("insertText", false, "{{c" + n + "::}}");
              s.modify("move", "backward", "character"); s.modify("move", "backward", "character");
            }
            changed();
          }
          f.addEventListener("input", changed);
          f.addEventListener("keydown", e => {
            if (!e.metaKey || e.altKey || e.ctrlKey) return;
            const cmd = { b: "bold", i: "italic", u: "underline" }[e.key.toLowerCase()];
            if (cmd && !e.shiftKey) { e.preventDefault(); format(cmd); }
          });
          // Pictures and sounds go to the media folder; Swift saves them and inserts them back.
          function sendFile(file) {
            const reader = new FileReader();
            reader.onload = () => webkit.messageHandlers.field.postMessage({
              type: "file", name: file.name || "", mime: file.type, data: String(reader.result).split(",")[1] });
            reader.readAsDataURL(file);
          }
          const isMedia = file => /^(image|audio|video)[/]/.test(file.type);
          f.addEventListener("paste", e => {
            const files = [...e.clipboardData.files].filter(isMedia);
            if (files.length) { e.preventDefault(); files.forEach(sendFile); return; }
            // Text pastes as plain text so web pages don't bring their styles along.
            const text = e.clipboardData.getData("text/plain");
            if (text) { e.preventDefault(); document.execCommand("insertText", false, text); }
          });
          f.addEventListener("dragover", e => e.preventDefault());
          f.addEventListener("drop", e => {
            const files = [...(e.dataTransfer?.files || [])].filter(isMedia);
            if (!files.length) return;
            e.preventDefault();
            const at = document.caretRangeFromPoint(e.clientX, e.clientY);
            if (at) { saved = at; }
            files.forEach(sendFile);
          });
          new ResizeObserver(report).observe(f);
          document.addEventListener("load", e => { if (e.target.tagName === "IMG") report(); }, true);
        </script></body></html>
        """
    }
}

/// WebKit keeps a strong hold on its message handlers; this avoids a memory loop.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}


/// A field's editor grows to fit its text, so it has nothing of its own to
/// scroll: the mouse wheel goes to the page around it instead of getting stuck.
/// Only a very long field (taller than the 600 pt cap) scrolls itself.
final class FieldWebView: WKWebView {
    var contentHeight: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        if contentHeight <= bounds.height + 2, let outer = enclosingScrollView ?? nextResponder {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
