import AppKit
import Foundation

/// Whether this Mac can run Apple Intelligence, the free, private, on-device
/// AI that Animus will use for lighter features without Animus+.
///
/// Apple's on-device model (the Foundation Models framework) needs an Apple
/// Silicon Mac on macOS 26 or later, with Apple Intelligence turned on. This
/// check covers the first two from the hardware and system version. Once Animus
/// is built with the macOS 26 tools, `SystemLanguageModel.default.availability`
/// will also say whether Apple Intelligence is switched on and its model has
/// downloaded; that check slots in here.
enum OnDeviceAI {
    enum Status: Equatable {
        /// Apple Silicon and macOS 26: can run it (if Apple Intelligence is on).
        case capable
        /// Apple Silicon, but macOS is older than 26.
        case needsNewerMacOS(current: String)
        /// An Intel Mac: Apple Intelligence isn't available.
        case notAppleSilicon
    }

    static var status: Status {
        guard isAppleSilicon else { return .notAppleSilicon }
        guard isMacOS26 else {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return .needsNewerMacOS(current: "\(v.majorVersion).\(v.minorVersion)")
        }
        return .capable
    }

    /// True on Apple Silicon, even when the Intel version of Animus is running
    /// through Rosetta (the Mac itself is still capable).
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var isMacOS26: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    static var macOSName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    /// Opens System Settings at Software Update.
    static func openSoftwareUpdate() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    /// Opens System Settings at Apple Intelligence & Siri.
    static func openSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    /// Free with Apple Intelligence: short text in, short text out, where the
    /// small on-device model does well (it reads text only, a few pages at a time).
    static let freeFeatures: [PlusFeature] = [.fixCard, .clozeFromNotes, .pictureToCards, .examPlan, .weeklyReport]

    /// What Animus+ adds on top: the jobs that need a stronger model, whole
    /// lectures, or real medical knowledge (a small model can state facts wrongly).
    static let plusOnly: [PlusFeature] = [.lectureToCards, .askAnimus, .explainMistakes, .practiceQuestions]

    /// Free for everyone, no AI at all: the Mac's own text recognition and a deck search.
    static let freeForEveryone = "Automatic picture labels and the duplicate check work for everyone, no AI needed."
}
