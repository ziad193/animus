import AppKit
import SwiftUI
import WebKit

/// What the card view should show right now.
struct CardPayload: Equatable {
    var cardID: Int64
    var side: Side
    var html: String
    var css: String
    /// The question of the card after this one, so its images load early.
    var upcoming: String?
    var dark: Bool
    var zoom: Double
    var appStyle: Bool
    var accentHex: String

    enum Side: String { case question = "q", answer = "a" }
}

/// Shows a card using the Mac's built-in WebKit (Anki cards are HTML).
///
/// One page is loaded once and kept; each new card is swapped in with
/// JavaScript, so there is no blank flash between cards. Images for the
/// next card are fetched in advance.
///
/// - Images load from the media folder through a private `study-media://`
///   address, so the page can't reach anything else on disk.
/// - Audio links (`study-play://q/0`) are caught and handed back to Swift.
struct CardWebView: NSViewRepresentable {
    let payload: CardPayload
    let mediaFolder: URL
    let onPlayAudio: (_ side: String, _ index: Int) -> Void

    func makeCoordinator() -> Holder { Holder() }

    /// Takes a card view that's already loaded and waiting, so the first
    /// card appears straight away instead of after the web engine starts.
    func makeNSView(context: Context) -> WKWebView {
        let host = CardWebHost.take()
        context.coordinator.host = host
        return host.view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard let host = context.coordinator.host else { return }
        host.onPlayAudio = onPlayAudio
        host.show(payload)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Holder) {
        if let host = coordinator.host { CardWebHost.giveBack(host) }
        coordinator.host = nil
    }

    final class Holder {
        var host: CardWebHost?
    }

    /// Call at launch so a card view is ready before the first study session.
    static func prepare() {
        CardWebHost.prepare()
    }

    /// Drops the waiting card views, e.g. after switching profile (they point at the old media folder).
    static func reset() {
        CardWebHost.reset()
    }
}

/// One loaded card page and its web view. Kept in a small pool and reused,
/// because starting a fresh web view takes a few seconds the first time.
@MainActor
final class CardWebHost: NSObject, WKNavigationDelegate {
    let view: WKWebView
    var onPlayAudio: ((String, Int) -> Void)?
    private var shellReady = false
    private var shown: CardPayload?
    private var waiting: CardPayload?

    private static var spare: [CardWebHost] = []

    static func prepare() {
        if spare.isEmpty { spare.append(CardWebHost()) }
    }

    static func reset() {
        spare.removeAll()
        prepare()
    }

    static func take() -> CardWebHost {
        let host = spare.popLast() ?? CardWebHost()
        // Have the next one warming up in the background.
        DispatchQueue.main.async { prepare() }
        return host
    }

    static func giveBack(_ host: CardWebHost) {
        host.onPlayAudio = nil
        host.shown = nil
        host.waiting = nil
        host.view.evaluateJavaScript("study.clear(); true", completionHandler: nil)
        host.view.removeFromSuperview()
        if spare.count < 2 { spare.append(host) }
    }

