import AppKit
import SwiftUI
import StudyCore
import UniformTypeIdentifiers

/// Make "hide parts of a picture" cards: pick a diagram, drag boxes over the
/// labels, and each box becomes a card that asks you what's underneath.
struct OcclusionEditor: View {
    @Environment(Library.self) private var library
    let deckID: Int64?
    @Binding var tags: String
    let onAdded: (Int) -> Void

    struct Box: Identifiable, Equatable {
        enum Kind: String { case rect, ellipse }
        let id = UUID()
        var kind: Kind
        /// Fractions of the image (0…1).
        var frame: CGRect
        /// Boxes with the same number are asked about together, on one card.
        var card: Int
    }

    enum Tool: String { case rect, ellipse, select }

    @State private var imageURL: URL?
    @State private var image: NSImage?
    @State private var boxes: [Box] = []
    @State private var selected: Set<UUID> = []
    @State private var tool: Tool = .rect
    @AppStorage("occlusion.hideAll") private var hideAll = true
    @State private var drawing: CGRect?
    @State private var moving: (id: UUID, start: CGRect)?
    @State private var header = ""
    @State private var extra = ""
    @State private var error: String?
    @State private var working = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if image == nil {
                picker
            } else {
                toolbar
                canvas
                modePicker
                HStack(alignment: .top, spacing: 14) {
                    field("Title (optional)", "e.g. Bones of the hand", $header)
                    field("Extra info on the back (optional)", "e.g. Mnemonic: Some Lovers Try Positions…", $extra)
                }
                field("Tags (optional)", "e.g. anatomy week1", $tags)
                footer
            }
        }
    }

    // MARK: Choosing the picture

    private var picker: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Choose a diagram, then drag boxes over the parts to hide.")
                .font(.headline)
            Text("Each box becomes a card: it shows the picture with that part covered and asks what's underneath.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button { choose() } label: { Label("Choose Picture…", systemImage: "folder") }
                    .buttonStyle(.borderedProminent)
                    .hoverGlow()
                Button { paste() } label: { Label("Paste Picture", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v", modifiers: .command)
                    .help("Use a screenshot or picture you've copied (⌘V)")
            }
            .controlSize(.large)
            Text("Or drag one in here. Tip: take a screenshot of a lecture slide with ⇧⌘4, holding Control to copy it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(dropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
        .onAppear {
            // For developers: preload a picture when running on a test collection.
            if Library.isTestCollection, let path = ProcessInfo.processInfo.environment["ITERUM_TEST_IMAGE"] {
                load(URL(fileURLWithPath: path))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            return load(url)
        } isTargeted: { dropTargeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a diagram or slide picture"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = load(url)
    }

    private func paste() {
        guard let picture = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let tiff = picture.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            error = "There's no picture copied right now. Copy a screenshot or image first."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("occlusion-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try png.write(to: url)
            _ = load(url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    private func load(_ url: URL) -> Bool {
        guard let picture = NSImage(contentsOf: url), picture.size.width > 0 else {
            error = "That file isn't a picture Iterum can open."
            return false
        }
        imageURL = url
        image = picture
        boxes = []
        selected = []
        error = nil
        return true
    }

    // MARK: Drawing

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Tool", selection: $tool) {
                Label("Box", systemImage: "rectangle").tag(Tool.rect)
                Label("Oval", systemImage: "oval").tag(Tool.ellipse)
                Label("Select", systemImage: "cursorarrow").tag(Tool.select)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Draw boxes or ovals, or select ones you've drawn to move, group or delete them")

            Button { group() } label: { Label("Group", systemImage: "square.on.square") }
                .disabled(selected.count < 2)
                .help("Hide the selected boxes together on one card (e.g. a label and its line)")
            Button { ungroup() } label: { Label("Ungroup", systemImage: "square.split.2x1") }
                .disabled(!selectionIsGrouped)
            Button(role: .destructive) { deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                .disabled(selected.isEmpty)
                .help("Delete the selected boxes")
            Button { if !boxes.isEmpty { boxes.removeLast(); renumber() } } label: {
                Label("Undo Box", systemImage: "arrow.uturn.backward")
            }
            .disabled(boxes.isEmpty)
            Spacer()
            Text(cardCount == 0 ? "Drag over a label to hide it" : "\(cardCount) card\(cardCount == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button { image = nil; imageURL = nil; boxes = [] } label: { Label("Other Picture", systemImage: "photo") }
                .help("Start again with a different picture")
        }
        .buttonStyle(.hoverable)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let area = fitted(in: proxy.size)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: area.width, height: area.height)
                        .offset(x: area.minX, y: area.minY)
                }
                ForEach(boxes) { box in
                    boxView(box, in: area)
                }
                if let drawing {
                    shape(tool == .ellipse ? .ellipse : .rect)
                        .fill(Color.accentColor.opacity(0.35))
                        .overlay(shape(tool == .ellipse ? .ellipse : .rect).stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: drawing.width * area.width, height: drawing.height * area.height)
                        .offset(x: area.minX + drawing.minX * area.width, y: area.minY + drawing.minY * area.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(drawGesture(area))
            .onTapGesture(coordinateSpace: .local) { point in tap(point, area) }
        }
        .frame(minHeight: 320, idealHeight: 460, maxHeight: 620)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func boxView(_ box: Box, in area: CGRect) -> some View {
        let isSelected = selected.contains(box.id)
        return shape(box.kind)
            .fill(Color(red: 1, green: 0.92, blue: 0.75).opacity(0.92))
            .overlay(shape(box.kind).stroke(isSelected ? Color.accentColor : Color(red: 0.85, green: 0.4, blue: 0.3),
                                            lineWidth: isSelected ? 2.5 : 1.5))
            .overlay {
                Text("\(box.card)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color(red: 0.6, green: 0.25, blue: 0.15))
            }
            .frame(width: max(4, box.frame.width * area.width), height: max(4, box.frame.height * area.height))
            .offset(x: area.minX + box.frame.minX * area.width, y: area.minY + box.frame.minY * area.height)
            .allowsHitTesting(false)
    }

    private func shape(_ kind: Box.Kind) -> AnyShape {
        kind == .ellipse ? AnyShape(Ellipse()) : AnyShape(RoundedRectangle(cornerRadius: 3))
    }

    /// Where the picture sits in the canvas (fitted, centred).
    private func fitted(in size: CGSize) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func fraction(_ point: CGPoint, _ area: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - area.minX) / area.width, 0), 1),
                y: min(max((point.y - area.minY) / area.height, 0), 1))
    }

    private func box(at point: CGPoint, _ area: CGRect) -> Box? {
        let p = fraction(point, area)
        return boxes.last { $0.frame.insetBy(dx: -0.005, dy: -0.005).contains(p) }
    }

    private func drawGesture(_ area: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                guard area.width > 0 else { return }
                if tool == .select {
                    // Drag a box to move it.
                    if moving == nil, let hit = box(at: value.startLocation, area) {
                        moving = (hit.id, hit.frame)
                        if !selected.contains(hit.id) { selected = [hit.id] }
                    }
                    guard let moving, let index = boxes.firstIndex(where: { $0.id == moving.id }) else { return }
                    let dx = value.translation.width / area.width, dy = value.translation.height / area.height
                    var frame = moving.start.offsetBy(dx: dx, dy: dy)
                    frame.origin.x = min(max(frame.minX, 0), 1 - frame.width)
                    frame.origin.y = min(max(frame.minY, 0), 1 - frame.height)
                    boxes[index].frame = frame
                    return
                }
                let a = fraction(value.startLocation, area), b = fraction(value.location, area)
                drawing = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            }
            .onEnded { _ in
                moving = nil
                guard let frame = drawing else { return }
                drawing = nil
                guard frame.width > 0.008, frame.height > 0.008 else { return }
                let next = (boxes.map(\.card).max() ?? 0) + 1
                boxes.append(Box(kind: tool == .ellipse ? .ellipse : .rect, frame: frame, card: next))
                selected = []
            }
    }

    private func tap(_ point: CGPoint, _ area: CGRect) {
        guard let hit = box(at: point, area) else {
            selected = []
            return
        }
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if selected.contains(hit.id) { selected.remove(hit.id) } else { selected.insert(hit.id) }
        } else {
            selected = [hit.id]
        }
    }

    // MARK: Groups

    private var cardCount: Int { Set(boxes.map(\.card)).count }

    private var selectionIsGrouped: Bool {
        let cards = boxes.filter { selected.contains($0.id) }.map(\.card)
        return cards.contains { card in boxes.filter { $0.card == card }.count > 1 }
    }

    private func group() {
        let picked = boxes.filter { selected.contains($0.id) }
        guard let number = picked.map(\.card).min() else { return }
        for index in boxes.indices where selected.contains(boxes[index].id) { boxes[index].card = number }
        renumber()
    }

    private func ungroup() {
        var next = (boxes.map(\.card).max() ?? 0) + 1
        var seen = Set<Int>()
        for index in boxes.indices where selected.contains(boxes[index].id) {
            if seen.contains(boxes[index].card) {
                boxes[index].card = next
                next += 1
            } else {
                seen.insert(boxes[index].card)
            }
        }
        renumber()
    }

    private func deleteSelected() {
        boxes.removeAll { selected.contains($0.id) }
        selected = []
        renumber()
    }

    /// Keeps card numbers 1, 2, 3… in the order the boxes were drawn.
    private func renumber() {
        var map: [Int: Int] = [:]
        for index in boxes.indices {
            let old = boxes[index].card
            if map[old] == nil { map[old] = map.count + 1 }
            boxes[index].card = map[old]!
        }
    }

    // MARK: Options and adding

    private var modePicker: some View {
        HStack(spacing: 10) {
            Text("While studying").font(.headline)
            Picker("While studying", selection: $hideAll) {
                Text("Hide all, guess one").tag(true)
                Text("Hide one, guess it").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(hideAll ? "Every label stays covered, so you can't use the others as clues."
                         : "Only the label being asked about is covered.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func field(_ title: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private var footer: some View {
        HStack {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Spacer()
            Button {
                Task { await add() }
            } label: {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Label(cardCount <= 1 ? "Add Card" : "Add \(cardCount) Cards", systemImage: "plus")
                        .padding(.horizontal, 8)
                }
            }
            .buttonStyle(.borderedProminent)
            .hoverGlow()
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(boxes.isEmpty || deckID == nil || working)
            .help("Add (⌘Return)")
        }
    }

    /// Anki's own text format for the boxes.
    nonisolated static func occlusionText(_ boxes: [Box], hideAll: Bool) -> String {
        func number(_ value: CGFloat) -> String {
            var text = String(format: "%.4f", Double(value))
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            if text.hasPrefix("0.") { text.removeFirst() }
            return text.isEmpty ? "0" : text
        }
        return boxes.map { box in
            let f = box.frame
            return "{{c\(box.card)::image-occlusion:\(box.kind.rawValue):left=\(number(f.minX)):top=\(number(f.minY))"
                + ":width=\(number(f.width)):height=\(number(f.height)):oi=\(hideAll ? 1 : 0)}}"
        }
        .joined(separator: "<br>")
    }

    private func add() async {
        guard let engine = library.engine, let deckID, let imageURL, !boxes.isEmpty else { return }
        working = true
        defer { working = false }
        let tagList = tags.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        do {
            try await engine.addOcclusion(deck: deckID, image: imageURL,
                                          occlusions: Self.occlusionText(boxes, hideAll: hideAll),
                                          header: header, backExtra: extra, tags: tagList)
            RecentDecks.use(deckID)
            let count = cardCount
            image = nil
            self.imageURL = nil
            boxes = []
            header = ""
            extra = ""
            error = nil
            onAdded(count)
            await library.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
