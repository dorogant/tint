import Foundation

/// Scripted playback check for development, enabled with the launch argument
/// `-FloeSelfTest YES` (optionally `-FloeSelfTestTrack spotify:track:…`).
/// Logs to stdout: play → pause → seek → resume, with audio counters and RAM.
/// Don't touch playback while it runs: an outside pause is reported as such.
@MainActor
enum SelfTest {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "FloeSelfTest") }

    static func run(_ model: PlayerModel) async {
        let track = UserDefaults.standard.string(forKey: "FloeSelfTestTrack") ?? PlayerView.defaultTrack
        let start = Date()
        let forward = model.core.onEvent
        model.core.onEvent = { event in
            let t = String(format: "%6.2f", Date().timeIntervalSince(start))
            say("  t=\(t) event \(String(describing: event).prefix(90))")
            forward?(event)
        }
        say("waiting for session")
        guard await wait(timeout: 600, { model.isConnected }) else { return finish(false, "no session") }
        let ram0 = MemoryFootprint.currentMB

        say("load \(track)")
        guard model.play(uri: track) else { return finish(false, "load rejected") }
        guard await wait(timeout: 30, { model.isPlaying }) else { return finish(false, "never started playing") }
        say("playing: \(model.track?.name ?? "?") – \(model.track?.artists.joined(separator: ", ") ?? "?")")

        var ok = true
        func interrupted() -> Bool { !model.isPlaying }
        _ = model.core.takeStats()
        var frames = model.core.takeStats().frames_rendered
        try? await Task.sleep(for: .seconds(6))
        if interrupted() { return finish(false, "playback was paused from outside the test") }
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
        let cpuStart = cpuSeconds(), wallStart = Date()
        var peak: Float = 0
        for _ in 0..<5 { // sampled so stalls show up in the log
            try? await Task.sleep(for: .seconds(1))
            let sample = model.core.takeStats()
            peak = max(peak, sample.peak)
            let rendered = Double(sample.frames_rendered - frames) / 44_100
            say(String(format: "  t=%6.2f rendered %.2f s since resume, playing=%@",
                       Date().timeIntervalSince(start), rendered, model.isPlaying ? "yes" : "no"))
        }
        let cpu = (cpuSeconds() - cpuStart) / Date().timeIntervalSince(wallStart) * 100
        if interrupted() { return finish(false, "playback was paused from outside the test") }
        stats = model.core.takeStats()
        let position = model.positionMs(at: Date()) / 1000
        say(String(format: "after seek to 60 s + 5 s playing: position %.1f s, rendered %.2f s, peak %.2f",
                   position, Double(stats.frames_rendered - frames) / 44_100, max(peak, stats.peak)))
        say(String(format: "CPU while playing: %.1f%% of one core; underruns so far: %llu", cpu, stats.underruns))
        ok = ok && (63...68).contains(position) && max(peak, stats.peak) > 0.01

        say(String(format: "RAM (phys_footprint): %.1f MB before playback, %.1f MB while playing",
                   ram0, MemoryFootprint.currentMB))
        model.pause()
        finish(ok, ok ? "all checks passed" : "a check failed")
    }

    /// User + system CPU time of this process.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
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
