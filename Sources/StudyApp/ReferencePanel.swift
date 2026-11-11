import AppKit
import Observation
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// A side panel for lecture slides and notes while you study or add cards.
///
/// - PDFs use Apple's PDFKit: page buttons, zoom, and search with a match count.
/// - PowerPoint, Keynote and Word files show their pages through macOS Quick
///   Look (no Office needed). PowerPoint and Word also have a Text view you
///   can search, and select from to copy into cards.
///
/// Each deck keeps its own files, shown as tabs along the top.
struct ReferencePanel: View {
    let deckID: Int64
    let onClose: () -> Void

    @State private var files: [URL] = []
    @State private var current: URL?
    @State private var dropTargeted = false
    @State private var attaching = false

    static let fileTypes: [UTType] = ReferenceStore.extensions.compactMap { UTType(filenameExtension: $0) }
        + [.pdf, .presentation, .rtf, .plainText]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                if let current {
                    DocumentView(url: current, deckID: deckID)
                        .id(current)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                }
                if attaching { ProgressView("Adding…") }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let usable = urls.filter(ReferenceStore.isSupported)
                guard !usable.isEmpty else { return false }
                Task { await attach(usable) }
                return true
            } isTargeted: { dropTargeted = $0 }
        }
        .background(.background)
        // Reload whenever the deck changes (e.g. picking another deck in Add Cards).
        .task(id: deckID) {
            load()
            if await ReferenceStore.adoptOutsideFiles(for: deckID) { load() }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 6) {
            if files.isEmpty {
                // Nothing attached yet: just the button, so a narrow panel has room for it on one line.
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(files, id: \.self) { file in
                            FileTab(url: file, selected: file == current) {
                                show(file)
                            } remove: {
                                remove(file)
                            }
                        }
                    }
                }
            }
            Button(action: choose) {
                Label("Add File", systemImage: "plus")
                    .lineLimit(1)
                    .fixedSize()
            }
            .tip("Attach a PDF, PowerPoint or Word file to this deck")
            Button(action: onClose) {
                Image(systemName: "sidebar.right")
            }
            .tip("Hide this panel")
        }
        .buttonStyle(.hoverable)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Keep your slides beside your cards")
                .font(.headline)
            Text("Drop a PDF, PowerPoint or Word file here, or click Add File.\nIt stays attached to this deck, and you can add several.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    // MARK: Logic

    private func load() {
        files = ReferenceStore.files(for: deckID)
        let last = ReferenceStore.lastShown(for: deckID)
        current = files.first { $0.path == last } ?? files.last
    }

    private func show(_ file: URL) {
        current = file
        ReferenceStore.setLastShown(file, for: deckID)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.fileTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose lecture slides or notes to keep beside your cards"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await attach(urls) }
        }
    }

    private func attach(_ urls: [URL]) async {
        attaching = true
        defer { attaching = false }
        var last: URL?
        for url in urls {
            last = await ReferenceStore.attach(url, to: deckID)
        }
        files = ReferenceStore.files(for: deckID)
        if let last { show(last) }
    }

    private func remove(_ file: URL) {
        ReferenceStore.detach(file, from: deckID)
        files = ReferenceStore.files(for: deckID)
        if current == file { current = files.last }
    }
}

/// One attached file along the top of the panel.
private struct FileTab: View {
    let url: URL
    let selected: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: DocumentKind(url).symbol)
                .foregroundStyle(DocumentKind(url).color)
            Text(url.deletingPathExtension().lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverable)
            .opacity(hovering || selected ? 1 : 0)
            .tip("Remove from this deck (the original file isn't touched)")
        }
        .font(.callout.weight(selected ? .semibold : .regular))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.primary.opacity(0.1) : hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .tip(url.lastPathComponent)
    }
}

enum DocumentKind {
    case pdf, slides, word, text

    init(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "pptx", "ppt", "key": self = .slides
        case "docx", "doc": self = .word
        default: self = .text
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .slides: "rectangle.on.rectangle.angled.fill"
        case .word: "doc.text.fill"
        case .text: "doc.plaintext.fill"
        }
    }

    var color: Color {
        switch self {
        case .pdf: .red
        case .slides: .orange
        case .word: .blue
        case .text: .gray
        }
    }
}

