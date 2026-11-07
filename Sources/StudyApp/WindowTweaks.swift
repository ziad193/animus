import AppKit
import SwiftUI

/// Keeps the title bar's bottom edge switched off on every window.
///
/// macOS draws that edge as a dark line, and with this app's layout it showed
/// up through the middle of the toolbar. SwiftUI can switch it back on when it
/// rebuilds the toolbar (changing page, opening a sheet), so this watches the
/// setting and turns it off again whenever it changes.
struct WindowTweaks: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.watch(window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.watch(view.window)
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observation: NSKeyValueObservation?

        func watch(_ window: NSWindow?) {
            guard let window else { return }
            Self.hideLine(in: window)
            guard window !== self.window else { return }
            self.window = window
            observation = window.observe(\.titlebarSeparatorStyle, options: [.new]) { window, _ in
                MainActor.assumeIsolated { Self.hideLine(in: window) }
            }
        }

        static func hideLine(in window: NSWindow) {
            guard window.titlebarSeparatorStyle != .none else { return }
            // Instantly, so it doesn't visibly fade out.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                window.titlebarSeparatorStyle = .none
            }
        }
    }

    /// Tells us as soon as the view is placed in (or moved to) a window.
    /// It never takes the mouse, so hover notes on the views around it still work.
    final class TrackingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Our own frosted strip behind the toolbar. The system's toolbar background
/// is switched off (it came with the dark line), so this keeps scrolled
/// content from showing through the toolbar.
struct ToolbarBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            TitlebarMaterial()
                .frame(height: proxy.safeAreaInsets.top)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }

    /// Frosted glass that never takes the mouse (the toolbar's buttons sit on it).
    final class PassThroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct TitlebarMaterial: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = PassThroughEffectView()
            view.material = .titlebar
            view.blendingMode = .withinWindow
            view.state = .followsWindowActiveState
            return view
        }
        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}
