// swift-tools-version: 6.2
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

// The Rust core (core/) is built by `cargo` first; scripts/build-app.sh does both.
let rustLibDir = root.appendingPathComponent("core/target/release").path

// Guides for coding agents, not resources. They are kept out of the repository, so a
// clone doesn't have them, and excluding a file that isn't there is a warning.
let agentGuides = ["Views/AGENTS.md", "Visualization/AGENTS.md"].filter {
    FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Floe/\($0)").path)
}

let package = Package(
    name: "Floe",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Floe", targets: ["Floe"]),
    ],
    targets: [
        // C header + modulemap for libfloe_core.a.
        .systemLibrary(name: "CFloeCore", path: "Sources/CFloeCore"),
        .executableTarget(
            name: "Floe",
            dependencies: ["CFloeCore"],
            path: "Sources/Floe",
            exclude: agentGuides,
            linkerSettings: [
                .unsafeFlags(["-L", rustLibDir]),
                // Needed by librespot's native-tls / networking / sysinfo deps.
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
