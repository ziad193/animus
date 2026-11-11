import SwiftUI
import StudyCore

// The study screen's look, shared by the Mac app and the iPhone/iPad app:
// the counts along the top, the glass pane behind the card (with its glow in
// the answer's colour) and the notification bubble.

struct CountsBar: View {
    let counts: StudyState.Counts?
    /// The card on screen: "new", "learning", "relearning" or "review". Its
    /// count is ringed, so you can see what kind of card it is.
    var current: String? = nil
    /// Just the dots and numbers, for when there's no room for the words.
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            item(counts?.new, "New", Palette.new, on: current == "new")
            item(counts?.learn, "Learning", Palette.learning, on: current == "learning" || current == "relearning")
            item(counts?.review, "Due", Palette.review, on: current == "review")
        }
        .font(.callout.monospacedDigit())
        .animation(.easeOut(duration: 0.2), value: current)
    }

    private func item(_ value: Int?, _ label: String, _ color: Color, on: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(value.map(String.init) ?? "–").bold()
                .contentTransition(.numericText())
            if !compact { Text(label).foregroundStyle(on ? .primary : .secondary) }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(on ? 0.16 : 0)))
        .overlay(Capsule().strokeBorder(color.opacity(on ? 0.35 : 0), lineWidth: 0.5))
        .tip(on ? "The card on screen is \(label == "Due" ? "a review" : label.lowercased())" : "\(label) cards left today")
    }
}


/// The box behind the card: solid normally, and thick frosted glass (like a
/// window pane) over a background picture, so the picture still shows through.
struct CardPane: View {
    /// The colour to glow in: the answer you gave, or the one you're hovering.
    var glow: Color?
    /// 1 for the flash after answering, about half for the hover preview.
    var strength: Double = 1
    /// How frosted the glass is over a picture; `.none` is no pane at all.
    var style = CardPaneStyle.frosted
    @Environment(\.onPicture) private var onPicture

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if style == .none {
            // Nothing to see, except the answer's colour as a soft bloom
            // behind the words (it has no pane to spill out from).
            shape
                .fill(glow ?? .clear)
                .padding(40)
                .blur(radius: 70)
                .opacity(glow == nil ? 0 : 0.3 * strength)
        } else {
            pane(shape)
        }
    }

    private var glass: AnyShapeStyle {
        switch style {
        case .lighter: AnyShapeStyle(.regularMaterial)
        case .lightest: AnyShapeStyle(.ultraThinMaterial)
        default: AnyShapeStyle(.thickMaterial)
        }
    }

    private func pane(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(onPicture ? glass : AnyShapeStyle(.background))
            .overlay(shape.strokeBorder(.white.opacity(onPicture ? 0.18 : 0)))
            .shadow(color: .black.opacity(onPicture ? 0.28 : 0.08), radius: onPicture ? 24 : 12, y: 6)
            // The glow sits behind the pane: a coloured halo spilling out
            // around its edges, while the glass itself stays clear.
            .background {
                shape
                    .fill(glow ?? .clear)
                    .padding(-4)
                    .blur(radius: 26)
                    .opacity(glow == nil ? 0 : 0.9 * strength)
                    // Cut out where the pane is, so the frosted glass (which is
                    // see-through) isn't tinted: the colour only shows outside it.
                    .mask {
                        Rectangle()
                            .padding(-120)
                            .overlay(shape.blendMode(.destinationOut))
                            .compositingGroup()
                    }
            }
    }
}

/// One answer, so the study screen can flash in its colour.
struct AnswerPulse: Equatable {
    let rating: Rating
    let id: Int
}

/// What a study action just did, shown briefly as a notification bubble.
struct StudyNotice: Equatable {
    let id = UUID()
    let symbol: String
    let color: Color
    let title: String
    let detail: String?
}

/// A notification-style bubble: a coloured icon, what happened, and a short
/// line saying what it means. Slides down from the top, then goes by itself.
struct NoticeBubble: View {
    let notice: StudyNotice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(notice.color.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: 460, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}

/// The flag and the marked star in the card's top corner.
struct CardBadges: View {
    let flag: Int
    let marked: Bool

    var body: some View {
        HStack(spacing: 6) {
            if flag > 0, let colour = FlagColor.all[safe: flag - 1] {
                Image(systemName: "flag.fill")
                    .foregroundStyle(colour.color)
                    .padding(6)
                    .background(Circle().fill(colour.color.opacity(0.16)))
                    .tip("Flagged \(colour.name.lowercased())")
            }
            if marked {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .padding(6)
                    .background(Circle().fill(Color.yellow.opacity(0.16)))
                    .tip("Marked")
            }
        }
        .font(.caption.weight(.medium))
        .animation(.easeOut(duration: 0.2), value: flag)
        .animation(.easeOut(duration: 0.2), value: marked)
    }
}
