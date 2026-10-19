import AppKit
import QuartzCore
import SwiftUI

/// Scrolls the real playlist page (the production window, views and models)
/// offscreen through a long synthetic playlist and measures the main thread
/// frame by frame. The fixture network from the layout harness answers every
/// request, with paging and generated covers: no login, network, audio or
/// visible window. See scripts/benchmark-scroll.sh.
@main @MainActor
struct ScrollBenchmark {
    static let size = CGSize(width: 1710, height: 1000)

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let environment = ProcessInfo.processInfo.environment
        let seconds = min(max(Double(environment["FLOE_SCROLL_SECONDS"] ?? "") ?? 5, 1), 600)
        /// Points per second; a brisk two-finger scroll.
        let speed = Double(environment["FLOE_SCROLL_SPEED"] ?? "") ?? 2_000
        let only = environment["FLOE_SCROLL_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }

        ScrollFixture.install()
        UserDefaults.standard.setVolatileDomain(["appLanguage": "en", "reduceMotion": false,
                                                 "FloeSnapshotDir": NSTemporaryDirectory()],
                                                forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let player = PlayerModel()
        let api = WebAPI(user: UserTokenProvider(), tokens: FixtureTokens(), http: ScrollFixture.session)
        let library = LibraryModel(api: api)
        let navigator = Navigator()
        let appearance = CoverAppearance()
        let visuals = VisualSettings()
        let settings = AppSettings()
        await library.refresh()
        let nowPlaying = TrackInfo(Track(id: "np", uri: "spotify:track:np", name: "New Person, Same Old Mistakes",
                                         durationMs: 363_000, explicit: false,
                                         artists: [ArtistRef(id: "tame-impala", uri: "spotify:artist:tame-impala",
                                                             name: "Tame Impala")],
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
        .environment(SearchModel())
        .environment(LyricsModel())
        .environment(appearance)
        .environment(VisualizationModel())
        .environment(visuals)
        .environment(settings)
        .environment(ConnectModel(api: api))
        .environment(\.interfaceScale, settings.interfaceSize.scale)
        .environment(\.coverPalette, CoverPalette.fixed(settings.fixedAccent))

        let origin = CGPoint(x: -30_000, y: -30_000)
        let window = OffscreenWindow(contentRect: NSRect(origin: origin, size: size),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        let host = CountingHostingView(rootView: root)
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host
        window.orderFrontRegardless()
        window.setFrameOrigin(origin)
        await settle(window, seconds: 2)

        let meter = MainThreadMeter()
        var failures = 0
        print(String(format: "SCROLL %d tracks, %.0f pt/s for %.0f s per run, window %.0fx%.0f @%.0fx",
                     ScrollFixture.trackCount, speed, seconds, size.width, size.height, window.backingScaleFactor))

        func run(_ name: String, playlist: String? = nil, seconds: Double, speed: Double, hover: Bool = false) async {
            guard only?.contains(name) ?? true else { return }
            if let playlist {
                navigator.select(.playlist(playlist))
                // The first page and the reveal.
                await settle(window, seconds: 2)
            }
            guard let scroll = pageScrollView(in: host) else {
                print("  ✗ \(name): no page scroll view")
                failures += 1
                return
            }
            await settle(window, seconds: 0.5)
            let result = await drive(scroll, host: host, meter: meter, seconds: seconds, speed: speed, hover: hover)
            print(result.line(name))
            if let redraws = result.redraws { print(redraws) }
            if environment["FLOE_SCROLL_VIEWS"] == "1" { print("  " + viewCensus(window)) }
            if hover && result.hoverChanges == 0 {
                print("  ✗ \(name): the simulated pointer never reached a row")
                failures += 1
            }
        }

        // Cold: rows, covers and pages arrive as the list scrolls; liked state isn't fetched.
        await run("cold", playlist: ScrollFixture.playlistIDs[0], seconds: seconds, speed: speed)
        // Back up over the same rows: covers and pages are in, only the rows are rebuilt.
        await run("warm", seconds: seconds, speed: -speed)
        // Down again with a pointer resting over the list, so rows light up as they pass under it.
        await run("hover", seconds: seconds, speed: speed, hover: true)
        // Back up three times as fast, as a flick does.
        await run("flick", seconds: seconds / 3, speed: -3 * speed)
        // A second playlist, cold, with liked-state checks answered as rows appear.
        library.benchmarkConnect()
        await run("cold-liked", playlist: ScrollFixture.playlistIDs[1], seconds: seconds, speed: speed)

        if let path = environment["FLOE_SCROLL_SNAPSHOT"] {
            let content = window.contentView!
            if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("[scroll] \(path)")
            }
        }
        window.close()
        print(failures == 0 ? "PASS: scroll benchmark completed; test window closed" : "FAIL: \(failures) check(s)")
        if failures > 0 { exit(1) }
    }

    // MARK: Driving

    struct Result {
        var frames: [Double] = []
        var cpu = 0.0, elapsed = 0.0, distance = 0.0
        var layouts = 0, rowBodies = 0, likeBodies = 0, hoverChanges = 0, moves = 0
        var redraws: String?

        func line(_ name: String) -> String {
            let sorted = frames.sorted()
            func percentile(_ p: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1_000
            }
            let over8 = frames.filter { $0 > 1.0 / 120 }.count, over16 = frames.filter { $0 > 1.0 / 60 }.count
            return String(format: "SCROLL %@: main thread busy %.0f%%, per frame p50 %.2f ms, p95 %.2f ms, max %.1f ms; "
                          + "%d of %d frames over 8.3 ms, %d over 16.7 ms; %.0f%% CPU; %.0f window layouts/s; "
                          + "%.0f row bodies/s, %.0f like-button bodies/s, %d rows under the pointer; "
                          + "list moved %.0f times/s, %.0f pt",
                          name, frames.reduce(0, +) / elapsed * 100, percentile(0.5), percentile(0.95),
                          (sorted.last ?? 0) * 1_000, over8, frames.count, over16, cpu / elapsed * 100,
                          Double(layouts) / elapsed, Double(rowBodies) / elapsed, Double(likeBodies) / elapsed,
                          hoverChanges, Double(moves) / elapsed, distance)
        }
    }

    /// Moves the page `speed` points per second, a step per 120 Hz tick, for
    /// `seconds`. A frame's main-thread time is the wall time between ticks less
    /// the time the run loop slept, so work SwiftUI defers to later passes counts too.
    static func drive(_ scroll: NSScrollView, host: CountingHostingView<some View>, meter: MainThreadMeter,
                      seconds: Double, speed: Double, hover: Bool) async -> Result {
        var result = Result()
        let probe = ScrollProbe.snapshot()
        let layouts = host.layouts, cpuBefore = cpu()
        let started = CACurrentMediaTime()
        let startY = scroll.contentView.bounds.origin.y
        var lastTick = started, lastIdle = meter.idle
        let redraws = ProcessInfo.processInfo.environment["FLOE_SCROLL_REDRAWS"] == "1" ? Redraws() : nil
        // Over the list below the header, in the title column (SwiftUI's global space).
        ScrollProbe.pointer = hover ? CGPoint(x: size.width * 0.45, y: size.height * 0.6) : nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
                let finished = MainActor.assumeIsolated {
                    let now = CACurrentMediaTime()
                    let idle = meter.idle
                    result.frames.append(max(0, (now - lastTick) - (idle - lastIdle)))
                    lastTick = now
                    lastIdle = idle
                    scrollTo(scroll, startY + speed * (now - started))
                    if let redraws { redraws.sample(host.window?.contentView?.superview?.layer) }
                    return now - started >= seconds
                }
                if finished {
                    timer.invalidate()
                    done.resume()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        ScrollProbe.pointer = nil
        result.redraws = redraws?.summary
        result.frames.removeFirst()
        result.elapsed = CACurrentMediaTime() - started
        result.cpu = cpu() - cpuBefore
        result.layouts = host.layouts - layouts
        result.distance = abs(scroll.contentView.bounds.origin.y - startY)
        let after = ScrollProbe.snapshot()
        result.rowBodies = after.rows - probe.rows
        result.likeBodies = after.likes - probe.likes
        result.hoverChanges = after.hovers - probe.hovers
        result.moves = after.moves - probe.moves
        return result
    }

    static func scrollTo(_ scroll: NSScrollView, _ y: Double) {
        let clip = scroll.contentView
        let top = -scroll.contentInsets.top
        let bottom = max(top, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height + scroll.contentInsets.bottom)
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: min(max(y, top), bottom)))
        scroll.reflectScrolledClipView(clip)
    }

    /// AppKit views and layers in the window, by class: SwiftUI hosts some
    /// controls in views, and AppKit walks every view for window regions.
    static func viewCensus(_ window: NSWindow) -> String {
        var views: [String: Int] = [:], layers = 0
        func visit(_ view: NSView) {
            views["\(type(of: view))", default: 0] += 1
            view.subviews.forEach(visit)
        }
        func count(_ layer: CALayer) {
            layers += 1
            layer.sublayers?.forEach(count)
        }
        if let frame = window.contentView?.superview { visit(frame) }
        if let root = window.contentView?.superview?.layer { count(root) }
        let top = views.sorted { $0.value > $1.value }.prefix(6).map { "\($0.value) \($0.key)" }
        return "views \(views.values.reduce(0, +)) (\(top.joined(separator: ", "))), layers \(layers)"
    }

    /// The library page's scroll view: the tallest document in the window.
    static func pageScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    static func settle(_ window: NSWindow, seconds: Double) async {
        for _ in 0..<max(Int(seconds * 10), 1) {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

/// FLOE_SCROLL_REDRAWS=1: which layers got new contents between ticks (drawn
/// again on the main thread), by class, size and position, and the pixels they
/// cost. Walking the layers every tick slows the run, so only the counts mean anything.
@MainActor final class Redraws {
    private var seen: [ObjectIdentifier: ObjectIdentifier] = [:]
    private var counts: [String: (count: Int, pixels: Double)] = [:]

    func sample(_ root: CALayer?) {
        guard let root else { return }
        func visit(_ layer: CALayer) {
            if let contents = layer.contents {
                let id = ObjectIdentifier(contents as AnyObject), key = ObjectIdentifier(layer)
                if let old = seen[key], old != id {
                    let size = layer.bounds.size, scale = layer.contentsScale
                    let frame = layer.convert(layer.bounds, to: root)
                    let name = "\(type(of: layer)) \(Int(size.width))x\(Int(size.height)) at x \(Int(frame.minX))"
                    let entry = counts[name] ?? (0, 0)
                    counts[name] = (entry.count + 1, entry.pixels + size.width * size.height * scale * scale)
                }
                seen[key] = id
            }
            layer.sublayers?.forEach(visit)
        }
        visit(root)
    }

    var summary: String {
        "  redraws: " + counts.sorted { $0.value.pixels > $1.value.pixels }.prefix(8)
            .map { String(format: "%@ ×%d (%.0f Mpx)", $0.key, $0.value.count, $0.value.pixels / 1e6) }
            .joined(separator: ", ")
    }
}

/// How long the main run loop has slept, from observers at both ends of each wait.
final class MainThreadMeter: @unchecked Sendable {
    private(set) var idle = 0.0
    private var sleptAt: Double?

    @MainActor init() {
        let (before, after) = Self.observers(self)
        CFRunLoopAddObserver(CFRunLoopGetMain(), before, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), after, .commonModes)
    }

    /// Last before the wait (after Core Animation's commit), first after it.
    nonisolated static func observers(_ meter: MainThreadMeter) -> (CFRunLoopObserver, CFRunLoopObserver) {
        let before = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max) { _, _ in
            meter.sleptAt = CACurrentMediaTime()
        }!
        let after = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, .min) { _, _ in
            if let start = meter.sleptAt { meter.idle += CACurrentMediaTime() - start }
            meter.sleptAt = nil
        }!
        return (before, after)
    }
}

/// What the production views report when built with `-D SCROLL_BENCHMARK`.
/// An offscreen window never hears the real pointer, so `pointer` stands in for
/// one resting over the list: a row under it takes the hover state.
enum ScrollProbe {
    nonisolated(unsafe) static var rows = 0, likes = 0, hovers = 0, moves = 0
    nonisolated(unsafe) static var pointer: CGPoint?
    static func snapshot() -> (rows: Int, likes: Int, hovers: Int, moves: Int) { (rows, likes, hovers, moves) }
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
