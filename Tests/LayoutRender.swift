import AppKit
import IOSurface
import SwiftUI

/// Renders the real main window offscreen with a fixture library and writes
/// PNGs (2x) of each page, the toolbar and the sidebar, for layout review.
/// Nothing is shown on screen and nothing talks to Spotify. See scripts/test-layout.sh.
@main @MainActor
struct LayoutRender {
    static let size = CGSize(width: 1710, height: 1000)

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0) // line by line, so a log being followed stays current
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: environment["FLOE_LAYOUT_DIR"] ?? "/tmp/tint-layout", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let only = environment["FLOE_LAYOUT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }

        FixtureProtocol.install()
        // Flat glass (the snapshot path); the app's own preferences are untouched
        // because the script points the harness at a temporary home.
        // FLOE_LAYOUT_REAL_GLASS=1 keeps Liquid Glass, which renders in the toolbar but not in the content;
        // FLOE_LAYOUT_REDUCE_MOTION=1 renders with the app's Reduce Motion on.
        var defaults: [String: Any] = ["appLanguage": "en",
                                       "reduceMotion": environment["FLOE_LAYOUT_REDUCE_MOTION"] == "1"]
        if environment["FLOE_LAYOUT_REAL_GLASS"] != "1" { defaults["FloeSnapshotDir"] = output.path }
        // FLOE_LAYOUT_SIZE=compact|standard|large picks the interface size (default: the app's).
        if let size = environment["FLOE_LAYOUT_SIZE"] { defaults["interfaceSize"] = size }
        UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)

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
        .environment(\.interfaceScale, settings.interfaceSize.scale)
        .environment(\.coverPalette, CoverPalette.fixed(settings.fixedAccent))
        // The harness can't activate without taking focus from whatever's in front;
        // FLOE_LAYOUT_ACTIVE=1 measures as if it were the frontmost app.
        .transformEnvironment(\.scenePhase) { if environment["FLOE_LAYOUT_ACTIVE"] == "1" { $0 = .active } }

        let window = OffscreenWindow(contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.title = "Tint"
        window.isReleasedWhenClosed = false
        let host = CountingHostingView(rootView: root)
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host
        window.orderFrontRegardless()
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))

        await settle(window)
        if environment["FLOE_LAYOUT_DUMP_TOOLBAR"] == "1", let frame = window.contentView?.superview {
            func dump(_ view: NSView, _ depth: Int) {
                let rect = view.convert(view.bounds, to: nil)
                print(String(repeating: "  ", count: depth) + "\(type(of: view)) \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
                for child in view.subviews where !(child is NSHostingView<AnyView>) { dump(child, depth + 1) }
            }
            for child in frame.subviews where "\(type(of: child))".contains("Titlebar") { dump(child, 0) }
        }
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print(condition ? "  ✓ \(name)" : "  ✗ \(name)")
            if !condition { failures += 1 }
        }
        check(!(window.firstResponder is NSText), "the search field doesn't take focus on its own")
        if environment["FLOE_LAYOUT_DUMP_SCROLL"] == "1" {
            print("first Home:")
            dumpScrollViews(window.contentView!)
        }
        navigator.surface = .nowPlaying
        await settle(window, steps: 10)
        if only?.contains("now-playing") ?? true { write(capture(window), to: output.appendingPathComponent("now-playing.png")) }
        navigator.surface = .lyrics
        await settle(window, steps: 10)
        if only?.contains("lyrics") ?? true { write(capture(window), to: output.appendingPathComponent("lyrics.png")) }
        navigator.surface = .library
        await settle(window, steps: 10)
        check(!(window.firstResponder is NSText), "returning to Library doesn't focus the field either")

        let playlist = Route.playlist(library.playlists[4].id)
        let scenarios: [(String, @MainActor () async -> Void)] = [
            ("home", { navigator.select(.home) }),
            ("search", {
                // Open a playlist, go to Now Playing, ⌘F and type: results open over the playlist.
                navigator.select(playlist)
                await settle(window)
                check(searchField(in: window) != nil, "the search field is in the toolbar")
                navigator.surface = .nowPlaying
                await settle(window, steps: 10)
                check(searchField(in: window) != nil, "the search field stays in the toolbar on Now Playing")
                navigator.select(.search)
                await settle(window, steps: 10)
                check(window.firstResponder is NSText && navigator.surface == .library,
                      "⌘F from Now Playing focuses the toolbar field and brings Library back")
                search.text = "tame impala"
                check(navigator.stack == [playlist, .search], "results open over the page you were on")
            }),
            ("search-artist", {
                // Opening a result lets go of the keyboard; ⌘F comes back with the query selected.
                navigator.push(.artist("tame-impala"))
                await settle(window, steps: 5)
                check(!(window.firstResponder is NSText), "opening a result hands the keyboard back")
                check(navigator.section == .search, "Search stays the section under a result")
                navigator.select(.search)
                await settle(window, steps: 5)
                let editor = window.firstResponder as? NSTextView
                check(editor?.selectedRange() == NSRange(location: 0, length: search.text.utf16.count),
                      "⌘F refocuses the field with the query selected")
                check(navigator.stack == [playlist, .search], "⌘F returns to the results instead of stacking them")
                navigator.push(.artist("tame-impala"))
            }),
            ("search-empty", {
                navigator.select(.search)
                await settle(window, steps: 5)
                // Escape clears the query and goes back; ⌘F then shows the empty state.
                window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
                await settle(window, steps: 5)
                check(search.text.isEmpty && navigator.stack == [playlist], "Escape clears and returns to the page")
                check(!(window.firstResponder is NSText), "Escape lets go of the keyboard")
                // Click into the field on Lyrics and type: Library comes back with the results.
                navigator.surface = .lyrics
                await settle(window, steps: 10)
                if let field = searchField(in: window) { window.makeFirstResponder(field) }
                await settle(window, steps: 5)
                search.text = "tame"
                await settle(window, steps: 5)
                check(navigator.surface == .library && navigator.current == .search, "typing on Lyrics shows the results")
                window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
                await settle(window, steps: 10)
                check(search.text.isEmpty && navigator.current != .search, "Escape returns from those results too")
                navigator.select(.search)
            }),
            ("playlist", {
                navigator.select(playlist)
                await settle(window, steps: 5)
                check(!(window.firstResponder is NSText), "leaving Search hands the keyboard back")
            }),
            ("artist", { navigator.select(.artist("tame-impala")) }),
            ("album", { navigator.select(.album("currents")) }),
            ("songs", { navigator.select(.songs) }),
            ("status-banner", {
                navigator.select(.home)
                FloeCore.shared.deliver(.unavailable(uri: nowPlaying.uri))
            }),
            ("home-default-size", {
                player.dismissError()
                // A fresh page: the banner's spring can leave the old one up to 2 pt off (see below).
                navigator.select(.songs)
                await settle(window, steps: 5)
                navigator.select(.home)
                window.setContentSize(CGSize(width: 1220, height: 800))
            }),
            ("home-minimum-size", { window.setContentSize(CGSize(width: 940, height: 600)) }),
        ]
        for (name, setUp) in scenarios where only?.contains(name) ?? true {
            await setUp()
            await settle(window)
            write(capture(window), to: output.appendingPathComponent("\(name).png"))
            if environment["FLOE_LAYOUT_DUMP_SCROLL"] == "1" { dumpScrollViews(window.contentView!) }
            // Known: a banner's room opens on a spring, and AppKit rounds the page's
            // scroll offset to pixels on each frame of it, so it can end 1–2 pt off.
            guard name != "status-banner" else { continue }
            check(scrollViewsAtRest(window.contentView!), "\(name): pages and shelves rest unscrolled, on the guides")
        }
        if environment["FLOE_LAYOUT_PERF"] == "1" {
            await measure(window: window, host: host, player: player, navigator: navigator, playlist: playlist)
        }
        window.close()
        print(failures == 0 ? "PASS: layout renders written to \(output.path)" : "FAIL: \(failures) check(s)")
        if failures > 0 { exit(1) }
    }

    /// FLOE_LAYOUT_PERF=1: CPU and SwiftUI window layouts per second on each
    /// surface, paused and then playing, with effects off. Continuous SwiftUI
    /// motion shows up as one layout per frame; the progress bars tick once a second.
    static func measure(window: NSWindow, host: CountingHostingView<some View>, player: PlayerModel,
                        navigator: Navigator, playlist: Route) async {
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        window.setContentSize(size)
        let seconds = Double(ProcessInfo.processInfo.environment["FLOE_LAYOUT_PERF_SECONDS"] ?? "") ?? 4
        let surfaces: [(String, () -> Void)] = [
            ("home", { navigator.surface = .library; navigator.select(.home) }),
            ("playlist", { navigator.select(playlist) }),
            ("now playing", { navigator.surface = .nowPlaying }),
            ("lyrics", { navigator.surface = .lyrics }),
        ]
        for playing in [false, true] {
            FloeCore.shared.deliver(playing ? .playing(positionMs: 64_000) : .paused(positionMs: 64_000))
            for (name, show) in surfaces {
                show()
                await settle(window, steps: 15)
                let before = cpu(), layouts = host.layouts, started = Date()
                try? await Task.sleep(for: .seconds(seconds))
                let elapsed = Date().timeIntervalSince(started)
                print(String(format: "PERF %@, %@: %.2f%% CPU, %.1f window layouts/s", name,
                             player.isPlaying ? "playing" : "paused", (cpu() - before) / elapsed * 100,
                             Double(host.layouts - layouts) / elapsed))
                if !player.isPlaying, let root = window.contentView?.superview?.layer {
                    print("  " + LayerCensus(root).summary)
                }
            }
        }
        FloeCore.shared.deliver(.paused(positionMs: 64_000))
        navigator.surface = .library
    }

    /// The toolbar's search field (the system's, inside the titlebar).
    static func searchField(in window: NSWindow) -> NSSearchField? {
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for child in view.subviews { if let field = find(child) { return field } }
            return nil
        }
        return window.contentView?.superview.flatMap(find)
    }

    /// Nothing has been scrolled in the harness, so every scroll view should sit
    /// at its origin. Animating a scroll view's frame used to leave it a few
    /// points off (pages under the toolbar, shelves sideways). Allow a pixel.
    static func scrollViewsAtRest(_ view: NSView) -> Bool {
        if let scroll = view as? NSScrollView {
            let origin = scroll.documentVisibleRect.origin
            if abs(origin.x + scroll.contentInsets.left) > 0.5 || abs(origin.y + scroll.contentInsets.top) > 0.5 {
                print("    \(scroll.convert(scroll.bounds, to: nil)) rests at \(origin)")
                return false
            }
        }
        return view.subviews.allSatisfy(scrollViewsAtRest)
    }

    /// Where each scroll view sits and how far it's scrolled, for chasing offsets.
    static func dumpScrollViews(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            let frame = scroll.convert(scroll.bounds, to: nil)
            print("  scroll \(frame) visible \(scroll.documentVisibleRect) insets \(scroll.contentInsets)")
        }
        view.subviews.forEach(dumpScrollViews)
    }

    static func settle(_ window: NSWindow, steps: Int = 20) async {
        for _ in 0..<steps {
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

    /// The area under the toolbar comes out transparent; lay it on the window's base colour.
    static func write(_ rep: NSBitmapImageRep, to url: URL) {
        let opaque = bitmap(for: NSView(frame: NSRect(origin: .zero, size: rep.size)))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: opaque)
        NSColor(red: 0.045, green: 0.05, blue: 0.06, alpha: 1).setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? opaque.representation(using: .png, properties: [:])?.write(to: url)
        print("[layout] \(url.path)")
    }
}

