import AppKit
import SwiftUI

/// A real SwiftUI window, using only synthetic text and a monotonic playback
/// fixture. No Spotify session, saved credentials, network request or rendered export.
@main @MainActor
struct LyricsRenderingBenchmark {
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let reducedMotion = environment["FLOE_LYRICS_REDUCE_MOTION"] == "1"
        let changingOnly = environment["FLOE_LYRICS_BENCHMARK_ONLY"] == "changing"
        let seconds = min(max(Double(environment["FLOE_LYRICS_BENCHMARK_SECONDS"] ?? "") ?? 20, 5), 120)
        UserDefaults.standard.setVolatileDomain(["reduceMotion": reducedMotion], forName: UserDefaults.argumentDomain)
        let player = PlayerModel(), lyrics = LyricsModel()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 430, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Floe — synthetic lyric performance check"
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: LyricsView().environment(player).environment(lyrics)
            .preferredColorScheme(.dark).background(Color(red: 0.04, green: 0.05, blue: 0.065)))
        window.contentView = view
        window.orderFrontRegardless()

        if !changingOnly {
            lyrics.fixture(from: 0, every: 3_600)
            await settle()
            snapshot(view, name: "steady", environment: environment)
            await measure("steady lyrics", seconds: 8, clock: player)
        }

        lyrics.fixture(from: player.positionMs(at: Date()) / 1_000 + 0.5, every: 1.25)
        // Reset the view's line clock just as a playback seek/state event does.
        player.seek(toMs: player.positionMs(at: Date()))
        await settle()
        snapshot(view, name: "following", environment: environment)
        await measure(reducedMotion ? "changing lyrics, reduce motion" : "changing lyrics every 1.25 s",
                      seconds: seconds, clock: player)

        // A seek on pause restarts the real view's task; it must then stop waking.
        if !changingOnly {
            player.isPlaying = false
            if case let .loaded(.synced(lines)) = lyrics.state,
               let gap = lines.first(where: { $0.text.isEmpty }) {
                player.seek(toMs: gap.time * 1_000 + 100)
            }
            await settle()
            snapshot(view, name: "paused-gap", environment: environment)
            await measure("paused instrumental gap", seconds: 5, clock: player)
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

    static func measure(_ name: String, seconds: Double, clock: PlayerModel) async {
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let before = cpu(), started = Date(), reads = clock.positionReads
        try? await Task.sleep(for: .seconds(seconds))
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "LYRICS %@: %.2f%% CPU over %.1f s, %d clock reads", name,
                     (cpu() - before) / elapsed * 100, elapsed, clock.positionReads - reads))
    }
}