// MARK: - One document

/// Picks the right reader for the file and shows its controls.
private struct DocumentView: View {
    let url: URL
    /// The deck cards made from these slides go into.
    let deckID: Int64
    @State private var plus = PlusStore.shared
    /// Animus+: dragging out an area of the slide to make cards from.
    @State private var capturing = false
    @State private var captured: CapturedPicture?

    struct CapturedPicture: Identifiable {
        let id = UUID()
        let image: NSImage
    }

    enum Mode: String { case pages, text }
    @State private var mode: Mode = .pages
    @State private var pdf = PDFController()
    @State private var text = TextController()
    @State private var query = ""

    private var kind: DocumentKind { DocumentKind(url) }
    private var hasPages: Bool { kind != .text }
    private var hasText: Bool { kind != .pdf && OfficeText.canExtract(url) }
    private var showingText: Bool { kind == .text || (hasText && mode == .text) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if kind == .pdf {
                PDFReader(url: url, controller: pdf)
                    .overlay {
                        if capturing {
                            CaptureOverlay(cancel: { capturing = false }) { rect in
                                capturing = false
                                if let image = pdf.capture(rect) { captured = CapturedPicture(image: image) }
                            }
                        }
                    }
            } else if showingText {
                TextReader(url: url, controller: text)
            } else {
                // Quick Look takes a moment on big files; show that it's working.
                ZStack {
                    ProgressView("Opening \(url.lastPathComponent)…")
                        .controlSize(.small)
                    QuickLookReader(url: url)
                }
            }
        }
        .onChange(of: query) { runSearch() }
        .onChange(of: mode) { query = "" }
        .sheet(item: $captured) { SlideCaptureSheet(picture: $0.image, deckID: deckID) }
    }

    /// Animus+ (Animus Dev only until the AI is connected): make cards from the
    /// slide you're on, or from an area you drag out.
    @ViewBuilder private var captureButtons: some View {
        if kind == .pdf, plus.showsPreviews, plus.showsPrompts {
            Divider().frame(height: 16)
            PlusFeatureButton(feature: .lectureToCards) {
                if let image = pdf.currentPagePicture() { captured = CapturedPicture(image: image) }
            } label: {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
            }
            .tip("Cards from this slide (Animus+)")
            PlusFeatureButton(feature: .lectureToCards) {
                capturing.toggle()
            } label: {
                Image(systemName: capturing ? "xmark.square" : "viewfinder")
            }
            .tip(capturing ? "Stop capturing" : "Capture an area of the slide to make cards from (Animus+)")
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if hasText && hasPages {
                Picker("View", selection: $mode) {
                    Text("Pages").tag(Mode.pages)
                    Text("Text").tag(Mode.text)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .tip("Pages shows the file as it looks. Text lets you search and copy.")
            }
            if kind == .pdf || showingText {
                SearchBox(query: $query,
                          status: kind == .pdf ? pdf.searchStatus : text.searchStatus,
                          previous: { kind == .pdf ? pdf.step(-1) : text.step(-1) },
                          next: { kind == .pdf ? pdf.step(1) : text.step(1) })
            } else {
                Text(hasText ? "Switch to Text to search or copy" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if kind == .pdf, pdf.pageCount > 0 {
                Button { pdf.goPage(-1) } label: { Image(systemName: "chevron.up") }
                    .tip("Previous page")
                    .disabled(pdf.page <= 1)
                Text("\(pdf.page) / \(pdf.pageCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { pdf.goPage(1) } label: { Image(systemName: "chevron.down") }
                    .tip("Next page")
                    .disabled(pdf.page >= pdf.pageCount)
            }
            if kind == .pdf || showingText {
                Divider().frame(height: 16)
                Button { zoom(1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .tip("Zoom out")
                Button { kind == .pdf ? pdf.fit() : text.fit() } label: { Image(systemName: "arrow.left.and.right") }
                    .tip("Fit to width")
                Button { zoom(1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .tip("Zoom in")
            }
            captureButtons
            if kind != .pdf {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .tip("Open in \(kind == .slides ? "PowerPoint or Keynote" : "Word or Pages")")
            }
        }
        .buttonStyle(.hoverable)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func zoom(_ factor: CGFloat) {
        if kind == .pdf { pdf.zoom(by: factor) } else { text.zoom(by: factor) }
    }

    private func runSearch() {
        if kind == .pdf { pdf.find(query) } else { text.find(query) }
    }
}

/// Search field with "3 of 12" and previous / next buttons. Return goes to the next match.
private struct SearchBox: View {
    @Binding var query: String
    let status: String
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(next)
                if !status.isEmpty {
                    Text(status)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(status == "No matches" ? .orange : .secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(minWidth: 120, idealWidth: 200, maxWidth: 240)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Button(action: previous) { Image(systemName: "chevron.left") }
                .tip("Previous match")
                .disabled(query.isEmpty)
            Button(action: next) { Image(systemName: "chevron.right") }
                .tip("Next match (Return)")
                .disabled(query.isEmpty)
        }
    }
}

// MARK: - PDF

/// Connects the panel's buttons to the PDF view, and reports page and search state.
@MainActor
@Observable
final class PDFController {
    @ObservationIgnored weak var view: PDFView?
    @ObservationIgnored var url: URL?
    private(set) var page = 0
    private(set) var pageCount = 0
    private(set) var searchStatus = ""

    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var pageObserver: NSObjectProtocol?

    func attach(_ view: PDFView, url: URL) {
        self.view = view
        self.url = url
        matches = []
        searchStatus = ""
        pageCount = view.document?.pageCount ?? 0
        // Reopen where you left off.
        let saved = ReferenceStore.page(for: url)
        if saved > 0, let document = view.document, saved < document.pageCount, let target = document.page(at: saved) {
            view.go(to: target)
        }
        updatePage()
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePage() }
        }
    }

    private func updatePage() {
        guard let view, let document = view.document, let current = view.currentPage else { return }
        let number = document.index(for: current)
        page = number + 1
        if let url { ReferenceStore.setPage(number, for: url) }
    }

    func goPage(_ step: Int) {
        guard let view else { return }
        step > 0 ? view.goToNextPage(nil) : view.goToPreviousPage(nil)
    }

    func zoom(by factor: CGFloat) {
        guard let view else { return }
        view.autoScales = false
        view.scaleFactor = min(max(view.scaleFactor * factor, view.minScaleFactor), view.maxScaleFactor)
    }

    func fit() {
        view?.autoScales = true
    }

    /// The slide you're on, as a picture (at double size, so small text reads).
    func currentPagePicture() -> NSImage? {
        guard let page = view?.currentPage else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        return page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
    }

    /// Exactly what's on screen inside `rect` (in the reader's own coordinates,
    /// measured from the top left), as a picture.
    func capture(_ rect: CGRect) -> NSImage? {
        guard let view, rect.width > 4, rect.height > 4 else { return nil }
        let area = CGRect(x: rect.minX, y: view.isFlipped ? rect.minY : view.bounds.height - rect.maxY,
                          width: rect.width, height: rect.height)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: area) else { return nil }
        view.cacheDisplay(in: area, to: rep)
        let image = NSImage(size: area.size)
        image.addRepresentation(rep)
        return image
    }

    /// Highlights every match and jumps to the first.
    func find(_ text: String) {
        guard let view, let document = view.document else { return }
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            matches = []
            view.highlightedSelections = nil
            view.clearSelection()
            searchStatus = ""
            return
        }
        matches = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for match in matches { match.color = .systemYellow.withAlphaComponent(0.5) }
        view.highlightedSelections = matches
        index = 0
        show()
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        index = (index + delta + matches.count) % matches.count
        show()
    }

    private func show() {
        guard let view else { return }
        guard !matches.isEmpty else {
            searchStatus = "No matches"
            return
        }
        searchStatus = "\(index + 1) of \(matches.count)"
        let match = matches[index]
        view.setCurrentSelection(match, animate: false)
        view.go(to: match)
    }
}

private struct PDFReader: NSViewRepresentable {
    let url: URL
    let controller: PDFController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.document = PDFDocument(url: url)
        controller.attach(view, url: url)
        return view
    }

    // A new file gets a brand-new view (the panel uses .id(url)), so the
    // old document's search results can never leak into a new one.
    func updateNSView(_ view: PDFView, context: Context) {}
}

// MARK: - Pages of PowerPoint, Keynote, Word

/// macOS Quick Look: the same previewer as pressing Space in Finder.
private struct QuickLookReader: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {}

    /// Let go of the file when the view goes away, so old previews don't linger.
    /// (Calling close() here crashes Quick Look if the preview is still loading.)
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
    }
}

// MARK: - Text of Word and PowerPoint files

@MainActor
@Observable
final class TextController {
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored weak var scrollView: NSScrollView?
    private(set) var searchStatus = ""
    @ObservationIgnored private var matches: [NSRange] = []
    @ObservationIgnored private var index = 0

    func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        scrollView.magnification = min(max(scrollView.magnification * factor, 0.5), 4)
    }

    func fit() {
        scrollView?.magnification = 1
    }

    func find(_ text: String) {
        guard let textView, let layout = textView.layoutManager else { return }
        let whole = NSRange(location: 0, length: textView.string.utf16.count)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        matches = []
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchStatus = ""
            return
        }
        let string = textView.string as NSString
        var range = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
            guard found.location != NSNotFound else { break }
            matches.append(found)
            let next = found.location + max(found.length, 1)
            range = NSRange(location: next, length: string.length - next)
        }
        for match in matches {
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), forCharacterRange: match)
        }
        index = 0
        show()
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        index = (index + delta + matches.count) % matches.count
        show()
    }

    private func show() {
        guard let textView else { return }
        guard !matches.isEmpty else {
            searchStatus = "No matches"
            return
        }
        searchStatus = "\(index + 1) of \(matches.count)"
        textView.setSelectedRange(matches[index])
        textView.scrollRangeToVisible(matches[index])
        textView.showFindIndicator(for: matches[index])
    }
}

