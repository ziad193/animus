import AppKit
import SwiftUI

/// Small text and icon buttons (the kind macOS draws with no border).
/// Shows a soft highlight under the pointer and a darker one while pressed.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration)
    }

    private struct HoverButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.16 : hovering ? 0.08 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    /// A borderless button that lights up when you point at it.
    static var hoverable: HoverButtonStyle { HoverButtonStyle() }
}

/// For big custom buttons (tiles, chips, cards): brightens a little and lifts
/// on hover, dips when pressed.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.015
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .brightness(hovering ? 0.04 : 0)
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: hovering ? 8 : 0, y: hovering ? 3 : 0)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
    }
}

/// For standard bordered buttons (Study Now, Save, Add Card…), which macOS
/// doesn't highlight on its own.
struct HoverGlow: ViewModifier {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .brightness(hovering && isEnabled ? 0.07 : 0)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.015) -> some View { modifier(HoverLift(scale: scale)) }
    func hoverGlow() -> some View { modifier(HoverGlow()) }
}

/// The app's standard button: a soft rounded fill that darkens under the
/// pointer. Set once at the top of each window, so every plain `Button`
/// gets it unless it asks for a different style.
struct HoverBorderedStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        private var padding: (h: CGFloat, v: CGFloat) {
            switch controlSize {
            case .mini, .small: (7, 2)
            case .large, .extraLarge: (14, 7)
            default: (10, 4)
            }
        }

        var body: some View {
            let fill = !isEnabled ? 0.05 : configuration.isPressed ? 0.22 : hovering ? 0.15 : 0.08
            configuration.label
                .padding(.horizontal, padding.h)
                .padding(.vertical, padding.v)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(fill)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.06)))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == HoverBorderedStyle {
    static var hoverBordered: HoverBorderedStyle { HoverBorderedStyle() }
}

// MARK: - Hover tips

/// A hover tip (tooltip) that shows reliably.
///
/// SwiftUI's own `.tip()` re-registers its tip every time the view redraws,
/// and these screens redraw a lot (hover highlights, ticking timers), which
/// cancels the tip before it appears. This hands the tip to a plain AppKit
/// view that stays put, and only touches it when the text actually changes.
private struct TipView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TipNSView {
        let view = TipNSView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: TipNSView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }

    /// Only there for its tip. It never takes the mouse: AppKit asks views like
    /// this directly, whatever SwiftUI's `allowsHitTesting` says, so without
    /// this a tip left over from another page could swallow clicks meant for
    /// the buttons underneath. Tips still show (macOS tracks them separately).
    final class TipNSView: NSView {
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// The hover tip for this control. Use instead of `.tip()`.
    func tip(_ text: String) -> some View {
        overlay(TipView(text: text).allowsHitTesting(false))
            .accessibilityHint(Text(text))
    }
}
