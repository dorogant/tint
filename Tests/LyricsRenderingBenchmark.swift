import AppKit
import SwiftUI

/// A real SwiftUI window, using only synthetic text and a monotonic playback
/// fixture. No Spotify session, saved credentials, network request or rendered export.
/// The window sits far off every display, so nothing appears on screen.
@main @MainActor
struct LyricsRenderingBenchmark {
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let environment = ProcessInfo.processInfo.environment
        let reducedMotion = environment["FLOE_LYRICS_REDUCE_MOTION"] == "1"
        let only = environment["FLOE_LYRICS_BENCHMARK_ONLY"]
        let seconds = min(max(Double(environment["FLOE_LYRICS_BENCHMARK_SECONDS"] ?? "") ?? 20, 5), 120)
        UserDefaults.standard.setVolatileDomain(["reduceMotion": reducedMotion], forName: UserDefaults.argumentDomain)
        // FLOE_LYRICS_LOOK_DIR=<dir> renders the instrumental gap's look (blur, glow, breathing) instead.
        if let path = environment["FLOE_LYRICS_LOOK_DIR"] {
            await LyricsLook.render(to: URL(fileURLWithPath: path, isDirectory: true))
            return
        }
        let player = PlayerModel(), lyrics = LyricsModel()
        let origin = CGPoint(x: -30_000, y: -30_000)
        let window = OffscreenWindow(contentRect: NSRect(origin: origin, size: CGSize(width: 430, height: 760)),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tint — synthetic lyric performance check"
        window.isReleasedWhenClosed = false
        let view = CountingHostingView(rootView: AnyView(LyricsView().environment(player).environment(lyrics)
            .preferredColorScheme(.dark).background(Color(red: 0.04, green: 0.05, blue: 0.065))))
        window.contentView = view
        window.orderFrontRegardless()
        window.setFrameOrigin(origin)
        func runs(_ name: String) -> Bool { only == nil || only == name }

        if runs("steady") {
            lyrics.fixture(from: 0, every: 3_600)
            await settle()
            snapshot(view, name: "steady", environment: environment)
            await measure("steady lyrics", seconds: 8, clock: player, host: view)
        }

        if runs("changing") {
            lyrics.fixture(from: player.positionMs(at: Date()) / 1_000 + 0.5, every: 1.25)
            // Reset the view's line clock just as a playback seek/state event does.
            player.seek(toMs: player.positionMs(at: Date()))
            await settle()
            snapshot(view, name: "following", environment: environment)
            await measure(reducedMotion ? "changing lyrics, reduce motion" : "changing lyrics every 1.25 s",
                          seconds: seconds, clock: player, host: view)
        }

        // An instrumental gap while playing: the "…" breathes, nothing else moves.
        if runs("gap") {
            player.isPlaying = true
            let now = player.positionMs(at: Date()) / 1_000
            // Line 5 of every eight is the empty one; make it current, the next an hour away.
            lyrics.fixture(from: now - 5 * 3_600 - 1, every: 3_600)
            player.seek(toMs: player.positionMs(at: Date()))
            await settle()
            snapshot(view, name: "playing-gap", environment: environment)
            await measure("playing instrumental gap", seconds: 8, clock: player, host: view)
        }

        // A seek on pause restarts the real view's task; it must then stop waking.
        if runs("paused") {
            player.isPlaying = false
            if case let .loaded(.synced(lines)) = lyrics.state,
               let gap = lines.first(where: { $0.text.isEmpty }) {
                player.seek(toMs: gap.time * 1_000 + 100)
            }
            await settle()
            snapshot(view, name: "paused-gap", environment: environment)
            await measure("paused instrumental gap", seconds: 5, clock: player, host: view)
        }
        window.close()
        print("PASS: synthetic lyric rendering benchmark completed; test window closed")
    }

    static func settle() async { try? await Task.sleep(for: .seconds(2)) }
    static func snapshot(_ view: NSView, name: String, environment: [String: String]) {
        guard let path = environment["FLOE_LYRICS_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        } catch { print("Synthetic lyric snapshot failed: \(error.localizedDescription)") }
    }

    /// CPU, the line clock's reads, and how often SwiftUI laid out the window:
    /// a continuous SwiftUI effect shows up as one layout per frame.
    static func measure(_ name: String, seconds: Double, clock: PlayerModel, host: CountingHostingView) async {
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let before = cpu(), started = Date(), reads = clock.positionReads, layouts = host.layouts
        try? await Task.sleep(for: .seconds(seconds))
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "LYRICS %@: %.2f%% CPU over %.1f s, %d clock reads, %.1f window layouts/s", name,
                     (cpu() - before) / elapsed * 100, elapsed, clock.positionReads - reads,
                     Double(host.layouts - layouts) / elapsed))
    }
}

/// Counts SwiftUI's passes over the window.
final class CountingHostingView: NSHostingView<AnyView> {
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
