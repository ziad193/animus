import AppKit
import CryptoKit
import Observation
import SwiftUI

/// Pictures and colour washes behind Home and the study screen.
///
/// Every picture is free to use and share: the paintings are public domain
/// (The Met's Open Access programme, CC0) and the Moon photo is NASA's, which
/// isn't copyrighted. Credits are in Resources/Credits.html.
enum AppBackground: String, CaseIterable, Identifiable {
    case none
    case aurora, sunset, lagoon
    case wave, wheat, andes, oxbow, rockies, earthset

    static let key = "background"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .aurora: "Aurora"
        case .sunset: "Sunset"
        case .lagoon: "Lagoon"
        case .wave: "The Great Wave"
        case .wheat: "Wheat Field"
        case .andes: "The Andes"
        case .oxbow: "The Oxbow"
        case .rockies: "Rocky Mountains"
        case .earthset: "Earthset"
        }
    }

    /// Who made it, shown under the picker.
    var credit: String? {
        switch self {
        case .none, .aurora, .sunset, .lagoon: nil
        case .wave: "Katsushika Hokusai, Under the Wave off Kanagawa, about 1830–32. The Met, public domain."
        case .wheat: "Vincent van Gogh, Wheat Field with Cypresses, 1889. The Met, public domain."
        case .andes: "Frederic Edwin Church, Heart of the Andes, 1859. The Met, public domain."
        case .oxbow: "Thomas Cole, The Oxbow, 1836. The Met, public domain."
        case .rockies: "Albert Bierstadt, The Rocky Mountains, Lander's Peak, 1863. The Met, public domain."
        case .earthset: "Earthset, photographed by the Artemis II crew, April 2026. NASA."
        }
    }

    var isPicture: Bool {
        switch self {
        case .none, .aurora, .sunset, .lagoon: false
        default: true
        }
    }

    static var gradients: [AppBackground] { [.aurora, .sunset, .lagoon] }
    static var pictures: [AppBackground] { allCases.filter(\.isPicture) }

    // MARK: Pictures

    /// The full pictures aren't inside the app: each one downloads the first
    /// time you pick it, and Settings can remove them all to free the space.
    /// The checksum makes sure the file is exactly the one we published.
    var download: (url: URL, sha256: String, bytes: Int)? {
        let base = "https://raw.githubusercontent.com/ziad193/animus/main/Resources/backgrounds/"
        func d(_ sha: String, _ bytes: Int) -> (URL, String, Int) { (URL(string: base + rawValue + ".jpg")!, sha, bytes) }
        switch self {
        case .wave: return d("1fee975eda170ba3a5eef69cae20447ffaca6b6cb96f9b58dd3800b6650f96f6", 2_853_141)
        case .wheat: return d("5ff46fdb21cfa0d004aeaafb836a9feb26a834731be354fb9f6571aeaf3adea5", 5_298_907)
        case .andes: return d("7d0d4846b0abd13d3789c50a3225601214bd1570d18a695e1ec2e457f24fcaea", 2_706_225)
        case .oxbow: return d("5df162b16131e3824d4cada560e2efb405faea920c0a4a415127e16b90a32166", 2_380_846)
        case .rockies: return d("1d6d8bd5f8b1f69360e0b936eacda8163124eaf7ceaea1362b76aa2dfbdd37e1", 1_856_864)
        case .earthset: return d("69eb920eeb20b7c8a3c9a9e62fbfec6606c624492994867be3f6f564b6f3154b", 1_181_840)
        default: return nil
        }
    }

    /// Where a downloaded picture is kept.
    var fileURL: URL { BackgroundStore.folder.appendingPathComponent("\(rawValue).jpg") }

    @MainActor private static var cache: [String: NSImage] = [:]

    /// The full picture (once downloaded), or the small one for the picker
    /// (always there: it comes with the app).
    @MainActor func image(thumbnail: Bool = false) -> NSImage? {
        guard isPicture else { return nil }
        let key = thumbnail ? "\(rawValue)-thumb" : rawValue
        if let hit = Self.cache[key] { return hit }
        let url = thumbnail
            ? Bundle.main.resourceURL?.appendingPathComponent("backgrounds/\(rawValue)-thumb.jpg")
            : fileURL
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        // Keep only the one full-size picture in use; thumbnails are small.
        if !thumbnail { Self.cache = Self.cache.filter { $0.key.hasSuffix("-thumb") } }
        Self.cache[key] = image
        return image
    }

    @MainActor static func forgetFullPictures() {
        cache = cache.filter { $0.key.hasSuffix("-thumb") }
    }

    /// Ready to show right now.
    @MainActor var isReady: Bool {
        !isPicture || FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Offered in the picker (a bare `swift run` has no thumbnails).
    @MainActor var isOffered: Bool { !isPicture || image(thumbnail: true) != nil }
}