    private override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MediaSchemeHandler(folder: Library.mediaFolder), forURLScheme: "study-media")
        view = PassiveWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        super.init()
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(CardWebView.shell, baseURL: URL(string: "study-media://media/"))
    }

    func show(_ payload: CardPayload) {
        guard payload != shown else { return }
        guard shellReady else {
            waiting = payload
            return
        }
        shown = payload
        let object: [String: Any] = [
            "id": String(payload.cardID),
            "side": payload.side.rawValue,
            "html": payload.html,
            "css": payload.css,
            "upcoming": payload.upcoming ?? "",
            "dark": payload.dark,
            "zoom": payload.zoom,
            "appStyle": payload.appStyle,
            "accent": payload.accentHex,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var json = String(data: data, encoding: .utf8) else { return }
        // These two characters are valid in JSON but not in JavaScript source.
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        view.evaluateJavaScript("study.show(\(json)); true") { _, error in
            if let error { NSLog("Study card view: %@", String(describing: error)) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !shellReady else { return }
        shellReady = true
        if let waiting {
            self.waiting = nil
            show(waiting)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        switch url.scheme {
        case "study-play":
            if let side = url.host, let index = Int(url.lastPathComponent) {
                onPlayAudio?(side, index)
            }
            decisionHandler(.cancel)
        case "study-media", "about":
            // Only the first load of the shell page is allowed; cards never navigate away.
            decisionHandler(shellReady && action.navigationType == .linkActivated ? .cancel : .allow)
        case "http", "https":
            // Links on cards open in the student's normal browser.
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
        }
    }
}

extension CardWebView {
    // MARK: - The page

    /// Loaded once. `study.show()` swaps cards in and out.
    static let shell = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <style id="note-css"></style>
    <style>
      :root { --zoom: 1; --accent: #0a84ff; --text: #1d1d1f; }
      .nightMode { --text: #e8e8ea; }
      html, body, .card { background: transparent !important; }
      body { margin: 0; padding: 28px 36px 56px; -webkit-font-smoothing: antialiased; }
      .nightMode.card { color: var(--text); }
      #qa { zoom: var(--zoom); transition: opacity 120ms ease; }
      #qa.hidden { opacity: 0; }
      img { max-width: 100%; height: auto; }
      a { color: var(--accent); }

      /* Clean "app style": system font and theme colours, the deck's layout kept. */
      .app-style.card, .app-style .card {
        font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif !important;
        color: var(--text) !important;
      }
      .app-style .cloze { color: var(--accent) !important; }
      .app-style hr#answer { border: none; border-top: 1px solid rgba(127,127,127,.3); margin: 1.2em 0; }

      /* In dark mode, pasted black text and white highlights would be invisible or glaring. */
      .nightMode [style*="color: rgb(0, 0, 0)"], .nightMode [style*="color:rgb(0,0,0)"],
      .nightMode [style*="color: black"], .nightMode [style*="color:#000"],
      .nightMode [style*="color: #000"], .nightMode font[color="#000000"] { color: inherit !important; }
      .nightMode [style*="background-color: rgb(255, 255, 255)"],
      .nightMode [style*="background-color: white"],
      .nightMode [style*="background-color: #fff"] { background-color: transparent !important; }

      /* The answer slides in under the question. */
      .study-reveal { animation: study-reveal 260ms ease-out both; }
      @keyframes study-reveal {
        from { opacity: 0; transform: translateY(6px); }
        to { opacity: 1; transform: none; }
      }

      .study-play {
        display: inline-flex; align-items: center; justify-content: center;
        width: 1.8em; height: 1.8em; margin: 0 .2em; border-radius: 50%;
        text-decoration: none; font-size: .8em; vertical-align: middle;
        color: inherit; background: rgba(127,127,127,.18);
      }
      .study-play:hover { background: rgba(127,127,127,.3); }
    </style>
    <script>
    window.study = (() => {
      let token = 0, currentID = null, currentSide = null;
      const prefetched = new Set();
      const sleep = ms => new Promise(r => setTimeout(r, ms));

      // innerHTML doesn't run <script> tags, but some decks need them.
      function runScripts(root) {
        for (const old of root.querySelectorAll("script")) {
          const s = document.createElement("script");
          for (const a of old.attributes) s.setAttribute(a.name, a.value);
          s.textContent = old.textContent;
          old.replaceWith(s);
        }
      }

      // Wait (briefly) for images so the card doesn't jump while they load.
      function imagesReady(root, limit) {
        const pending = [...root.querySelectorAll("img")].filter(i => !i.complete);
        if (!pending.length) return Promise.resolve();
        return Promise.race([
          Promise.all(pending.map(i => new Promise(r => { i.onload = i.onerror = r; }))),
          sleep(limit),
        ]);
      }

      function prefetch(html) {
        if (!html) return;
        const doc = new DOMParser().parseFromString(html, "text/html");
        for (const img of doc.querySelectorAll("img[src]")) {
          const src = img.getAttribute("src");
          if (prefetched.has(src)) continue;
          prefetched.add(src);
          new Image().src = src;
        }
      }

      async function show(p) {
        const mine = ++token;
        const qa = document.getElementById("qa");
        const body = document.body;
        body.classList.toggle("nightMode", p.dark);
        body.classList.toggle("night_mode", p.dark);
        body.classList.toggle("app-style", p.appStyle);
        document.documentElement.style.setProperty("--zoom", p.zoom);
        document.documentElement.style.setProperty("--accent", p.accent);
        document.getElementById("note-css").textContent = p.css;

        const revealing = p.id === currentID && currentSide === "q" && p.side === "a";
        const sameCard = p.id === currentID && p.side === currentSide;
        currentID = p.id; currentSide = p.side;

        if (!revealing && !sameCard) {
          qa.classList.add("hidden");
          await sleep(90);
          if (mine !== token) return;
        }
        qa.innerHTML = p.html;
        runScripts(qa);
        if (!sameCard) await imagesReady(qa, 300);
        if (mine !== token) return;

        if (revealing) {
          const marker = document.getElementById("answer");
          let el = marker ? marker.nextElementSibling : null;
          if (marker) marker.classList.add("study-reveal");
          while (el) { el.classList.add("study-reveal"); el = el.nextElementSibling; }
          if (marker) marker.scrollIntoView({ behavior: "smooth", block: "start" });
        } else if (!sameCard) {
          window.scrollTo(0, 0);
        }
        qa.classList.remove("hidden");
        prefetch(p.upcoming);
      }

      // Empties the page when the view is put back in the pool.
      function clear() {
        token++;
        const qa = document.getElementById("qa");
        qa.innerHTML = "";
        qa.classList.add("hidden");
        currentID = null; currentSide = null;
      }

      return { show, clear };
    })();
    </script>
    </head>
    <body class="card"><div id="qa" class="hidden"></div></body></html>
    """
}

/// A web view that never grabs the keyboard, so Space and 1–4 always reach
/// the study screen instead of scrolling the card.
private final class PassiveWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
}

/// Serves files from the media folder, and nothing outside it.
/// Files are read off the main thread so big images don't stall the UI.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    let folder: URL
    private var stopped = Set<ObjectIdentifier>()

    init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let name = url.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              !name.isEmpty else {
            return task.didFailWithError(URLError(.badURL))
        }
        let file = folder.appendingPathComponent(name).standardizedFileURL
        guard file.path.hasPrefix(folder.path + "/") else {
            return task.didFailWithError(URLError(.noPermissionsToReadFile))
        }
        let id = ObjectIdentifier(task)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: file)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stopped.remove(id) == nil else { return }
                guard let data else {
                    return task.didFailWithError(URLError(.fileDoesNotExist))
                }
                let response = URLResponse(url: url,
                                           mimeType: Self.mimeType(for: file.pathExtension),
                                           expectedContentLength: data.count,
                                           textEncodingName: nil)
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "css": "text/css"
        case "js": "text/javascript"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        default: "application/octet-stream"
        }
    }
}
