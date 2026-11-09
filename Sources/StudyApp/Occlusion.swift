#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import StudyCore

/// An image occlusion card, ready to draw natively: one picture, and boxes
/// over it. Positions are fractions of the image (0…1), so they work at any size.
struct OcclusionCard: Equatable {
    struct Shape: Equatable {
        enum Kind: Equatable { case rect, ellipse, polygon([CGPoint]) }
        var kind: Kind
        /// Bounding box, as fractions of the image.
        var frame: CGRect
        /// The box being asked about on this card.
        var isTarget: Bool
    }

    var image: URL
    var header: String
    var extra: String
    var questionShapes: [Shape]
    var answerShapes: [Shape]

    var targets: [Shape] { questionShapes.filter(\.isTarget) }

    /// Returns nil if this isn't an occlusion card we can draw, so the
    /// normal web view shows it instead.
    init?(_ data: OcclusionFields, media: URL) {
        guard let imageName = Self.imageName(in: data.fields["Image"] ?? "") else { return nil }
        image = media.appendingPathComponent(imageName)
        guard FileManager.default.fileExists(atPath: image.path) else { return nil }

        switch data.kind {
        case "enhanced":
            header = Self.plainText(data.fields["Header"] ?? "")
            extra = ["Footer", "Remarks", "Sources", "Extra 1", "Extra 2"]
                .compactMap { data.fields[$0].map(Self.plainText) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard let qName = Self.imageName(in: data.fields["Question Mask"] ?? ""),
                  let q = MaskSVG.parse(media.appendingPathComponent(qName)) else { return nil }
            questionShapes = q
            if let aName = Self.imageName(in: data.fields["Answer Mask"] ?? ""),
               let a = MaskSVG.parse(media.appendingPathComponent(aName)) {
                answerShapes = a.filter { !$0.isTarget }
            } else {
                answerShapes = q.filter { !$0.isTarget }
            }
        case "builtin":
            header = Self.plainText(data.fields["Header"] ?? "")
            extra = Self.plainText(data.fields["Back Extra"] ?? "")
            let all = Self.builtinShapes(data.fields["Occlusion"] ?? "", ordinal: data.ordinal)
            questionShapes = all.shapes
            answerShapes = all.shapes.filter { !$0.isTarget && all.hideOthers }
            if !all.hideOthers {
                questionShapes = all.shapes.filter(\.isTarget)
            }
        default:
            return nil
        }
        guard questionShapes.contains(where: \.isTarget) else { return nil }
    }

    // MARK: Parsing helpers

    private static func imageName(in html: String) -> String? {
        guard let range = html.range(of: #"src\s*=\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let match = html[range]
        guard let start = match.firstIndex(of: "\""), let end = match.lastIndex(of: "\""), start < end else { return nil }
        let name = String(match[match.index(after: start)..<end])
        return name.removingPercentEncoding ?? name
    }

    static func plainText(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: #"<br\s*/?>|</div>|</p>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Anki's own format: `{{c1::image-occlusion:rect:left=.1:top=.2:width=.3:height=.1:oi=1}}`.
    private static func builtinShapes(_ text: String, ordinal: Int) -> (shapes: [Shape], hideOthers: Bool) {
        let pattern = #"\{\{c(\d+)::image-occlusion:(\w+):([^}]*)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([], true) }
        var shapes: [Shape] = []
        var hideOthers = true
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let number = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let kindName = ns.substring(with: match.range(at: 2))
            var props: [String: String] = [:]
            for part in ns.substring(with: match.range(at: 3)).split(separator: ":") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { props[pair[0]] = pair[1] }
            }
            if props["oi"] == "0" { hideOthers = false }
            let value = { (key: String) in CGFloat(Double(props[key] ?? "") ?? 0) }
            let isTarget = number == ordinal
            switch kindName {
            case "rect", "ellipse":
                let frame = CGRect(x: value("left"), y: value("top"), width: value("width"), height: value("height"))
                shapes.append(Shape(kind: kindName == "rect" ? .rect : .ellipse, frame: frame, isTarget: isTarget))
            case "polygon":
                let points = (props["points"] ?? "").split(separator: " ").compactMap { pair -> CGPoint? in
                    let xy = pair.split(separator: ",").compactMap { Double($0) }
                    return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
                }
                guard !points.isEmpty else { continue }
                shapes.append(Shape(kind: .polygon(points), frame: boundingBox(points), isTarget: isTarget))
            default:
                continue
            }
        }
        return (shapes, hideOthers)
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Reads the mask drawings made by the Image Occlusion Enhanced add-on.
/// Shapes marked `qshape` (on themselves or a parent group) are the ones being asked.
private final class MaskSVG: NSObject, XMLParserDelegate {
    private var size = CGSize(width: 1, height: 1)
    private var groupTargets: [Bool] = []
    private var shapes: [OcclusionCard.Shape] = []

    static func parse(_ url: URL) -> [OcclusionCard.Shape]? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        let delegate = MaskSVG()
        parser.delegate = delegate
        guard parser.parse(), !delegate.shapes.isEmpty else { return nil }
        return delegate.shapes
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        let number = { (key: String) in CGFloat(Double(a[key] ?? "") ?? 0) }
        let marked = (a["class"] ?? "").contains("qshape")
        let target = marked || groupTargets.contains(true)
        let w = max(size.width, 1), h = max(size.height, 1)

        switch name {
        case "svg":
            size = CGSize(width: number("width"), height: number("height"))
        case "g":
            groupTargets.append(marked)
        case "rect":
            let box = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            if let (angle, centre) = Self.rotation(a["transform"]) {
                // A rotated box becomes a four-cornered polygon.
                let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                               CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
                let points = corners.map { p -> CGPoint in
                    let dx = p.x - centre.x, dy = p.y - centre.y
                    let x = centre.x + dx * cos(angle) - dy * sin(angle)
                    let y = centre.y + dx * sin(angle) + dy * cos(angle)
                    return CGPoint(x: x / w, y: y / h)
                }
                shapes.append(.init(kind: .polygon(points), frame: OcclusionCard.boundingBox(points), isTarget: target))
            } else {
                let frame = CGRect(x: box.minX / w, y: box.minY / h, width: box.width / w, height: box.height / h)
                shapes.append(.init(kind: .rect, frame: frame, isTarget: target))
            }
        case "ellipse", "circle":
            let rx = a["rx"] != nil ? number("rx") : number("r")
            let ry = a["ry"] != nil ? number("ry") : number("r")
            let frame = CGRect(x: (number("cx") - rx) / w, y: (number("cy") - ry) / h,
                               width: 2 * rx / w, height: 2 * ry / h)
            shapes.append(.init(kind: .ellipse, frame: frame, isTarget: target))
        case "polygon":
            let values = (a["points"] ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            var points: [CGPoint] = []
            var i = 0
            while i + 1 < values.count {
                points.append(CGPoint(x: values[i] / w, y: values[i + 1] / h))
                i += 2
            }
            guard !points.isEmpty else { return }
            shapes.append(.init(kind: .polygon(points), frame: OcclusionCard.boundingBox(points), isTarget: target))
        default:
            break
        }
    }

    /// Reads `rotate(angle cx,cy)`; returns the angle in radians and the pivot.
    private static func rotation(_ transform: String?) -> (CGFloat, CGPoint)? {
        guard let transform, let open = transform.range(of: "rotate("),
              let close = transform[open.upperBound...].firstIndex(of: ")") else { return nil }
        let numbers = transform[open.upperBound..<close]
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }
        guard let degrees = numbers.first else { return nil }
        let pivot = numbers.count >= 3 ? CGPoint(x: numbers[1], y: numbers[2]) : .zero
        return (CGFloat(degrees) * .pi / 180, pivot)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "g", !groupTargets.isEmpty { groupTargets.removeLast() }
    }
}

// MARK: - The view

/// Draws an occlusion card with native shapes. On the question, the box to
/// guess glows in the accent colour; on the answer, it lifts away and
/// leaves an outline around the revealed label.
struct OcclusionCardView: View {
    let card: OcclusionCard
    let showingAnswer: Bool
    let accent: Color

    @State private var image: Image?
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 14) {
            if !card.header.isEmpty {
                Text(card.header)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            if let image {
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .overlay { GeometryReader { geo in shapes(in: geo.size) } }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showingAnswer, !card.extra.isEmpty {
                Text(card.extra)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(24)
        .animation(.spring(duration: 0.35), value: showingAnswer)
        .task(id: card.image) {
            let url = card.image
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            image = data.flatMap(Image.init(pictureData:))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private func shapes(in size: CGSize) -> some View {
        let others = showingAnswer ? card.answerShapes : card.questionShapes.filter { !$0.isTarget }
        ZStack {
            ForEach(Array(others.enumerated()), id: \.offset) { _, shape in
                path(shape, in: size)
                    // Fully solid: a see-through box would give the hidden label away.
                    .fill(Color(white: 0.55))
                    .overlay(path(shape, in: size).stroke(Color(white: 0.35), lineWidth: 1))
            }
            ForEach(Array(card.targets.enumerated()), id: \.offset) { _, shape in
                ZStack {
                    path(shape, in: size)
                        .fill(accent.opacity(showingAnswer ? 0 : 1))
                    path(shape, in: size)
                        .stroke(accent, lineWidth: showingAnswer ? 3 : 1.5)
                        .shadow(color: accent.opacity(showingAnswer ? 0.8 : (pulse ? 0.7 : 0.15)), radius: 6)
                    if !showingAnswer {
                        Text("?")
                            .font(.system(size: min(28, max(12, shape.frame.height * size.height * 0.6)), weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .position(x: shape.frame.midX * size.width, y: shape.frame.midY * size.height)
                    }
                }
                .scaleEffect(showingAnswer ? 1.04 : 1,
                             anchor: UnitPoint(x: shape.frame.midX, y: shape.frame.midY))
            }
        }
    }

    private func path(_ shape: OcclusionCard.Shape, in size: CGSize) -> Path {
        let rect = CGRect(x: shape.frame.minX * size.width, y: shape.frame.minY * size.height,
                          width: shape.frame.width * size.width, height: shape.frame.height * size.height)
        switch shape.kind {
        case .rect:
            return Path(roundedRect: rect, cornerRadius: 4)
        case .ellipse:
            return Path(ellipseIn: rect)
        case .polygon(let points):
            var path = Path()
            path.addLines(points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
            path.closeSubpath()
            return path
        }
    }
}

extension Image {
    /// A picture from file data, on Mac, iPhone and iPad.
    init?(pictureData data: Data) {
        #if os(macOS)
        guard let picture = NSImage(data: data) else { return nil }
        self.init(nsImage: picture)
        #else
        guard let picture = UIImage(data: data) else { return nil }
        self.init(uiImage: picture)
        #endif
    }
}