/// What the window's layers hold: how many, how much backing store their
/// contents take (estimated at their scale), and how many need an offscreen
/// pass (shadows without a path, masks, filters, group opacity).
struct LayerCensus {
    var layers = 0, withContents = 0, offscreen = 0
    /// Offscreen passes by cause: shadow, mask, filter, group opacity.
    var causes: [String: Int] = [:]
    var bytes = 0.0
    var largest: [(String, Double)] = []

    init(_ root: CALayer) {
        visit(root)
        largest = Array(largest.sorted { $0.1 > $1.1 }.prefix(5))
    }

    private mutating func visit(_ layer: CALayer) {
        layers += 1
        if layer.contents != nil {
            withContents += 1
            let size = layer.bounds.size, scale = layer.contentsScale
            // An image costs its own pixels however large it's drawn; drawn contents cost the layer's.
            let image = CFGetTypeID(layer.contents as CFTypeRef) == CGImage.typeID ? (layer.contents as! CGImage) : nil
            // SwiftUI's proxy images hide their pixels; they're images too, so don't guess from the layer.
            let proxy = "\(type(of: layer.contents as AnyObject))".contains("ProxyImage")
            let layerBytes = image.map { Double($0.width * $0.height * 4) }
                ?? (proxy ? 0 : Double(size.width * scale * size.height * scale * 4))
            bytes += layerBytes
            let owner = layer.delegate.map { " of \(type(of: $0))" } ?? ""
            largest.append(("\(type(of: layer))\(owner) \(Int(size.width))x\(Int(size.height))@\(Int(scale))x"
                            + (image.map { " image \($0.width)x\($0.height)" }
                               ?? " \(contentsKind(layer.contents!))"), layerBytes))
        }
        let cause = if layer.shadowOpacity > 0 && layer.shadowPath == nil {
                (layer.shadowColor?.alpha ?? 0) == 0 ? "invisible shadow" : "shadow"
            }
            else if layer.mask != nil { "mask" }
            else if !(layer.filters ?? []).isEmpty { layer.opacity == 0 ? "hidden filter" : "filter" }
            else if layer.allowsGroupOpacity && layer.opacity < 1 && !(layer.sublayers ?? []).isEmpty { "group opacity" }
            else { String?.none }
        if let cause {
            offscreen += 1
            causes[cause, default: 0] += 1
        }
        layer.sublayers?.forEach { visit($0) }
    }

    /// The contents' class, and an IOSurface's real size.
    private func contentsKind(_ contents: Any) -> String {
        if let surface = contents as? IOSurface { return "IOSurface \(surface.width)x\(surface.height)" }
        return String(describing: type(of: contents as AnyObject))
    }

    var summary: String {
        String(format: "layers %d, with contents %d (~%.1f MB), offscreen passes %d (%@); largest: %@", layers,
               withContents, bytes / 1_048_576, offscreen,
               causes.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "),
               largest.map { String(format: "%@ %.1f MB", $0.0, $0.1 / 1_048_576) }.joined(separator: ", "))
    }
}

/// Counts SwiftUI's passes over the window.
final class CountingHostingView<Content: View>: NSHostingView<Content> {
    private(set) var layouts = 0

    override func layout() {
        layouts += 1
        super.layout()
    }
}

/// Keeps its offscreen origin instead of being pulled back onto a display.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
