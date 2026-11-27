import AppKit
import SwiftUI

/// Offscreen renders of the Visuals popover's controls (presets at the top of
/// the live background), in English and Ukrainian, on a preset and on Custom,
/// and of the equalizer in Settings.
/// Synthetic settings in a private defaults suite; nothing plays or signs in.
@main
@MainActor
struct VisualOptionsRender {
    static func main() {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLOE_OPTIONS_DIR"] ?? "/tmp/tint-visual-options")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Hand-picked presets, then the auto preset's captions (from a genre, from the sound, still choosing).
        let scenarios: [(language: String, name: String, setUp: (VisualSettings) -> Void)] = [
            ("en", "club", { $0.choose(.club) }),
            ("en", "custom", { $0.choose(.intense); $0.glow = 1.86 }),
            ("uk", "hipHop", { $0.choose(.hipHop) }),
            ("en", "auto-genre", { auto($0, .club, .genre(.club, "ukrainian electronic")) }),
            ("uk", "auto-genre", { auto($0, .hipHop, .genre(.hipHop, "ukrainian hip hop")) }),
            ("en", "auto-sound", { auto($0, .chill, .sound(.chill)) }),
            ("uk", "auto-sound", { auto($0, .rock, .sound(.rock)) }),
            ("en", "auto-choosing", { auto($0, .balanced, .choosing) }),
            ("uk", "auto-choosing", { auto($0, .balanced, .choosing) }),
            ("en", "settings-auto-genre", { auto($0, .club, .genre(.club, "ukrainian electronic")) }),
            ("uk", "settings-auto-sound", { auto($0, .acoustic, .sound(.acoustic)) }),
        ]
        for (language, name, setUp) in scenarios {
            let settings = VisualSettings(defaults: TestDefaults.make())
            settings.liveBackground = true
            setUp(settings)
            // "settings-…" scenarios draw the rows as Settings ▸ Background's grouped form does.
            let content = name.hasPrefix("settings-")
                ? AnyView(Form { Section("Motion") { BackgroundOptions() } }.formStyle(.grouped).frame(width: 520, height: 640))
                : AnyView(VisualControls())
            let view = content
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
            let url = directory.appendingPathComponent("visual-options-\(language)-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path, "preset:", settings.backgroundPreset.rawValue, "auto:", settings.autoPreset, "size:", size)
            window.close()
        }
        equalizerPanes(directory: directory)
    }

    /// Settings ▸ Playback's equalizer, in the grouped form it sits in: a preset,
    /// a custom curve, switched off, and waiting for the tap to hear Soloist.
    private static func equalizerPanes(directory: URL) {
        let scenarios: [(language: String, name: String, setUp: (inout Equalizer) -> Void)] = [
            ("en", "rock", { $0.isOn = true; $0.choose(.rock) }),
            ("uk", "custom", { $0.isOn = true; $0.choose(.vocal); $0.setGain(-7.5, band: 0); $0.setGain(12, band: 9) }),
            ("en", "off", { $0.choose(.bassBoost) }),
            ("uk", "listening", { $0.isOn = true }),
        ]
        for (language, name, setUp) in scenarios {
            let settings = AppSettings(defaults: TestDefaults.make())
            setUp(&settings.equalizer)
            EqualizerStatus.shared.state = name == "listening" ? .listening : .idle
            let view = Form { EqualizerSection() }.formStyle(.grouped).frame(width: 620, height: 420)
                .environment(settings)
                .environment(\.locale, Locale(identifier: language))
                .preferredColorScheme(.dark)
                .background(Color(white: 0.16))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = directory.appendingPathComponent("equalizer-\(language)-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path, "preset:", settings.equalizer.preset.rawValue, "size:", host.frame.size)
            window.close()
        }
    }

    /// The auto preset as the controller leaves it after choosing for a song.
    private static func auto(_ settings: VisualSettings, _ preset: BackgroundPreset, _ status: AutoPresetStatus) {
        settings.autoPreset = true
        settings.applyAutomatically(preset)
        settings.autoStatus = status
    }
}
