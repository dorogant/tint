import Foundation
import os

/// Spotify genres per artist, for the auto preset: one `GET /artists/{id}` at
/// most per song change, cached in memory and in a small file so a song from
/// a known artist costs nothing. Development Mode apps may get the artist with
/// an empty `genres` list; that's cached too (for less time), so such an
/// artist isn't asked again on every song.
actor ArtistGenres {
    struct Answer: Equatable, Sendable {
        /// The first artist (in credit order) with genres, and those genres;
        /// empty when none of the looked-up artists had any.
        var artistID: String?
        var genres: [String] = []
        /// Each artist looked at, and where its genres came from, for the self-test log.
        var trail: [String] = []
    }

    private struct Entry: Codable {
        var genres: [String]
        var fetched: Date
    }

    /// Genres change rarely; an empty answer may just be Development Mode, or a
    /// new artist Spotify hasn't tagged yet, so it's checked again sooner.
    private static let lifetime: TimeInterval = 30 * 86_400
    private static let emptyLifetime: TimeInterval = 3 * 86_400
    private static let capacity = 1500
    /// Only the first few credited artists are worth a look.
    private static let artistsConsidered = 3

    private let fetch: @Sendable (String) async throws -> [String]
    private let file: URL?
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var loaded = false
    /// After a 429 or a refusal, no requests until then.
    private var pausedUntil = Date.distantPast
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "genres")

    init(file: URL? = ArtistGenres.defaultFile, now: @escaping @Sendable () -> Date = Date.init,
         fetch: @escaping @Sendable (String) async throws -> [String]) {
        self.file = file
        self.now = now
        self.fetch = fetch
    }

    init(api: WebAPI) {
        self.init { id in try await api.artist(id).genres ?? [] }
    }

    static var defaultFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Floe/ArtistGenres.json")
    }

    /// The Spotify ID in `spotify:artist:<id>`, or nil for local files and the like.
    static func artistID(fromURI uri: String?) -> String? {
        guard let uri, uri.hasPrefix("spotify:artist:") else { return nil }
        let id = String(uri.dropFirst("spotify:artist:".count))
        return id.isEmpty ? nil : id
    }

    /// The genres of the first credited artist that has any, asking Spotify
    /// about one uncached artist at most. Cancellable: a skipped song's request
    /// is dropped and nothing is cached for it.
    func genres(for artistIDs: [String]) async -> Answer {
        loadIfNeeded()
        var answer = Answer()
        var asked = false
        for id in artistIDs.prefix(Self.artistsConsidered) {
            if let entry = entries[id], isFresh(entry) {
                answer.trail.append("\(id): cached \(entry.genres)")
                if !entry.genres.isEmpty { return answer.with(id, entry.genres) }
                continue
            }
            guard !asked else { answer.trail.append("\(id): not asked (one request per song)"); continue }
            guard now() >= pausedUntil else { answer.trail.append("\(id): not asked (paused after an error)"); break }
            asked = true
            do {
                let genres = try await fetch(id)
                guard !Task.isCancelled else { return answer }
                store(id, genres)
                answer.trail.append("\(id): Spotify returned \(genres)")
                if !genres.isEmpty { return answer.with(id, genres) }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled
                else { return answer }
                answer.trail.append("\(id): \(error.localizedDescription)")
                pause(after: error)
                break
            }
        }
        return answer
    }

    private func isFresh(_ entry: Entry) -> Bool {
        now().timeIntervalSince(entry.fetched) < (entry.genres.isEmpty ? Self.emptyLifetime : Self.lifetime)
    }

    /// Rate limits wait as long as Spotify asks (at least a minute); a refusal
    /// (Development Mode may forbid the endpoint) stops asking for an hour.
    /// Network errors don't pause: the next song simply tries again.
    private func pause(after error: Error) {
        switch error as? WebAPI.Failure {
        case let .rateLimited(seconds): pausedUntil = now().addingTimeInterval(max(60, seconds))
        case let .http(status, _) where status == 403 || status == 404: pausedUntil = now().addingTimeInterval(3600)
        default: break
        }
        if pausedUntil > now() { log.notice("artist genres paused until \(self.pausedUntil, privacy: .public)") }
    }

    private func store(_ id: String, _ genres: [String]) {
        entries[id] = Entry(genres: genres, fetched: now())
        if entries.count > Self.capacity {
            // Forget the oldest tenth at once, so this doesn't sort on every song.
            let oldest = entries.sorted { $0.value.fetched < $1.value.fetched }.prefix(Self.capacity / 10)
            for (key, _) in oldest { entries[key] = nil }
        }
        save()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = saved
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

private extension ArtistGenres.Answer {
    func with(_ id: String, _ genres: [String]) -> Self {
        var answer = self
        answer.artistID = id
        answer.genres = genres
        return answer
    }
}
