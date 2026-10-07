import Foundation

/// Scripted playback check for development, enabled with the launch argument
/// `-FloeSelfTest YES` (optionally `-FloeSelfTestTrack spotify:track:…`).
/// Logs to stdout: play → pause → seek → resume, with audio counters and RAM.
@MainActor
enum SelfTest {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "FloeSelfTest") }

    static func run(_ model: PlayerModel) async {
        let track = UserDefaults.standard.string(forKey: "FloeSelfTestTrack") ?? PlayerView.defaultTrack
        say("waiting for session")
        guard await wait(timeout: 60, { model.isConnected }) else { return finish(false, "no session") }
        let ram0 = MemoryFootprint.currentMB

        say("load \(track)")
        guard model.play(uri: track) else { return finish(false, "load rejected") }
        guard await wait(timeout: 30, { model.isPlaying }) else { return finish(false, "never started playing") }
        say("playing: \(model.track?.name ?? "?") – \(model.track?.artists.joined(separator: ", ") ?? "?")")

        var ok = true
        _ = model.core.takeStats()
        var frames = model.core.takeStats().frames_rendered
        try? await Task.sleep(for: .seconds(6))
        var stats = model.core.takeStats()
        let played = Double(stats.frames_rendered - frames) / 44_100
        say(String(format: "6 s of playback rendered %.2f s of audio, peak %.2f, underruns %llu",
                   played, stats.peak, stats.underruns))
        ok = ok && played > 5 && stats.peak > 0.01

        model.pause()
        frames = model.core.takeStats().frames_rendered
        try? await Task.sleep(for: .seconds(3))
        stats = model.core.takeStats()
        let leaked = Double(stats.frames_rendered - frames) / 44_100
        say(String(format: "paused 3 s: rendered %.2f s (expect 0), position %.1f s",
                   leaked, model.positionMs(at: Date()) / 1000))
        ok = ok && leaked < 0.05 && !model.isPlaying

        model.seek(toMs: 60_000)
        model.resume()
        guard await wait(timeout: 15, { model.isPlaying }) else { return finish(false, "resume failed") }
        frames = model.core.takeStats().frames_rendered
        try? await Task.sleep(for: .seconds(5))
        stats = model.core.takeStats()
        let position = model.positionMs(at: Date()) / 1000
        say(String(format: "after seek to 60 s + 5 s playing: position %.1f s, rendered %.2f s, peak %.2f",
                   position, Double(stats.frames_rendered - frames) / 44_100, stats.peak))
        ok = ok && (63...68).contains(position) && stats.peak > 0.01

        say(String(format: "RAM (phys_footprint): %.1f MB before playback, %.1f MB while playing",
                   ram0, MemoryFootprint.currentMB))
        model.pause()
        finish(ok, ok ? "all checks passed" : "a check failed")
    }

    private static func wait(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private static func say(_ message: String) {
        print("[selftest] \(message)")
        fflush(stdout)
    }

    private static func finish(_ passed: Bool, _ detail: String) {
        say("\(passed ? "PASS" : "FAIL"): \(detail)")
    }
}
