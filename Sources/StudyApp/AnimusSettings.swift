import AppKit
import SwiftUI

/// Settings › Animus: the version, your plan, a product key, feedback and
/// donations. Feedback and donations aren't set up yet, so they say "coming
/// soon"; the plan and key go through `PlusStore` (no server yet, so keys
/// can't be confirmed and nothing is saved).
struct AnimusSettings: View {
    @AppStorage(Pref.accent) private var accent = AccentChoice.blue
    @State private var productKey = ""
    @State private var comingSoon: ComingSoon?
    @State private var plus = PlusStore.shared
    @State private var showingPlus = false
    @State private var keyMessage: String?
    @State private var activating = false

    enum ComingSoon: String, Identifiable {
        case feedback, donate
        var id: String { rawValue }

        var title: String {
            switch self {
            case .feedback: "Feedback is coming soon"
            case .donate: "Donations are coming soon"
            }
        }

        var message: String {
            switch self {
            case .feedback: "Soon you'll be able to send ideas and report problems from here."
            case .donate: "Soon you'll be able to support Animus from here. Thank you for thinking of it."
            }
        }
    }

    private var planDetail: String {
        guard let renews = plus.license?.renews else { return "Thank you for supporting Animus." }
        return "Renews \(renews.formatted(date: .abbreviated, time: .omitted))."
    }

    private func activate() {
        guard !productKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        activating = true
        Task {
            keyMessage = await plus.activate(productKey)
            activating = false
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Who we are and which version this is.
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Animus").font(.title.weight(.semibold))
                    Text(version)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Built on Anki's engine \(AppInfo.ankiVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Your plan.
            VStack(alignment: .leading, spacing: 10) {
                Text("Your plan").font(.headline)
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text(plus.planTitle)
                        if plus.hasPlus { PlusBadge() }
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Text(plus.hasPlus ? planDetail : "Everything you need to study, free.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button {
                    showingPlus = true
                } label: {
                    HStack(spacing: 10) {
                        AnimusPlusGlyph(size: 20)
                        Text("Find out about Animus+")
                    }
                    .padding(.top, 4)
                }
                .buttonStyle(.link)
                .tip("What Animus+ will add")
            }

            // Free users can switch off Plus buttons and badges around the app.
            if !plus.hasPlus {
                Toggle(isOn: $plus.showPrompts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Animus+ suggestions")
                        Text("Plus buttons and badges around the app. Turn off to hide them; you can still find Animus+ here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.row)
            }

            // A product key.
            VStack(alignment: .leading, spacing: 8) {
                Text("Product key").font(.headline)
                HStack {
                    TextField("XXXXX-XXXXX-XXXXX-XXXXX", text: $productKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit { activate() }
                        .onChange(of: productKey) { keyMessage = nil }
                    Button {
                        activate()
                    } label: {
                        if activating { ProgressView().controlSize(.small) } else { Text("Activate") }
                    }
                    .disabled(productKey.trimmingCharacters(in: .whitespaces).isEmpty || activating)
                }
                if let keyMessage {
                    Label(keyMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Have an Animus+ key? Enter it here to unlock Animus+.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Animus+ (Animus Dev only until it's ready): explain cards you get wrong.
            if plus.showsPreviews && plus.hasPlus {
                Toggle(isOn: $plus.explainMistakes) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) { Text("Explain cards I get wrong"); PlusBadge() }
                        Text("After you press Again, a short note on why, and a way to remember it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.row)
            }

            // Animus Dev only: switch Animus+ on, to build and try its screens.
            if plus.showsPreviews {
                Toggle(isOn: $plus.devPreview) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preview Animus+ (Animus Dev only)")
                        Text("Unlocks Plus features in this dev copy, without a key. Never in the real app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.row)
            }

            Divider()

            // Feedback and donations.
            HStack(spacing: 12) {
                Button {
                    comingSoon = .feedback
                } label: {
                    Label("Feedback & Suggestions", systemImage: "bubble.left.and.text.bubble.right")
                }
                .tip("Tell us what you'd like to see, or what isn't working")
                Button {
                    comingSoon = .donate
                } label: {
                    Label("Donate", systemImage: "heart")
                }
                .tip("Support Animus")
                Spacer()
            }
            .controlSize(.large)
        }
        .padding(24)
        .sheet(isPresented: $showingPlus) { PlusInfoSheet() }
        .alert(item: $comingSoon) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
    }
}

// MARK: - The Animus glyph

/// A one-colour drawing of the app icon (a fanned stack of cards with the
/// circling arrows), for places that need a small symbol rather than the
/// full-colour icon: the Settings tab and the Animus+ link.
struct AnimusGlyph: View {
    var size: CGFloat = 18

    var body: some View {
        let w = size, h = size * 0.72
        ZStack {
            // The cards behind, fanned out like the icon.
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .strokeBorder(lineWidth: max(1, size * 0.08))
                .frame(width: w * 0.86, height: h * 0.86)
                .rotationEffect(.degrees(-14))
                .offset(x: -size * 0.06, y: size * 0.06)
            // The front card, with the arrows cut out of it.
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .frame(width: w * 0.86, height: h * 0.86)
                .rotationEffect(.degrees(-4))
                .overlay {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .offset(x: size * 0.04, y: -size * 0.02)
        }
        .frame(width: size, height: size)
    }

    /// The tab icon, drawn once.
    @MainActor static let tabImage = templateImage()

    /// The glyph as a template image (it takes the colour of wherever it's
    /// shown), for the Settings window's tab bar.
    @MainActor static func templateImage(size: CGFloat = 18) -> NSImage {
        // Drawn a little inside its square, to match the weight of the other tab symbols.
        let renderer = ImageRenderer(content: AnimusGlyph(size: size * 0.8)
            .foregroundStyle(.black)
            .frame(width: size, height: size))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }
}

/// The glyph with a little "+" bubble on its corner, like a notification badge.
struct AnimusPlusGlyph: View {
    var size: CGFloat = 18

    var body: some View {
        AnimusGlyph(size: size)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.36, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.56, height: size * 0.56)
                    .background(Circle().fill(Color.red))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: size * 0.28, y: -size * 0.24)
            }
    }
}
