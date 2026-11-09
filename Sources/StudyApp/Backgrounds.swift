#if os(macOS)
import AppKit
/// NSImage on Mac, UIImage on iPhone and iPad.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif
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
    // Art
    case wave, wheat, andes, oxbow, rockies
    case ninthWave, yosemiteSunrise, cairnSnow, wheatstacks, sainteAdresse, turnerSunrise, friedrichSummer, waterLilies
    // Space
    case earthset, orbitSunset, devilsTower, cosmicCliffs, saturn, joshuaTree, queenValley
    // Nature
    case tetons, tetonsCloud, capeRoyal, vishnuTemple, lavaSea, oolahValley

    static let key = "background"
    var id: String { rawValue }

    /// The sections of the picker.
    enum Group: String, CaseIterable, Identifiable {
        case colours, art, space, nature
        var id: String { rawValue }
        var title: String {
            switch self {
            case .colours: "Colours"
            case .art: "Art"
            case .space: "Space and night skies"
            case .nature: "Nature"
            }
        }
    }

    var group: Group {
        switch self {
        case .none, .aurora, .sunset, .lagoon: .colours
        case .earthset, .orbitSunset, .devilsTower, .cosmicCliffs, .saturn, .joshuaTree, .queenValley: .space
        case .tetons, .tetonsCloud, .capeRoyal, .vishnuTemple, .lavaSea, .oolahValley: .nature
        default: .art
        }
    }

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
        case .ninthWave: "The Ninth Wave"
        case .yosemiteSunrise: "Yosemite Sunrise"
        case .cairnSnow: "Cairn in Snow"
        case .wheatstacks: "Wheatstacks"
        case .sainteAdresse: "Sainte-Adresse"
        case .turnerSunrise: "Rising Sun"
        case .friedrichSummer: "Summer"
        case .waterLilies: "Water Lilies"
        case .earthset: "Earthset"
        case .orbitSunset: "Orbit Sunset"
        case .devilsTower: "Devils Tower"
        case .cosmicCliffs: "Cosmic Cliffs"
        case .saturn: "Saturn"
        case .joshuaTree: "Joshua Tree"
        case .queenValley: "Queen Valley"
        case .tetons: "The Tetons"
        case .tetonsCloud: "Teton Clouds"
        case .capeRoyal: "Cape Royal"
        case .vishnuTemple: "Vishnu Temple"
        case .lavaSea: "Lava and Sea"
        case .oolahValley: "Oolah Valley"
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
        case .ninthWave: "Ivan Aivazovsky, The Ninth Wave, 1850. State Russian Museum, public domain."
        case .yosemiteSunrise: "Albert Bierstadt, Sunrise, Yosemite Valley, about 1870. Public domain."
        case .cairnSnow: "Caspar David Friedrich, Cairn in Snow, 1807. Public domain."
        case .wheatstacks: "Claude Monet, Stacks of Wheat (Sunset, Snow Effect), 1890–91. Art Institute of Chicago, public domain."
        case .sainteAdresse: "Claude Monet, The Beach at Sainte-Adresse, 1867. Art Institute of Chicago, public domain."
        case .turnerSunrise: "J. M. W. Turner, Sun Rising through Vapour, 1807. Public domain."
        case .friedrichSummer: "Caspar David Friedrich, Summer, 1807. Public domain."
        case .waterLilies: "Claude Monet, Water Lilies, 1919. The Met, public domain."
        case .earthset: "Earthset, photographed by the Artemis II crew, April 2026. NASA."
        case .orbitSunset: "Sunset over the South Atlantic, photographed from the International Space Station, 2016. NASA."
        case .devilsTower: "The Milky Way over Devils Tower, Wyoming. Damon Joyce, National Park Service."
        case .cosmicCliffs: "The Cosmic Cliffs of the Carina Nebula, James Webb Space Telescope, 2022. NASA, ESA, CSA, STScI."
        case .saturn: "Saturn, a mosaic from the Cassini spacecraft, 2004. NASA/JPL/Space Science Institute."
        case .joshuaTree: "Night sky over Joshua Tree National Park, California. Brad Sutton, National Park Service."
        case .queenValley: "The Milky Way and Jupiter over Queen Valley, Joshua Tree. Emily Hassell, National Park Service."
        case .tetons: "Grand Teton National Park, Wyoming. David Restivo, National Park Service."
        case .tetonsCloud: "Sunrise in Grand Teton National Park. David Restivo, National Park Service."
        case .capeRoyal: "Sunrise from Cape Royal, Grand Canyon. National Park Service."
        case .vishnuTemple: "Vishnu Temple at sunrise, Grand Canyon. National Park Service."
        case .lavaSea: "Lava pouring into the sea at Kamokuna, Hawaiʻi Volcanoes National Park, 2017. Janice Wei, National Park Service."
        case .oolahValley: "Oolah Valley, Gates of the Arctic, Alaska. National Park Service."
        }
    }

    var isPicture: Bool { group != .colours }

    static var gradients: [AppBackground] { [.aurora, .sunset, .lagoon] }
    static var pictures: [AppBackground] { allCases.filter(\.isPicture) }

    // MARK: Pictures

    /// The full pictures aren't inside the app: each one downloads the first
    /// time you pick it, and Settings can remove any of them to free the space.
    /// The checksum makes sure the file is exactly the one we published.
    var download: (url: URL, sha256: String, bytes: Int)? {
        guard let file = Self.files[rawValue] else { return nil }
        let base = "https://raw.githubusercontent.com/ziad193/animus/main/Resources/backgrounds/"
        return (URL(string: base + rawValue + ".jpg")!, file.sha, file.bytes)
    }

    /// Each picture's checksum and size, as published.
    private static let files: [String: (sha: String, bytes: Int)] = [
        "wave": ("1fee975eda170ba3a5eef69cae20447ffaca6b6cb96f9b58dd3800b6650f96f6", 2_853_141),
        "wheat": ("5ff46fdb21cfa0d004aeaafb836a9feb26a834731be354fb9f6571aeaf3adea5", 5_298_907),
        "andes": ("7d0d4846b0abd13d3789c50a3225601214bd1570d18a695e1ec2e457f24fcaea", 2_706_225),
        "oxbow": ("5df162b16131e3824d4cada560e2efb405faea920c0a4a415127e16b90a32166", 2_380_846),
        "rockies": ("1d6d8bd5f8b1f69360e0b936eacda8163124eaf7ceaea1362b76aa2dfbdd37e1", 1_856_864),
        "earthset": ("69eb920eeb20b7c8a3c9a9e62fbfec6606c624492994867be3f6f564b6f3154b", 1_181_840),
        "ninthWave": ("56062f00ced20800a0cf5c95ac835d3bcfcc6b636287b2401eb6739c78a07771", 2_318_862),
        "yosemiteSunrise": ("6632eb6a3440e2fe6dcf4d114123d7b094dd8e42f56045c4df683ae016a0034f", 2_967_860),
        "cairnSnow": ("d18caefd74dd85a246d2638791a26a993ca55509aa66bfa18ac866e90e171350", 3_718_966),
        "wheatstacks": ("72b48a84f9b051c9d23efa0b106703c753df87e5fb18667b73f1a8d242f77275", 3_727_024),
        "sainteAdresse": ("4332e869cd776e4fcab51adb2efc7d7f84db01fa1b76d9382237113222379e42", 4_034_445),
        "turnerSunrise": ("97a8b6e972b45fda2b6f6898844e37fbf12198a74359b70ad5ba23a122acb946", 2_112_456),
        "friedrichSummer": ("af4bd33068675f7980a6b202170bbb5b4e159d53bafee0ebd9f082a60ef387d4", 3_707_327),
        "waterLilies": ("22ab256e4a730eac1c63674bbb51dc23ae394a0bb2888df0d898378999922a15", 2_290_878),
        "orbitSunset": ("6c7f21cb4d123c4e912ad8c58ffb8263f5680def75d770a8478d247461157a59", 3_631_938),
        "devilsTower": ("1ffdcc5fc1900c9c8e2611d02dd49d024d56f88d07627c93e0fbae6fc863ecb3", 2_698_022),
        "cosmicCliffs": ("ec847552da3c10d5c3dabef0d709b8c973055ce9900c57376b331a122d0279f3", 1_761_756),
        "saturn": ("0ff663ec137213bfb888b98c4c0d8500a66314c9a4898dd389904bd043170611", 278_317),
        "joshuaTree": ("1a1da18bf9c91f7c7a82254184f619cda7cfbe72bd049f35b3a6980359ab3981", 2_767_692),
        "queenValley": ("a8d863efcaac479807a680bdbfacd88c934bc11fca41befcc6d8173f75521665", 2_616_445),
        "tetons": ("e5562f79d39228dd1a9bce1f1812951f8da357df411db0058b49e406db5f4c7b", 3_966_983),
        "tetonsCloud": ("0d92109eb7bb0fb0e1c0eea879aca7b60258dceb6714ae968a9c6c75ab57a394", 2_524_720),
        "capeRoyal": ("d854d409c5166c6f95039f5aeaeb49524b4a3336f0a7ea6b68c8cc6240448a5c", 2_921_100),
        "vishnuTemple": ("a48627f082dd1cd118e0c4d4e2159e31bbe58387e31cf06ccb3ecefbcd5f1957", 2_006_308),
        "lavaSea": ("164b3145d0e2a172e541c44e240914853a092c65bb86c960d6cb62867b37b5d7", 1_555_921),
        "oolahValley": ("53d237f6d4e1e840637ce2c19738f43776f0512564ef27d7cb24f7878e6e422a", 1_631_756),
    ]

    /// Where a downloaded picture is kept.
    var fileURL: URL { BackgroundStore.folder.appendingPathComponent("\(rawValue).jpg") }

    @MainActor private static var cache: [String: PlatformImage] = [:]

    /// The full picture (once downloaded), or the small one for the picker
    /// (always there: it comes with the app).
    @MainActor func image(thumbnail: Bool = false) -> PlatformImage? {
        guard isPicture else { return nil }
        let key = thumbnail ? "\(rawValue)-thumb" : rawValue
        if let hit = Self.cache[key] { return hit }
        let url = thumbnail
            ? Bundle.main.resourceURL?.appendingPathComponent("backgrounds/\(rawValue)-thumb.jpg")
            : fileURL
        guard let url, let image = PlatformImage(contentsOfFile: url.path) else { return nil }
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

    /// Something to draw: a colour wash, or a picture that's been downloaded.
    @MainActor var isShowing: Bool { self != .none && isReady }

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

    /// Deletes one downloaded picture. If it was in use, the background
    /// goes back to plain until it's downloaded again.
    func remove(_ picture: AppBackground) {
        try? FileManager.default.removeItem(at: picture.fileURL)
        AppBackground.forgetFullPictures()
        generation += 1
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
            // A little darker overall, and most at the top where the greeting
            // and today's count sit, so white text reads on any picture.
            .overlay(LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.2)],
                                    startPoint: .top, endPoint: .bottom))
            .clipped()
            // White text and a light ring on the picture, in light or dark mode.
            .environment(\.colorScheme, .dark)
            // Only ever a backdrop: it reaches up behind the tabs and toolbar,
            // so it must never take clicks meant for them.
            .allowsHitTesting(false)
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
                            Image(platformImage: image)
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
        // A backdrop only: clicks always go to whatever is on top of it.
        .allowsHitTesting(false)
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
/// True for views on Home's picture banner: text sits straight on the
/// picture with a soft shadow, rather than on glass.
private struct OnBannerKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var onPicture: Bool {
        get { self[OnPictureKey.self] }
        set { self[OnPictureKey.self] = newValue }
    }
    var onBanner: Bool {
        get { self[OnBannerKey.self] }
        set { self[OnBannerKey.self] = newValue }
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
    /// `alsoOnBanner` keeps the glass on Home's banner too (the profile bubble).
    func frostedOnPicture(cornerRadius: CGFloat = 16, padding: CGFloat = 0, alsoOnBanner: Bool = false) -> some View {
        modifier(FrostedOnPicture(cornerRadius: cornerRadius, padding: padding, alsoOnBanner: alsoOnBanner))
    }

    /// The background picture behind a whole page, like Home's, with each
    /// block on frosted glass. `blur` softens it (Add Cards, for focus).
    /// With no background, the page keeps its `plain` fill.
    func pageBackground(blur: CGFloat = 0, plain: some ShapeStyle = Color.clear) -> some View {
        modifier(PageBackground(blur: blur, plain: AnyShapeStyle(plain)))
    }

    /// A soft dark shadow so white text stays readable on the banner picture.
    func bannerShadow() -> some View { modifier(BannerShadow()) }
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

private struct PageBackground: ViewModifier {
    let blur: CGFloat
    let plain: AnyShapeStyle
    @AppStorage(AppBackground.key) private var background = AppBackground.none
    @State private var store = BackgroundStore.shared

    func body(content: Content) -> some View {
        let _ = store.generation
        if !background.isShowing {
            content.background(plain)
        } else {
            content
                // Light text on the darkened picture, and glass behind each block.
                .environment(\.colorScheme, .dark)
                .environment(\.onPicture, true)
                .background {
                    BannerBackdrop(background: background)
                        .blur(radius: blur, opaque: true)
                        .ignoresSafeArea()
                }
        }
    }
}

private struct BannerShadow: ViewModifier {
    @Environment(\.onBanner) private var onBanner
    func body(content: Content) -> some View {
        if onBanner {
            content
                .shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.6), radius: 10)
        } else {
            content
        }
    }
}

