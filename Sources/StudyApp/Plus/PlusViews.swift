import SwiftUI

/// The small "PLUS" label next to anything that's part of Animus+.
struct PlusBadge: View {
    var body: some View {
        Text("PLUS")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.95),
                                                               Color(red: 0.62, green: 0.32, blue: 0.92)],
                                                      startPoint: .leading, endPoint: .trailing)))
            .accessibilityLabel("Animus Plus")
    }
}

/// What Animus+ is: the features, and that the free version stays free.
/// Opened from Settings › Animus, and from any Plus feature you haven't unlocked.
struct PlusInfoSheet: View {
    /// The feature that brought you here, shown first and highlighted.
    var highlight: PlusFeature?
    @Environment(\.dismiss) private var dismiss

    private var features: [PlusFeature] {
        guard let highlight else { return PlusFeature.allCases }
        return [highlight] + PlusFeature.allCases.filter { $0 != highlight }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AnimusPlusGlyph(size: 34)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Animus+").font(.title2.weight(.bold))
                        PlusBadge()
                    }
                    Text("Less time making cards, more time learning them.")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(features) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: feature.symbol)
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title).font(.headline)
                            Text(feature.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(feature == highlight ? Color.accentColor.opacity(0.08) : .clear))
                }
            }
            }
            .frame(maxHeight: 340)

            Label("Everything in Animus today stays free. Animus+ only adds to it.", systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Text("Coming soon").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 500)
    }
}

/// A button for a Plus feature: does the thing if Animus+ is on, otherwise
/// explains Animus+ (with this feature first). Shows the PLUS badge either way.
struct PlusFeatureButton<Label: View>: View {
    let feature: PlusFeature
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var store = PlusStore.shared
    @State private var explaining = false

    var body: some View {
        Button {
            if store.isUnlocked(feature) { action() } else { explaining = true }
        } label: {
            HStack(spacing: 6) {
                label
                PlusBadge()
            }
        }
        .tip(store.isUnlocked(feature) ? feature.title : "\(feature.title) is part of Animus+")
        .sheet(isPresented: $explaining) { PlusInfoSheet(highlight: feature) }
    }
}

/// Animus Dev only: where an unfinished Plus feature will go.
struct PlusPlaceholderSheet: View {
    let feature: PlusFeature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: feature.symbol).font(.system(size: 40)).foregroundStyle(Color.accentColor)
            HStack(spacing: 8) {
                Text(feature.title).font(.title3.weight(.semibold))
                PlusBadge()
            }
            Text(feature.detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Not built yet. This is where it will open.")
                .font(.caption).foregroundStyle(.tertiary)
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 420)
    }
}
