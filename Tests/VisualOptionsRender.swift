import AppKit
import SwiftUI

/// Offscreen renders of the Visuals popover's controls (presets at the top of
/// the live background), in English and Ukrainian, on a preset and on Custom.
/// Synthetic settings in a private defaults suite; nothing plays or signs in.
@main
@MainActor
struct VisualOptionsRender {
    static func main() {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLOE_OPTIONS_DIR"] ?? "/tmp/tint-visual-options")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (language, preset) in [("en", BackgroundPreset.club), ("en", .custom), ("uk", .hipHop)] {
            let suite = "tint-visual-options-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = VisualSettings(defaults: defaults)
            settings.liveBackground = true
            settings.choose(preset == .custom ? .intense : preset)
            if preset == .custom { settings.glow = 1.86 }
            let view = VisualControls()
                .environment(VisualizationModel())
                .environment(settings)
                .environment(\.locale, Locale(identifier: language))
                .preferredColorScheme(.dark)
                .background(Color(white: 0.16))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            let size = host.fittingSize
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = directory.appendingPathComponent("visual-options-\(language)-\(preset.rawValue).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path, "preset:", settings.backgroundPreset.rawValue, "size:", size)
            window.close()
        }
    }
}
