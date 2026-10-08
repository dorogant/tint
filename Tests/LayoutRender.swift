import AppKit
import SwiftUI

/// Renders the real main window offscreen with a fixture library and writes
/// PNGs (2x) of each page, the toolbar and the sidebar, for layout review.
/// Nothing is shown on screen and nothing talks to Spotify. See scripts/test-layout.sh.
@main @MainActor
struct LayoutRender {
    static let size = CGSize(width: 1710, height: 1000)

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: environment["FLOE_LAYOUT_DIR"] ?? "/tmp/tint-layout", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let only = environment["FLOE_LAYOUT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }

        FixtureProtocol.install()
        // Flat glass (the snapshot path); the app's own preferences are untouched
        // because the script points the harness at a temporary home.
        UserDefaults.standard.setVolatileDomain(["FloeSnapshotDir": output.path, "appLanguage": "en"],
                                                forName: UserDefaults.argumentDomain)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let player = PlayerModel()
        let api = WebAPI(user: UserTokenProvider(), tokens: FixtureTokens(), http: FixtureProtocol.session)
        let library = LibraryModel(api: api)
        let navigator = Navigator()
        let search = SearchModel()
        let appearance = CoverAppearance()
        let visuals = VisualSettings()
        let settings = AppSettings()

        await library.refresh()
        let nowPlaying = TrackInfo(Track(id: "np", uri: "spotify:track:np", name: "New Person, Same Old Mistakes",
                                         durationMs: 363_000, explicit: false,
                                         artists: [ArtistRef(id: "tame-impala", uri: "spotify:artist:tame-impala", name: "Tame Impala")],
                                         album: library.savedAlbums.first, trackNumber: 13, discNumber: 1,
                                         isLocal: false, isPlayable: true))
        FloeCore.shared.deliver(.connected(username: Fixture.userID))
        FloeCore.shared.deliver(.track(nowPlaying))
        FloeCore.shared.deliver(.paused(positionMs: 64_000))
        await appearance.load(nowPlaying.coverURL, blur: visuals.backgroundBlur)

        let root = ZStack {
            Backdrop()
            MainView()
        }
        .preferredColorScheme(.dark)
        .environment(player)
        .environment(library)
        .environment(navigator)
        .environment(search)
        .environment(LyricsModel())
        .environment(appearance)
        .environment(VisualizationModel())
        .environment(visuals)
        .environment(settings)
        .environment(ConnectModel(api: api))
        .environment(\.coverPalette, CoverPalette.fixed(settings.fixedAccent))

        let window = OffscreenWindow(contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.title = "Tint"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host
        window.orderFrontRegardless()
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))

        let scenarios: [(String, @MainActor () -> Void)] = [
            ("home", { navigator.select(.home) }),
            ("search", {
                navigator.select(.search)
                search.text = "tame impala"
            }),
            ("search-empty", {
                search.text = ""
                navigator.select(.search)
            }),
            ("playlist", { navigator.select(.playlist(library.playlists[4].id)) }),
            ("artist", { navigator.select(.artist("tame-impala")) }),
            ("album", { navigator.select(.album("currents")) }),
            ("songs", { navigator.select(.songs) }),
        ]
        for (name, setUp) in scenarios where only?.contains(name) ?? true {
            setUp()
            await settle(window)
            write(capture(window), to: output.appendingPathComponent("\(name).png"))
        }
        window.close()
        print("PASS: layout renders written to \(output.path)")
    }

    static func settle(_ window: NSWindow) async {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The content at 2x with the toolbar drawn on top (it lives in the
    /// titlebar, outside the content view), as `Snapshot.capture` does.
    static func capture(_ window: NSWindow) -> NSBitmapImageRep {
        let content = window.contentView!
        let rep = bitmap(for: content)
        content.cacheDisplay(in: content.bounds, to: rep)
        if let titlebar = content.superview?.subviews.first(where: { "\(type(of: $0))".contains("Titlebar") }) {
            let bar = bitmap(for: titlebar)
            titlebar.cacheDisplay(in: titlebar.bounds, to: bar)
            let origin = content.convert(content.bounds, to: nil).origin
            let frame = titlebar.convert(titlebar.bounds, to: nil).offsetBy(dx: -origin.x, dy: -origin.y)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            bar.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep
    }

    static func bitmap(for view: NSView) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                                   pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                   bitsPerPixel: 0)!
        rep.size = view.bounds.size
        return rep
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("[layout] \(url.path)")
    }
}

/// Keeps its offscreen origin instead of being pulled back onto a display.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
