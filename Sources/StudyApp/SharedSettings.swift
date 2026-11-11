#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

// Settings shared by the Mac app and the iPhone/iPad app.

/// Settings the student picks in Setup or Settings (⌘,). Stored with
/// UserDefaults, so they belong to this Mac, not to the collection.
enum Pref {
    /// The deck studied most recently, for Home's Continue button.
    static let lastStudiedDeck = "lastStudiedDeck"
    /// Whether Add Cards shows the "open your slides beside you" hint.
    static let slidesHint = "addCards.showSlidesHint"
    static let setupDone = "setupDone"
    static let appearance = "appearance"
    static let accent = "accent"
    static let cardTextSize = "cardTextSize"
    static let cardStyle = "cardStyle"
    /// While studying: whether the deck list shows down the side (off by default).
    static let studyShowDecks = "study.showDecks"
    /// While studying: whether the tabs (Home, Add Cards…) show along the top.
    static let studyShowTabs = "study.showTabs"
    /// While studying: the card glows in the colour of the answer you give.
    static let studyGlow = "study.glow"
    /// TEST ONLY: lets Claude reach your cards through Animus (see Connector.swift).
    static let connector = "connector.enabled"
    /// A small meter in the corner of the window: frames a second and what Animus is using.
    static let perfMeter = "perf.meter"
    /// While studying: how frosted the glass pane behind the card is.
    static let studyPane = "study.paneStyle"
}

/// The pane behind the card while you study: frosted glass over a background
/// picture (three strengths), or no pane at all.
enum CardPaneStyle: String, CaseIterable, Identifiable {
    case frosted, lighter, lightest, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .frosted: "Frosted"
        case .lighter: "Lighter"
        case .lightest: "Lightest"
        case .none: "None"
        }
    }
    /// The picture shows through enough that the card's words need a soft shadow.
    var needsTextShadow: Bool { self == .lightest || self == .none }
}

/// Whether cards use the app's clean look or the deck's own fonts and colours.
enum CardStyle: String, CaseIterable, Identifiable {
    case app, deck
    var id: String { rawValue }
    var title: String {
        switch self {
        case .app: "Clean"
        case .deck: "Deck's own"
        }
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, purple, pink, orange, green, teal
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        }
    }

    /// CSS colour for cards, e.g. "#0a84ff".
    var hex: String {
        #if os(macOS)
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02x%02x%02x",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
        #endif
    }
}

enum CardTextSize: String, CaseIterable, Identifiable {
    case small, normal, large, extraLarge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Small"
        case .normal: "Normal"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }
    /// Zoom applied to card content.
    var zoom: Double {
        switch self {
        case .small: 0.9
        case .normal: 1.0
        case .large: 1.2
        case .extraLarge: 1.4
        }
    }
}

