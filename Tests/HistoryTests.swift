import Foundation

/// The listening history without the app: what counts as a play, how a play
/// that goes on is stored, and what survives a restart.
@main
struct HistoryTests {
    nonisolated(unsafe) static var checks = 0

    static func track(_ id: String, seconds: Double = 200) -> TrackInfo {
        TrackInfo(uri: "spotify:track:\(id)", name: "Song \(id)", artists: [.init(name: "Artist", uri: "spotify:artist:a")],
                  album: "Album", durationMs: seconds * 1000, explicit: false, coverURL: nil)
    }

    static func main() async {
        trackerChecks()
        await storeChecks()
        print("PASS: \(checks) listening history checks (what counts, plays that go on, pauses, the file, the limit)")
    }

    static func trackerChecks() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        var tracker = ListeningTracker()
        check(tracker.update(track: track("a"), isPlaying: true, now: at(0)) == nil, "a song that has just started isn't a play")
        check(tracker.untilCounted == 30, "a long song counts after thirty seconds (\(tracker.untilCounted ?? -1))")
        check(tracker.update(track: track("a"), isPlaying: true, now: at(10)) == nil, "ten seconds aren't a play")
        // Skipped: the next song starts and the first leaves nothing.
        check(tracker.update(track: track("b"), isPlaying: true, now: at(12)) == nil, "a song skipped after twelve seconds must leave no play")
        let counted = tracker.update(track: track("b"), isPlaying: true, now: at(43))
        check(counted?.uri == "spotify:track:b" && counted?.listenedSeconds == 31 && counted?.playedAt == at(12),
              "a song must count once thirty seconds of it have played (\(String(describing: counted)))")
        check(tracker.untilCounted == nil, "a song that has counted isn't waited for again")
        check(tracker.update(track: track("b"), isPlaying: true, now: at(43.5)) == nil, "the same second isn't stored twice")
        // Paused for a minute: the minute isn't listening.
        let paused = tracker.update(track: track("b"), isPlaying: false, now: at(60))
        check(paused?.listenedSeconds == 48 && paused?.playedAt == at(12), "a pause must store the play so far (\(String(describing: paused)))")
        check(tracker.update(track: track("b"), isPlaying: true, now: at(120)) == nil, "time paused isn't listened")
        let finished = tracker.update(track: track("c", seconds: 40), isPlaying: true, now: at(180))
        check(finished?.uri == "spotify:track:b" && finished?.listenedSeconds == 108 && finished?.playedAt == at(12),
              "the next song must close the last with its full length, under the same start (\(String(describing: finished)))")
        check(tracker.untilCounted == 20, "a forty-second song counts at half (\(tracker.untilCounted ?? -1))")
        let short = tracker.update(track: nil, isPlaying: false, now: at(201))
        check(short?.uri == "spotify:track:c" && short?.listenedSeconds == 21, "a short song counts from its half (\(String(describing: short)))")
        check(tracker.update(track: nil, isPlaying: false, now: at(500)) == nil && tracker.untilCounted == nil, "nothing playing is nothing to store")
    }

    static func storeChecks() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("floe-history-\(getpid())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("deep/plays.jsonl")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func play(_ id: String, at offset: Double, seconds: Int = 60) -> Play {
            Play(uri: "spotify:track:\(id)", name: "Song \(id)", artists: ["Artist"], artistURIs: ["spotify:artist:a"], album: "Album",
                 cover: URL(string: "https://i.scdn.co/image/\(id)"), durationMs: 200_000, playedAt: start.addingTimeInterval(offset), listenedSeconds: seconds)
        }
        var history = ListeningHistory(file: file)
        await history.record(play("a", at: 0, seconds: 31))
        await history.record(play("a", at: 0, seconds: 180))
        await history.record(play("b", at: 300))
        await history.record(play("a", at: 600))
        var plays = await history.plays()
        check(plays.map(\.uri) == ["spotify:track:a", "spotify:track:b", "spotify:track:a"] && plays.last?.listenedSeconds == 180,
              "a play that went on must replace its earlier self, and a later play of the song must be its own (\(plays.map(\.listenedSeconds)))")
        check(plays.first?.trackID == "a" && plays.first?.artistLine == "Artist", "a play must give its Spotify ID and its artists")
        let recent = await history.plays(since: start.addingTimeInterval(200))
        check(recent.count == 2, "plays since a moment must leave out the earlier ones (\(recent.count))")
        let heard = await history.heard()
        check(heard == ["spotify:track:a", "spotify:track:b"], "every song played must be known as heard")

        // A new launch reads the same history from the file.
        history = ListeningHistory(file: file)
        plays = await history.plays()
        check(plays.count == 3 && plays.last?.listenedSeconds == 180 && plays.last?.cover?.absoluteString == "https://i.scdn.co/image/a",
              "the history must survive a restart as it was (\(plays.count) plays)")
        check(plays.first?.playedAt == start.addingTimeInterval(600), "dates must come back exact")

        // Past the limit the oldest go, and the file is rewritten without them.
        for i in 0..<(ListeningHistory.limit + 500) { await history.record(play("n\(i)", at: 1000 + Double(i))) }
        history = ListeningHistory(file: file)
        let kept = await history.plays()
        check(kept.count == ListeningHistory.limit && kept.first?.uri == "spotify:track:n\(ListeningHistory.limit + 499)" && !kept.contains { $0.uri == "spotify:track:b" },
              "only the newest plays up to the limit are kept (\(kept.count))")
        // A song left playing is written again and again; once the file holds a
        // quarter more lines than plays, the next launch writes it out clean.
        for seconds in 31..<6000 { await history.record(play("z", at: 90_000, seconds: seconds)) }
        history = ListeningHistory(file: file)
        let last = await history.plays().first
        let lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").count ?? 0
        check(lines <= ListeningHistory.limit, "a file grown well past its plays must be rewritten (\(lines) lines)")
        check(last?.uri == "spotify:track:z" && last?.listenedSeconds == 5999, "the rewrite must keep each play's last word (\(last?.listenedSeconds ?? -1))")

        // A damaged line costs that play and no other.
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("{ not a play\n".utf8))
            try? handle.close()
        }
        history = ListeningHistory(file: file)
        await history.record(play("y", at: 90_100))
        let after = await history.plays()
        check(after.first?.uri == "spotify:track:y" && after.dropFirst().first?.uri == "spotify:track:z", "a damaged line must cost only itself")
        await history.clear()
        history = ListeningHistory(file: file)
        let cleared = await history.plays()
        check(cleared.isEmpty, "a cleared history must stay empty")
        let memoryOnly = ListeningHistory(file: nil)
        await memoryOnly.record(play("m", at: 0))
        let inMemory = await memoryOnly.plays()
        check(inMemory.count == 1, "without a file the history still holds for the run")
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition {
            print("FAIL: \(message())")
            exit(1)
        }
    }
}