/// Downloads and removes the full-size background pictures.
@MainActor
@Observable
final class BackgroundStore {
    static let shared = BackgroundStore()

    /// Pictures being downloaded right now.
    var downloading: Set<AppBackground> = []
    var problem: String?
    /// Bumped when pictures arrive or are removed, so views look again.
    var generation = 0

    /// Shared by every profile. A test copy keeps its own inside the test folder.
    nonisolated static var folder: URL {
        if Library.isTestCollection {
            return URL(fileURLWithPath: ProcessInfo.processInfo.environment["ITERUM_DATA_FOLDER"] ?? "", isDirectory: true)
                .appendingPathComponent("Backgrounds", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Animus/Backgrounds", isDirectory: true)
    }

    /// Space the downloaded pictures take up, in bytes.
    var bytesUsed: Int {
        _ = generation
        return AppBackground.pictures.reduce(0) { total, picture in
            let size = (try? picture.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
    }

    /// Gets the picture if it isn't here yet. Returns whether it's ready.
    func fetch(_ picture: AppBackground) async -> Bool {
        if picture.isReady { return true }
        guard let download = picture.download, !downloading.contains(picture) else { return false }
        downloading.insert(picture)
        defer { downloading.remove(picture) }
        problem = nil
        do {
            var request = URLRequest(url: download.url, timeoutInterval: 60)
            request.setValue("Animus/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            guard data.count == download.bytes, Self.sha256(data) == download.sha256 else {
                problem = "The picture didn't download properly. Please try again."
                return false
            }
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try data.write(to: picture.fileURL, options: .atomic)
            generation += 1
            return true
        } catch {
            problem = "Couldn't download \(picture.title). Are you online?"
            return false
        }
    }

    /// Deletes every downloaded picture. Backgrounds go back to plain until
    /// you pick one again.
    func removeAll() {
        try? FileManager.default.removeItem(at: Self.folder)
        AppBackground.forgetFullPictures()
        generation += 1
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// How the picture is shown.
enum BackgroundStyle: String, CaseIterable, Identifiable {
    /// A banner behind the greeting and today's ring on Home; the rest plain.
    case banner
    /// Behind everything on Home and while studying, with frosted blocks.
    case window

    static let key = "background.style"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .banner: "Banner on Home"
        case .window: "Whole window"
        }
    }
}

/// The banner behind Home's greeting: the picture with a dark wash over it,
/// so the white text on top is easy to read. A clean edge at the bottom.
struct BannerBackdrop: View {
    let background: AppBackground

    var body: some View {
        BackgroundFill(background: background)
            .overlay(LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.6)],
                                    startPoint: .top, endPoint: .bottom))
            .clipped()
            // White text and a light ring on the picture, in light or dark mode.
            .environment(\.colorScheme, .dark)
    }
}

/// Fills its space with the chosen background.
struct BackgroundFill: View {
    let background: AppBackground
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch background {
            case .none:
                Color.clear
            case .aurora, .sunset, .lagoon:
                Wash(background: background, dark: scheme == .dark)
            default:
                if let image = background.image() {
                    Color.clear
                        .overlay {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                        }
                        .clipped()
                        // A little dimmer at night, so it isn't glaring.
                        .overlay(Color.black.opacity(scheme == .dark ? 0.28 : 0))
                } else {
                    Color.clear
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A soft mesh of colour, drawn rather than stored, so it's sharp at any size.
private struct Wash: View {
    let background: AppBackground
    let dark: Bool

    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.42, 0.58], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: colors.map { dark ? $0.mix(with: .black, by: 0.45) : $0 })
    }

    private var colors: [Color] {
        func c(_ hex: UInt32) -> Color {
            Color(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
        }
        switch background {
        case .sunset:
            return [c(0xffb38a), c(0xff8fa3), c(0xc58cf2),
                    c(0xffd29d), c(0xff9f8a), c(0xe08ad8),
                    c(0xffe3b0), c(0xffc29e), c(0xf2a7c8)]
        case .lagoon:
            return [c(0x7fd8d0), c(0x6cc3e8), c(0x5b8def),
                    c(0xa3e7c9), c(0x63c9c7), c(0x6aa5f0),
                    c(0xd2f4d8), c(0x9be1d0), c(0x8cc4f5)]
        default: // aurora
            return [c(0x5c6cf2), c(0x7c5cf2), c(0x31b6c9),
                    c(0x46c9a6), c(0x6a7cf0), c(0x9a6cf0),
                    c(0x2fb59a), c(0x58d0b4), c(0x7f8ff5)]
        }
    }
}

/// True for views drawn over a background picture or wash, so blocks can put
/// frosted glass behind themselves (and only themselves) to stay readable.
private struct OnPictureKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var onPicture: Bool {
        get { self[OnPictureKey.self] }
        set { self[OnPictureKey.self] = newValue }
    }
}

extension View {
    /// Puts the chosen background behind a screen, at full strength. Each block
    /// on the screen frosts its own patch (see `frostedOnPicture`), so the
    /// picture shows in every gap. With no background, nothing changes.
    func screenBackground(plain: some ShapeStyle = Color.clear) -> some View {
        modifier(ScreenBackground(plain: AnyShapeStyle(plain)))
    }