private struct FrostedOnPicture: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    var alsoOnBanner = false
    @Environment(\.onPicture) private var onPicture
    @Environment(\.onBanner) private var onBanner

    func body(content: Content) -> some View {
        if onPicture || (alsoOnBanner && onBanner) {
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
        if !background.isShowing || style == .banner {
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
    @State private var removing: AppBackground?

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
            ForEach(AppBackground.Group.allCases) { group in
                let options = AppBackground.allCases.filter { $0.group == group && $0.isOffered }
                if !options.isEmpty {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(options) { option in
                            Tile(option: option,
                                 selected: background == option && option.isReady,
                                 downloading: store.downloading.contains(option),
                                 remove: { removing = option }) {
                                choose(option)
                            }
                        }
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
        .confirmationDialog("Delete “\(removing?.title ?? "")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Delete Picture", role: .destructive) {
                if let removing { store.remove(removing) }
            }
        } message: {
            Text("This frees up \(ByteCountFormatter.string(fromByteCount: Int64(removing?.download?.bytes ?? 0), countStyle: .file)). You can download it again any time\(removing == background ? "; until then the background is plain" : "").")
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
        let remove: () -> Void
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
                // The whole tile is clickable, including the preview (which,
                // for the colour washes, otherwise ignores clicks like every backdrop).
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(downloading)
            .hoverLift(scale: 1.03)
            .tip(option.isReady ? (option.credit ?? option.title) : "Download \(option.title) (\(size))")
            // Downloaded pictures can be deleted one at a time to save space.
            .overlay(alignment: .topTrailing) {
                if option.isPicture && option.isReady {
                    Button(action: remove) {
                        Image(systemName: "trash.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .tip("Delete this picture (\(size)) to save space")
                }
            }
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
                    #if os(macOS)
                    Color(nsColor: .windowBackgroundColor)
                    #else
                    Color(uiColor: .systemBackground)
                    #endif
                    Image(systemName: "nosign").font(.title2).foregroundStyle(.secondary)
                }
            } else if let thumb = option.image(thumbnail: true) {
                Image(platformImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                BackgroundFill(background: option)
            }
        }
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
