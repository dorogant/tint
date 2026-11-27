import Foundation

// Stand-ins for everything a mix touches outside itself: the recommendation
// service, the user's history and library, and the player. Nothing here opens
// a socket or plays a sound. The stubs are set up and read by a test only
// while the model has nothing in flight (`await mix.settled()`); their own
// methods, which the model calls from other threads, take the lock.

/// A Spotify-shaped track ID (22 letters and digits) that says what it is.
func tid(_ prefix: String, _ number: Int) -> String {
    let tail = "\(number)"
    return prefix + String(repeating: "0", count: max(0, 22 - prefix.count - tail.count)) + tail
}

enum Synthetic {
    /// Ninety made-up songs for one fetch, each by its own artist, three
    /// minutes twenty long, with valence and energy spread over the whole range.
    static func rows(batch: Int, count: Int = 90) -> [MixFixtures.Row] {
        (0..<count).map { index in
            (id: tid("b\(batch)n", index), title: "Song \(batch)-\(index)", artists: ["Artist \(batch)-\(index)"],
             durationMs: 200_000, valence: Double((index * 37 + batch * 11) % 100) / 100,
             energy: Double((index * 53 + batch * 29) % 100) / 100)
        }
    }

    static func track(_ id: String, name: String? = nil, artist: String = "Someone") -> Track {
        Track(id: id, uri: "spotify:track:\(id)", name: name ?? "Liked \(id)", durationMs: 200_000, explicit: false,
              artists: [ArtistRef(id: "artist", uri: "spotify:artist:artist", name: artist)], album: nil,
              trackNumber: 1, discNumber: 1, isLocal: false, isPlayable: true)
    }
}

/// Answers from tables instead of ReccoBeats, and remembers what it was asked.
final class StubCatalog: MixCatalog, @unchecked Sendable {
    private let lock = NSLock()
    /// What a fetch with these seeds answers; the Int counts fetches from 1.
    var respond: @Sendable ([String], Int) -> [MixFixtures.Row] = { _, fetch in Synthetic.rows(batch: fetch) }
    /// Features by ID, beyond those of the rows handed out.
    var features: [String: MixFeatures] = [:]
    /// Seeds the service doesn't know: a fetch made only of these answers 4002.
    var unknownSeeds: Set<String> = []
    var failure: (any Error)?
    private(set) var seedLog: [[String]] = []
    private(set) var targetLog: [(valence: Double?, energy: Double?)] = []
    private(set) var featureLog: [[String]] = []
    /// Set to make the next fetch wait until `release()`.
    var holds = false
    private var held: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { lock.withLock { held != nil } }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            holds = false
            return held
        }
        waiting?.resume()
    }

    func recommendations(seeds: [String], valence: Double?, energy: Double?) async throws -> [MixSong] {
        if lock.withLock({ holds }) {
            await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
        }
        return try lock.withLock {
            seedLog.append(seeds)
            targetLog.append((valence, energy))
            if let failure { throw failure }
            if seeds.allSatisfy(unknownSeeds.contains) { throw ReccoBeats.Failure.unknownSeeds }
            let rows = respond(seeds, seedLog.count)
            for row in rows { features[row.id] = MixFeatures(valence: row.valence, energy: row.energy) }
            return MixFixtures.songs(rows)
        }
    }

    func features(for ids: [String]) async throws -> [String: MixFeatures] {
        try lock.withLock {
            featureLog.append(ids)
            if let failure { throw failure }
            return features.filter { ids.contains($0.key) }
        }
    }
}

/// The user's history and library, from arrays.
final class StubLibrary: MixLibrary, @unchecked Sendable {
    private let lock = NSLock()
    /// Plays newest first, with how many seconds ago each was.
    var plays: [(id: String, secondsAgo: TimeInterval)] = []
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var heardIDs: Set<String> = []
    var recent: [String] = []
    var likedTracks: [Track] = []
    var likedIDs: Set<String> = []
    var spotifyFails = false
    private(set) var likedPagesAsked: [Int] = []
    private(set) var likedChecks: [[String]] = []
    private(set) var lookups: [String] = []

    struct Offline: LocalizedError { var errorDescription: String? { "offline" } }

    func listened(since date: Date) async -> [String] {
        lock.withLock { plays.filter { now.addingTimeInterval(-$0.secondsAgo) >= date }.map(\.id) }
    }

    func heard() async -> Set<String> { lock.withLock { heardIDs } }

    func recentlyPlayed() async throws -> [String] {
        try lock.withLock {
            if spotifyFails { throw Offline() }
            return recent
        }
    }

    func likedSongs(offset: Int) async throws -> (tracks: [Track], total: Int) {
        try lock.withLock {
            if spotifyFails { throw Offline() }
            likedPagesAsked.append(offset)
            return (Array(likedTracks.dropFirst(offset).prefix(50)), likedTracks.count)
        }
    }

    func liked(among ids: [String]) async throws -> Set<String> {
        try lock.withLock {
            if spotifyFails { throw Offline() }
            likedChecks.append(ids)
            return likedIDs.intersection(ids)
        }
    }

    func track(_ id: String) async throws -> Track {
        try lock.withLock {
            if spotifyFails { throw Offline() }
            lookups.append(id)
            return Synthetic.track(id, name: "Looked up \(id)")
        }
    }
}

/// Spotify as a mix sees it: one song playing and a queue that only grows at
/// its end and shrinks at its front.
@MainActor final class FakePlayer: MixPlayer {
    var playingURI: String?
    var connected = true
    private(set) var started: [MixSong] = []
    private(set) var queue: [MixSong] = []
    /// Every song ever queued, for checking nothing is added after a mix lets go.
    private(set) var everQueued: [MixSong] = []

    func start(_ song: MixSong, details: Track?) -> Bool {
        guard connected else { return false }
        started.append(song)
        return true
    }

    func queue(_ song: MixSong) -> Bool {
        guard connected else { return false }
        queue.append(song)
        everQueued.append(song)
        return true
    }

    /// The song just started begins to play.
    func begin() -> MixNowPlaying? {
        guard let song = started.last else { return nil }
        playingURI = song.uri
        return MixNowPlaying(uri: song.uri, title: song.title, artists: song.artists)
    }

    /// The song playing ends and the queue's first takes over.
    func advance() -> MixNowPlaying? {
        guard !queue.isEmpty else { return nil }
        let song = queue.removeFirst()
        playingURI = song.uri
        return MixNowPlaying(uri: song.uri, title: song.title, artists: song.artists)
    }
}

/// Hands canned answers to the ReccoBeats client and keeps the requests.
final class StubTransport: MixTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var answer: @Sendable (URLRequest) -> (Data, Int) = { _ in (Data(), 500) }

    func answer(to request: URLRequest) async throws -> (Data, Int) {
        lock.withLock {
            requests.append(request)
            return answer(request)
        }
    }
}
