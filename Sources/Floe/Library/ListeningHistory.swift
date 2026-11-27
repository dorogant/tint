import Foundation
import Observation

/// One song listened to in Tint: enough to show it again, count it, and start
/// a mix from it without asking Spotify.
struct Play: Codable, Equatable, Sendable {
    var uri: String
    var name: String
    var artists: [String]
    var artistURIs: [String]
    var album: String?
    var cover: URL?
    var durationMs: Int
    /// When it started. With `uri`, what tells one play from another.
    var playedAt: Date
    var listenedSeconds: Int

    /// The Spotify ID, for catalogue tracks.
    var trackID: String? { uri.hasPrefix("spotify:track:") ? String(uri.dropFirst("spotify:track:".count)) : nil }
    var artistLine: String { artists.joined(separator: ", ") }
}

/// What Tint has played, on this Mac only: Spotify's own history holds fifty
/// songs and says nothing of how long each was listened to, and a mix can only
/// leave out what you've heard if something remembers it. One JSON line per
/// play in Application Support, appended as songs play; a play that goes on is
/// written again, and the later line wins.
actor ListeningHistory {
    static let shared = ListeningHistory(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Floe/History/plays.jsonl"))

    /// Plays kept. At fifty songs a day that is over a year, and about 4 MB on disk.
    static let limit = 20_000
    private let file: URL?
    /// Oldest first. Read from disk on first use.
    private var plays: [Play]?
    private var handle: FileHandle?

    /// Without a file, history lives for the run only (tests, a disk that can't be written).
    init(file: URL?) {
        self.file = file
    }

    /// Adds a play, or replaces the one of the same song and start with its newer length.
    func record(_ play: Play) {
        var all = loaded()
        if let index = all.lastIndex(where: { $0.uri == play.uri && $0.playedAt == play.playedAt }) {
            all[index] = play
        } else {
            all.append(play)
        }
        plays = all
        append(play)
    }

    /// Newest first.
    func plays(since date: Date = .distantPast) -> [Play] {
        loaded().reversed().prefix { $0.playedAt >= date }.map { $0 }
    }

    /// Every song ever played here, by URI.
    func heard() -> Set<String> {
        Set(loaded().map(\.uri))
    }

    func clear() {
        plays = []
        try? handle?.close()
        handle = nil
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func loaded() -> [Play] {
        if let plays { return plays }
        var all: [Play] = []
        var lines = 0
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = Self.decoder
            var index: [String: Int] = [:]
            for line in data.split(separator: UInt8(ascii: "\n")) {
                lines += 1
                guard let play = try? decoder.decode(Play.self, from: line) else { continue }
                let key = "\(play.uri)#\(play.playedAt.timeIntervalSince1970)"
                if let at = index[key] {
                    all[at] = play
                } else {
                    index[key] = all.count
                    all.append(play)
                }
            }
        }
        if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
        plays = all
        // Rewritten once it holds a good deal more lines than plays: updates and old plays past the limit.
        if lines > all.count + all.count / 4 + 64 { rewrite(all) }
        return all
    }

    private func append(_ play: Play) {
        guard let file, var line = try? Self.encoder.encode(play) else { return }
        line.append(UInt8(ascii: "\n"))
        if handle == nil {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: line)
    }

    private func rewrite(_ all: [Play]) {
        guard let file else { return }
        var data = Data()
        for play in all {
            guard let line = try? Self.encoder.encode(play) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? handle?.close()
        handle = nil
        try? data.write(to: file, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// Decides when a song counts as listened to and for how long. A song counts
/// after thirty seconds of it, or half of it if it's shorter than a minute, so
/// skipping through a list leaves no trace. Fed every change of song and of
/// playing; time only runs while playing.
struct ListeningTracker {
    private var track: TrackInfo?
    private var startedAt = Date.distantPast
    private var listened: TimeInterval = 0
    private var playingSince: Date?
    /// Seconds in the last play handed out for this song, to hand out a longer one later.
    private var reported = 0

    /// The play to store now, if any: a song that has just counted, or one that
    /// counted before and has gone on since (the same `playedAt`, more seconds).
    mutating func update(track newTrack: TrackInfo?, isPlaying: Bool, now: Date) -> Play? {
        if let playingSince { listened += max(0, now.timeIntervalSince(playingSince)) }
        let result = play()
        if newTrack?.uri != track?.uri {
            track = newTrack
            startedAt = now
            listened = 0
            reported = 0
        } else if result != nil {
            reported = Int(listened)
        }
        playingSince = isPlaying && track != nil ? now : nil
        return result
    }

    /// Seconds of playing until the current song counts; nil once it has, or with nothing playing.
    var untilCounted: TimeInterval? {
        guard let track, playingSince != nil, reported == 0 else { return nil }
        return max(0, Self.threshold(for: track) - listened)
    }

    private func play() -> Play? {
        guard let track, listened >= Self.threshold(for: track), Int(listened) > reported else { return nil }
        return Play(uri: track.uri, name: track.name, artists: track.artists.map(\.name), artistURIs: track.artists.compactMap(\.uri),
                    album: track.album, cover: track.coverURL, durationMs: Int(track.durationMs),
                    playedAt: startedAt, listenedSeconds: Int(listened))
    }

    static func threshold(for track: TrackInfo) -> TimeInterval {
        track.durationMs > 0 ? min(30, track.durationMs / 2000) : 30
    }
}

/// Feeds the tracker from the player and the history from the tracker. The app
/// tells it of every change, and once more when the song playing is due to count.
@MainActor @Observable final class ListeningRecorder {
    @ObservationIgnored private var tracker = ListeningTracker()
    @ObservationIgnored let history: ListeningHistory
    /// Goes up with every play stored, for pages that show the history.
    private(set) var revision = 0

    init(history: ListeningHistory = .shared) {
        self.history = history
    }

    /// Returns how long to wait, while this song keeps playing, before telling it again.
    func update(track: TrackInfo?, isPlaying: Bool, now: Date = Date()) async -> TimeInterval? {
        if let play = tracker.update(track: track, isPlaying: isPlaying, now: now) {
            await history.record(play)
            revision += 1
        }
        return tracker.untilCounted
    }
}
