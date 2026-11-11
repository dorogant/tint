// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The Rust core (core/) is built by `cargo` first; scripts/build-app.sh does both.
let rustLibDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("core/target/release")
    .path

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
            // Guides for coding agents, not resources.
            exclude: ["Views/AGENTS.md", "Visualization/AGENTS.md"],
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
