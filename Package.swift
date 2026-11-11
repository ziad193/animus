// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StudyApp",
    platforms: [.macOS(.v15)],
    targets: [
        // C header describing the Rust engine (engine/src/lib.rs).
        .target(
            name: "CStudyEngine",
            path: "Sources/CStudyEngine",
            linkerSettings: [
                .unsafeFlags(["-L", "engine/target/lib"]),
                .linkedLibrary("study_engine"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Swift-friendly wrapper around the engine. No UI code here,
        // so a future web/Tauri version can follow the same shape.
        .target(
            name: "StudyCore",
            dependencies: ["CStudyEngine"],
            path: "Sources/StudyCore"
        ),
        // Developer tool for testing the engine from the terminal.
        .executableTarget(
            name: "study-cli",
            dependencies: ["StudyCore"],
            path: "Sources/StudyCLI"
        ),
        // TEST ONLY: the helper Claude starts to reach Animus Dev (remove for the final release).
        .executableTarget(
            name: "animus-connector",
            path: "Sources/AnimusConnector"
        ),
        // The Mac app itself (SwiftUI).
        .executableTarget(
            name: "StudyApp",
            dependencies: ["StudyCore"],
            path: "Sources/StudyApp"
        ),
    ],
    swiftLanguageModes: [.v5]
)
