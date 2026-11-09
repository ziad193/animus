import Foundation
import WebKit

/// The page cards are shown in, on Mac, iPhone and iPad.
enum CardPage {

    /// Loaded once. `study.show()` swaps cards in and out.
    static let shell = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style id="note-css"></style>
    <style>
      :root { --zoom: 1; --accent: #0a84ff; --text: #1d1d1f; }
      .nightMode { --text: #e8e8ea; }
      html, body, .card { background: transparent !important; }
      body { margin: 0; padding: 28px 36px 56px; -webkit-font-smoothing: antialiased; }
      .nightMode.card { color: var(--text); }
      #qa { zoom: var(--zoom); transition: opacity 90ms ease; }
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
      .study-reveal { animation: study-reveal 180ms ease-out both; }
      @keyframes study-reveal {
        from { opacity: 0; transform: translateY(6px); }
        to { opacity: 1; transform: none; }
      }

      /* Type-the-answer: Anki's comparison of what you typed. */
      #typeans { font-family: ui-monospace, Menlo, monospace; margin: .6em auto; text-align: center; }
      .typeGood { background: rgba(48, 209, 88, .35); border-radius: 3px; }
      .typeBad { background: rgba(255, 69, 58, .35); border-radius: 3px; }
      .typeMissed { background: rgba(142, 142, 147, .35); border-radius: 3px; }
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

      // Maths formulas: \\\\( … \\\\) inline and \\\\[ … \\\\] on their own line, as in Anki.
      // MathJax is big, so it's only loaded the first time a card needs it.
      let mathjax = null;
      function loadMathJax() {
        if (mathjax) return mathjax;
        window.MathJax = {
          tex: {
            displayMath: [["\\\\[", "\\\\]"]],
            processEscapes: false, processEnvironments: false, processRefs: false,
            packages: { "[+]": ["noerrors", "mathtools"], "[-]": ["textmacros"] },
          },
          svg: { fontCache: "local" },
          startup: { typeset: false },
        };
        mathjax = new Promise(resolve => {
          const s = document.createElement("script");
          s.src = "study-app://mathjax/tex-svg-full.js";
          s.onload = () => window.MathJax.startup.promise.then(resolve, resolve);
          s.onerror = resolve;
          document.head.appendChild(s);
        });
        return mathjax;
      }
      const hasMath = html => html.includes("\\\\(") || html.includes("\\\\[");
      async function typeset(root) {
        await loadMathJax();
        if (!window.MathJax || !window.MathJax.typesetPromise) return;
        try { await window.MathJax.typesetPromise([root]); } catch (e) {}
      }

      // Pasted text often brings its own colours, e.g. dark grey text on a white
      // highlight from a website. On a dark card that text vanishes; on a light
      // card pasted white text does. Fix the colours written into the card itself
      // (not the deck's own styling): plain greys follow the theme, coloured text
      // keeps its hue but is made bright or dark enough to read, and highlights
      // that would glare or hide the text are toned down.
      function parseRGB(value) {
        const m = (value || "").match(/[0-9.]+/g);
        if (!m || m.length < 3) return null;
        const a = m.length > 3 ? parseFloat(m[3]) : 1;
        return { r: +m[0] / 255, g: +m[1] / 255, b: +m[2] / 255, a: a };
      }
      function toHSL(c) {
        const max = Math.max(c.r, c.g, c.b), min = Math.min(c.r, c.g, c.b);
        const l = (max + min) / 2, d = max - min;
        if (d === 0) return { h: 0, s: 0, l: l };
        const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
        let h = max === c.r ? (c.g - c.b) / d + (c.g < c.b ? 6 : 0) : max === c.g ? (c.b - c.r) / d + 2 : (c.r - c.g) / d + 4;
        return { h: h * 60, s: s, l: l };
      }
      const hsl = (c, l) => "hsl(" + Math.round(c.h) + "," + Math.round(c.s * 100) + "%," + Math.round(l * 100) + "%)";
      function fixColours(root, dark) {
        const marked = root.querySelectorAll("[style*='color'], font[color], [bgcolor]");
        for (const el of marked) {
          if (el.closest("svg, mjx-container")) continue;
          const style = getComputedStyle(el);
          const text = parseRGB(style.color);
          if (text && (el.hasAttribute("color") || /(^|;)[ ]*color[ ]*:/i.test(el.getAttribute("style") || ""))) {
            const c = toHSL(text);
            if (dark && c.l < 0.55) {
              if (c.s < 0.25) el.style.setProperty("color", "inherit", "important");
              else el.style.setProperty("color", hsl(c, Math.max(0.68, 1 - c.l)), "important");
            } else if (!dark && c.l > 0.75) {
              if (c.s < 0.25) el.style.setProperty("color", "inherit", "important");
              else el.style.setProperty("color", hsl(c, Math.min(0.38, 1 - c.l)), "important");
            }
          }
          const back = parseRGB(style.backgroundColor);
          if (back && back.a > 0.05) {
            const c = toHSL(back);
            if (dark && c.l > 0.6) {
              if (c.s < 0.25) el.style.setProperty("background-color", "transparent", "important");
              else el.style.setProperty("background-color", hsl(c, 0.3), "important");
            } else if (!dark && c.l < 0.3) {
              if (c.s < 0.25) el.style.setProperty("background-color", "transparent", "important");
              else el.style.setProperty("background-color", hsl(c, 0.85), "important");
            }
          }
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
          await sleep(60);
          if (mine !== token) return;
        }
        qa.innerHTML = p.html;
        runScripts(qa);
        fixColours(qa, p.dark);
        if (hasMath(p.html)) {
          await Promise.race([typeset(qa), sleep(2000)]);
          if (mine !== token) return;
        }
        // A new card waits a moment for its pictures so it doesn't jump; the
        // answer never waits (its pictures were fetched while the question showed).
        if (!sameCard && !revealing) await imagesReady(qa, 150);
        if (mine !== token) return;

        if (revealing) {
          // Slide the whole answer in as one piece. (Animating each element on
          // its own left plain text showing at once and bold words fading in late.)
          const marker = document.getElementById("answer");
          if (marker) {
            const wrap = document.createElement("div");
            wrap.className = "study-reveal";
            while (marker.nextSibling) wrap.appendChild(marker.nextSibling);
            marker.after(wrap);
            marker.scrollIntoView({ behavior: "smooth", block: "start" });
          }
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

/// Serves the app's own web files (MathJax) from inside Animus.app, and nothing else.
final class AppResourceHandler: NSObject, WKURLSchemeHandler {
    private static let folder = Bundle.main.resourceURL?.appendingPathComponent("mathjax").standardizedFileURL

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "mathjax", let folder = Self.folder else {
            return task.didFailWithError(URLError(.badURL))
        }
        let file = folder.appendingPathComponent(url.lastPathComponent).standardizedFileURL
        guard file.path.hasPrefix(folder.path + "/"), let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        task.didReceive(URLResponse(url: url, mimeType: "text/javascript",
                                    expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
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
