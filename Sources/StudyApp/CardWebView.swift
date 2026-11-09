import AppKit
import SwiftUI
import WebKit

/// What the card view should show right now.
struct CardPayload: Equatable {
    var cardID: Int64
    var side: Side
    var html: String
    var css: String
    /// Pictures to fetch early: this card's answer (while the question shows)
    /// and the next card's question.
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
        config.setURLSchemeHandler(AppResourceHandler(), forURLScheme: "study-app")
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

/// A web view that never grabs the keyboard, so Space and 1–4 always reach
/// the study screen instead of scrolling the card.
private final class PassiveWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
}

extension CardWebView {
    /// The card page, shared with the iPhone and iPad app (CardPage.swift).
    static var shell: String { CardPage.shell }
}