    /// Frosted glass behind this block, only while a background shows.
    func frostedOnPicture(cornerRadius: CGFloat = 16, padding: CGFloat = 0) -> some View {
        modifier(FrostedOnPicture(cornerRadius: cornerRadius, padding: padding))
    }
}

/// A block's own fill: frosted glass over a background, or `plain` without one.
struct BlockFill: View {
    var cornerRadius: CGFloat
    var plain: AnyShapeStyle
    @Environment(\.onPicture) private var onPicture

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(onPicture ? AnyShapeStyle(.regularMaterial) : plain)
    }
}

private struct FrostedOnPicture: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    @Environment(\.onPicture) private var onPicture

    func body(content: Content) -> some View {
        if onPicture {
            content
                .padding(padding)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        } else {
            content
        }
    }
}

private struct ScreenBackground: ViewModifier {
    let plain: AnyShapeStyle
    @AppStorage(AppBackground.key) private var background = AppBackground.none
    @AppStorage(BackgroundStyle.key) private var style = BackgroundStyle.banner
    @State private var store = BackgroundStore.shared

    func body(content: Content) -> some View {
        let _ = store.generation
        // The banner style draws its picture on Home itself; screens stay plain.
        if background == .none || !background.isReady || style == .banner {
            content.background(plain)
        } else {
            content
                .environment(\.onPicture, true)
                .background { BackgroundFill(background: background).ignoresSafeArea() }
        }
    }
}

// MARK: - Picker

/// Settings › General › Background.
struct BackgroundPicker: View {
    @AppStorage(AppBackground.key) private var background = AppBackground.none
    @AppStorage(BackgroundStyle.key) private var style = BackgroundStyle.banner
    @State private var store = BackgroundStore.shared
    @State private var confirmingRemove = false

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 120), spacing: 12)]

    var body: some View {
        let _ = store.generation
        VStack(alignment: .leading, spacing: 8) {
            Text("Background").font(.headline)
            Picker("Show it", selection: $style) {
                ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            Text(style == .banner
                 ? "A banner across the top of Home. Each picture downloads the first time you pick it."
                 : "Behind Home and while you study. Each picture downloads the first time you pick it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(AppBackground.allCases.filter(\.isOffered)) { option in
                    Tile(option: option,
                         selected: background == option && option.isReady,
                         downloading: store.downloading.contains(option)) {
                        choose(option)
                    }
                }
            }
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let credit = background.credit, background.isReady {
                Text(credit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let used = store.bytesUsed
            if used > 0 {
                HStack {
                    Text("Downloaded pictures use \(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Pictures…") { confirmingRemove = true }
                        .tip("Free up the space. You can download them again any time.")
                }
            }
        }
        .confirmationDialog("Remove the downloaded pictures?", isPresented: $confirmingRemove) {
            Button("Remove Pictures", role: .destructive) { store.removeAll() }
        } message: {
            Text("This frees up \(ByteCountFormatter.string(fromByteCount: Int64(store.bytesUsed), countStyle: .file)). Backgrounds that use a picture go back to plain until you pick one again. The colour washes don't need downloading, so they stay.")
        }
    }

    private func choose(_ option: AppBackground) {
        if option.isReady {
            background = option
            return
        }
        Task {
            if await store.fetch(option) { background = option }
        }
    }

    private struct Tile: View {
        let option: AppBackground
        let selected: Bool
        let downloading: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 6) {
                    preview
                        .frame(width: 104, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected ? Color.accentColor : .secondary.opacity(0.3),
                                          lineWidth: selected ? 3 : 1))
                        .overlay(alignment: .bottomTrailing) { badge.padding(5) }
                    Text(option.title)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 104)
                }
            }
            .buttonStyle(.plain)
            .disabled(downloading)
            .hoverLift(scale: 1.03)
            .tip(option.isReady ? (option.credit ?? option.title) : "Download \(option.title) (\(size))")
        }

        private var size: String {
            ByteCountFormatter.string(fromByteCount: Int64(option.download?.bytes ?? 0), countStyle: .file)
        }

        @ViewBuilder private var badge: some View {
            if downloading {
                ProgressView().controlSize(.small)
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
            } else if !option.isReady {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
        }

        @ViewBuilder private var preview: some View {
            if option == .none {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Image(systemName: "nosign").font(.title2).foregroundStyle(.secondary)
                }
            } else if let thumb = option.image(thumbnail: true) {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                BackgroundFill(background: option)
            }
        }
    }
}
