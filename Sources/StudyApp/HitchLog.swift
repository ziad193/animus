#if os(macOS)
import AppKit
import Foundation

/// Dev builds only: notes every time the app's main thread was too busy to
/// draw a frame, so slow spots show up as numbers rather than as a feeling.
/// Each line of `hitches.log` (in the test data folder) is how long the app
/// froze for, in milliseconds, and when.
@MainActor
enum HitchLog {
    private static var started = false
    private static var wokeAt: CFAbsoluteTime = 0
    private static var handle: FileHandle?
    private static var activity: NSObjectProtocol?
    private static var collecting = false
    private static var turns: [Double] = []
    private static let launch = CFAbsoluteTimeGetCurrent()

    static func startIfDevBuild() {
        guard Library.isTestCollection, !started,
              let folder = ProcessInfo.processInfo.environment["ITERUM_DATA_FOLDER"] else { return }
        started = true
        // Timings only mean something at full speed: stop macOS slowing the
        // app down while its window is behind others.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Timing page switches")
        let url = URL(fileURLWithPath: folder).appendingPathComponent("hitches.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)

        // One turn of the run loop is one chance to draw. Time each turn from
        // waking to going back to sleep; anything over two frames is a hitch.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, activity in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                if activity.contains(.afterWaiting) {
                    wokeAt = now
                } else if activity.contains(.beforeWaiting), wokeAt > 0 {
                    let ms = (now - wokeAt) * 1000
                    wokeAt = 0
                    if collecting { turns.append(ms) }
                    if ms >= 33 {
                        let line = String(format: "%7.2fs  %5.0f ms\n", now - launch, ms)
                        handle?.write(Data(line.utf8))
                    }
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)

        // Lets a script switch pages (back / forward) without touching the
        // window, so the timings aren't muddied by the tool doing the clicking.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.ziad.animus.dev.perf"), object: nil, queue: .main
        ) { note in
            let what = note.object as? String ?? ""
            MainActor.assumeIsolated {
                mark(what)
                switch what {
                case "back": NotificationCenter.default.post(name: .iterumGoBack, object: nil)
                case "forward": NotificationCenter.default.post(name: .iterumGoForward, object: nil)
                case "scroll": scrollTest()
                case "count": countViews()
                case "tips": listTips()
                case "glass": GlassTest.shared.live.toggle()   // real glass, or the cheap kind
                case "big", "small":
                    // Your usual window size (nearly the whole laptop screen), or the default.
                    let window = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("AppWindow") == true }
                    if let window, let screen = window.screen ?? NSScreen.main {
                        let size = what == "big" ? NSSize(width: 1710, height: 1011) : NSSize(width: 1100, height: 720)
                        let origin = what == "big" ? screen.visibleFrame.origin : NSPoint(x: 305, y: 185)
                        window.setFrame(NSRect(origin: origin, size: size), display: true)
                    }
                case "space":
                    // As if Space were pressed: show the answer, or rate the card Good.
                    let window = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("AppWindow") == true }
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window?.windowNumber ?? 0, context: nil, characters: " ",
                                                    charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
                        NSApp.postEvent(event, atStart: false)
                    }
                default:
                    // Open the page, and note every frame's work for the next 1.4 seconds.
                    turns = []
                    collecting = true
                    NotificationCenter.default.post(name: .iterumPerfOpen, object: what)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        MainActor.assumeIsolated {
                            collecting = false
                            let big = turns.filter { $0 >= 8 }.map { String(format: "%.0f", $0) }.joined(separator: " ")
                            let line = String(format: "          %@: busy %.0f ms in %d turns; turns of 8 ms or more: %@\n",
                                              what, turns.reduce(0, +), turns.count, big)
                            handle?.write(Data(line.utf8))
                        }
                    }
                }
            }
        }
    }

    /// Scrolls the page's main list down and back up over three seconds, as a
    /// steady hand would, and notes how long the app took over each frame.
    private static func scrollTest() {
        let window = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("AppWindow") == true }
        var best: NSScrollView?
        func find(_ view: NSView) {
            if let scroll = view as? NSScrollView, let doc = scroll.documentView,
               doc.frame.height > scroll.contentSize.height + 50,
               scroll.frame.width * scroll.frame.height > (best.map { $0.frame.width * $0.frame.height } ?? 0) {
                best = scroll
            }
            view.subviews.forEach(find)
        }
        if let root = window?.contentView?.superview ?? window?.contentView { find(root) }
        guard let scroll = best, let doc = scroll.documentView else {
            handle?.write(Data("          scroll: nothing to scroll here\n".utf8))
            return
        }
        let range = min(doc.frame.height - scroll.contentSize.height, 2400)
        let steps = 180
        var step = 0
        turns = []
        collecting = true
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                step += 1
                let phase = Double(step) / Double(steps)
                let y = range * (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                guard step >= steps else { return }
                timer.invalidate()
                collecting = false
                let sorted = turns.sorted()
                let total = turns.reduce(0, +)
                let slow = turns.filter { $0 > 16.7 }.count
                let line = String(format: "          scroll: %.0f pt each way, %d frames, busy %.0f ms of 3000, typical %.1f ms, worst %.0f ms, %d frames too slow for 60 a second\n",
                                  range, turns.count, total, sorted[sorted.count / 2], sorted.last ?? 0, slow)
                handle?.write(Data(line.utf8))
            }
        }
    }

    /// Marks a point in the log, so hitches can be matched to what was done.
    static func mark(_ text: String) {
        guard started else { return }
        let line = String(format: "%7.2fs  -- %@\n", CFAbsoluteTimeGetCurrent() - launch, text)
        handle?.write(Data(line.utf8))
    }

    /// Every hover tip in the window and where it sits, to track down one showing in the wrong place.
    private static func listTips() {
        var lines: [String] = []
        func visit(_ view: NSView) {
            if let tip = view.toolTip, !tip.isEmpty, let window = view.window {
                let frame = view.convert(view.bounds, to: nil)
                let top = window.frame.height - frame.maxY
                lines.append(String(format: "          tip x %.0f y %.0f  %.0f×%.0f  hidden %d  %@  [%@]\n", frame.minX, top, frame.width, frame.height,
                                    view.isHiddenOrHasHiddenAncestor ? 1 : 0, String(tip.prefix(60)), String(describing: type(of: view)).prefix(24).description))
            }
            view.subviews.forEach(visit)
        }
        for window in NSApp.windows where window.isVisible {
            if let root = window.contentView?.superview ?? window.contentView { visit(root) }
        }
        handle?.write(Data(lines.joined().utf8))
    }

    /// How much the page on screen is made of: AppKit views and layers.
    private static func countViews() {
        var views = 0, layers = 0, kinds: [String: Int] = [:]
        func count(_ view: NSView) {
            views += 1
            kinds[String(describing: type(of: view)).prefix(40).description, default: 0] += 1
            view.subviews.forEach(count)
        }
        func count(_ layer: CALayer) { layers += 1; layer.sublayers?.forEach(count) }
        for window in NSApp.windows where window.isVisible {
            if let root = window.contentView?.superview ?? window.contentView {
                count(root)
                if let layer = root.layer { count(layer) }
            }
        }
        let top = kinds.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        let before = String(format: "%7.2fs  ## was showing %d views, %d layers: %@\n",
                            CFAbsoluteTimeGetCurrent() - launch, views, layers, top)
        handle?.write(Data(before.utf8))
    }
}
#endif