/// Read-only, selectable text on a white "page", so you can copy lines into cards.
private struct TextReader: NSViewRepresentable {
    let url: URL
    let controller: TextController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.allowsMagnification = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = .white
        text.textContainerInset = NSSize(width: 22, height: 20)
        text.string = "Reading…"
        text.textColor = .gray
        controller.textView = text
        controller.scrollView = scroll

        let url = url
        Task.detached {
            // Made here and only read afterwards, so handing it over is safe.
            nonisolated(unsafe) let content = OfficeText.extract(url)
            await MainActor.run {
                if let content, content.length > 0 {
                    text.textStorage?.setAttributedString(Self.readable(content))
                } else {
                    text.string = "This file has no text that could be read. Try the Pages view."
                    text.textColor = .gray
                }
            }
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    /// Word files sometimes set white or very light text; keep it readable on the white page.
    private static func readable(_ content: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: content)
        let whole = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            let color = (value as? NSColor)?.usingColorSpace(.deviceRGB)
            if color == nil || (color!.brightnessComponent > 0.85 && color!.saturationComponent < 0.2) {
                copy.addAttribute(.foregroundColor, value: NSColor.black, range: range)
            }
        }
        return copy
    }
}

// MARK: - Capturing part of a slide (Animus+)

/// Dims the slide; drag a box over the part you want cards from.
private struct CaptureOverlay: View {
    let cancel: () -> Void
    let done: (CGRect) -> Void
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var box: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .overlay {
                    if let box {
                        Rectangle()
                            .frame(width: box.width, height: box.height)
                            .position(x: box.midX, y: box.midY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            if let box {
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
            }
            HStack(spacing: 10) {
                Image(systemName: "viewfinder")
                Text("Drag over the part of the slide to make cards from")
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.regularMaterial))
            .padding(.top, 12)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { value in
                    if start == nil { start = value.startLocation }
                    current = value.location
                }
                .onEnded { _ in
                    if let box { done(box) }
                    start = nil
                    current = nil
                }
        )
        .onHover { inside in inside ? NSCursor.crosshair.push() : NSCursor.pop() }
    }
}
