import Foundation

/// One song somebody listened to, as ListenBrainz tells it.
struct FriendListen: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
    /// nil for the song playing now: ListenBrainz gives that one no time.
    var listenedAt: Date?
    /// The Spotify track, when the listen says which one it was.
    var spotifyID: String?
    /// The artists one by one with their Spotify IDs, which only listens that
    /// came through ListenBrainz's Spotify connection carry.
    var spotifyArtists: [SpotifyArtist] = []
    /// From the Cover Art Archive, when ListenBrainz matched the song to a release.
    var cover: URL?
    var durationMs: Int?

    struct SpotifyArtist: Equatable, Sendable {
        var id: String
        var name: String
    }

    var uri: String? { spotifyID.map { "spotify:track:\($0)" } }
    /// What to type into Search for a song with no Spotify link.
    var searchText: String { "\(artist) \(title)" }
}

struct FriendArtist: Equatable, Sendable {
    var name: String
    var listens: Int
}

/// What ListenBrainz's answers mean. Its listens are whatever each player
/// sent, so every field but the song's and the artist's name may be missing or
/// of another type; anything unusable is skipped rather than failing the list.
enum ListenBrainz {
    struct Malformed: Error {}

    /// The listens of `…/listens` and `…/playing-now`, newest first as sent.
    static func listens(in data: Data) throws -> [FriendListen] {
        guard let payload = payload(in: data), let listens = payload["listens"] as? [Any] else { throw Malformed() }
        return listens.compactMap { ($0 as? [String: Any]).flatMap(listen) }
    }

    /// The artists of `/1/stats/user/<name>/artists`.
    static func topArtists(in data: Data) throws -> [FriendArtist] {
        guard let payload = payload(in: data), let artists = payload["artists"] as? [Any] else { throw Malformed() }
        return artists.compactMap { artist in
            guard let artist = artist as? [String: Any], let name = artist["artist_name"] as? String, !name.isEmpty else { return nil }
            return FriendArtist(name: name, listens: (artist["listen_count"] as? NSNumber)?.intValue ?? 0)
        }
    }

    static func listenCount(in data: Data) throws -> Int {
        guard let count = payload(in: data)?["count"] as? NSNumber else { throw Malformed() }
        return count.intValue
    }

    static func following(in data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = object["following"] as? [Any] else { throw Malformed() }
        return names.compactMap { $0 as? String }
    }

    private static func payload(in data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["payload"] as? [String: Any]
    }

    private static func listen(_ listen: [String: Any]) -> FriendListen? {
        guard let track = listen["track_metadata"] as? [String: Any],
              let title = track["track_name"] as? String, !title.isEmpty,
              let artist = track["artist_name"] as? String, !artist.isEmpty else { return nil }
        let info = track["additional_info"] as? [String: Any] ?? [:]
        let mapping = track["mbid_mapping"] as? [String: Any] ?? [:]
        let links = [info["spotify_id"] as? String, info["origin_url"] as? String]
            + ((mapping["url_rels"] as? [[String: Any]]) ?? []).map { $0["url"] as? String }
        var result = FriendListen(title: title, artist: artist)
        result.album = (track["release_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        result.listenedAt = (listen["listened_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        result.spotifyID = links.lazy.compactMap { $0.flatMap { spotifyID(of: "track", in: $0) } }.first
        result.cover = cover(mapping)
        result.durationMs = number(info["duration_ms"]).map(Int.init) ?? number(info["duration"]).map { Int($0 * 1000) }
        // Only when the names and the links pair up; otherwise there's no telling which is whose.
        if let ids = info["spotify_artist_ids"] as? [String], let names = info["artist_names"] as? [String], ids.count == names.count {
            let artists = zip(ids, names).compactMap { link, name in
                spotifyID(of: "artist", in: link).map { FriendListen.SpotifyArtist(id: $0, name: name) }
            }
            if artists.count == ids.count { result.spotifyArtists = artists }
        }
        return result
    }

    /// Players send lengths as numbers or as text.
    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    /// The ID in an `open.spotify.com/track/…` address (with or without a
    /// country prefix and a query) or a `spotify:track:…` URI; nil for
    /// anything else, such as the Bandcamp and YouTube pages `origin_url` often holds.
    static func spotifyID(of kind: String, in link: String) -> String? {
        let pattern = "(?:open\\.spotify\\.com/(?:intl-[A-Za-z-]+/)?\(kind)/|spotify:\(kind):)([A-Za-z0-9]{22})(?![A-Za-z0-9])"
        guard let match = link.range(of: pattern, options: .regularExpression) else { return nil }
        return String(link[match].suffix(22))
    }

    /// The 250-pixel front cover of the release the song was matched to.
    private static func cover(_ mapping: [String: Any]) -> URL? {
        guard let release = mapping["caa_release_mbid"] as? String, UUID(uuidString: release) != nil,
              let id = (mapping["caa_id"] as? NSNumber)?.int64Value, id > 0 else { return nil }
        return URL(string: "https://coverartarchive.org/release/\(release.lowercased())/\(id)-250.jpg")
    }
}

// MARK: - Client

/// The network under the client, so tests can answer from saved files.
protocol ListenBrainzTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Time as the client's pacing sees it, so tests can run it without waiting.
protocol PacingClock: Sendable {
    /// Seconds from any fixed start.
    var now: TimeInterval { get }
    func sleep(for seconds: TimeInterval) async throws
}

struct SystemPacingClock: PacingClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(for seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

struct URLSessionTransport: ListenBrainzTransport {
    let session: URLSession

    init() {
        // Nothing here is worth keeping on disk, and stale answers would show friends as still listening.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

/// ListenBrainz's public API, read only and without a key: what people who
/// connected a player to it are listening to. Every request waits its turn in
/// one line, so however many friends there are and whatever asks, the API sees
/// one stream that keeps to its rules: at most one call a second, and none
/// while its rate-limit headers say the window is used up.
actor ListenBrainzClient {
    enum Failure: Error, Equatable {
        /// No account by that name (HTTP 404).
        case noSuchUser
        /// The account exists but doesn't show this (401 or 403).
        case hidden
        /// The limit is used up for longer than is worth waiting in line.
        case rateLimited(retryIn: TimeInterval)
        case http(Int)
        /// The request never got an answer: offline, timed out, no such host.
        case network
        case malformed
    }

    enum StatsRange: String, Sendable { case thisWeek = "this_week", lastWeek = "week" }

    /// "All users of the API must ensure that each of their client applications
    /// never make more than ONE call per second" (ListenBrainz's API documentation).
    static let spacing: TimeInterval = 1
    /// A wait longer than this fails the request instead of holding the line.
    static let longestWait: TimeInterval = 30
    /// When a 429 comes without saying how long to wait. The window has been ten seconds.
    private static let unstatedWait: TimeInterval = 10
    /// ListenBrainz asks every client to name itself and give a way to reach its
    /// makers: `Name/version ( contact-url )`. The page is Tint's public one,
    /// the same LRCLIB is given.
    static let userAgent = "Tint/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.0") ( https://github.com/dorogant/tint )"
    private static let base = "https://api.listenbrainz.org/1/"

    private let transport: any ListenBrainzTransport
    private let clock: any PacingClock
    /// The earliest the next request may start.
    private var notBefore: TimeInterval = 0
    /// One request at a time; the rest wait here in the order they came.
    private var busy = false
    private var line: [CheckedContinuation<Void, Never>] = []

    init(transport: any ListenBrainzTransport = URLSessionTransport(), clock: any PacingClock = SystemPacingClock()) {
        self.transport = transport
        self.clock = clock
    }

    /// The song playing now, or nil.
    func playingNow(_ name: String) async throws -> FriendListen? {
        let data = try await body("user/\(Self.escaped(name))/playing-now")
        return try Self.parsed { try ListenBrainz.listens(in: data).first }
    }

    /// The latest listens, newest first.
    func listens(_ name: String, count: Int) async throws -> [FriendListen] {
        let data = try await body("user/\(Self.escaped(name))/listens", ["count": "\(count)"])
        return try Self.parsed { try ListenBrainz.listens(in: data) }
    }

    /// The most listened artists of a week; nil while ListenBrainz hasn't
    /// worked them out (HTTP 204), which is the usual state early in a week
    /// and for accounts that listen rarely.
    func topArtists(_ name: String, range: StatsRange, count: Int) async throws -> [FriendArtist]? {
        let (status, data) = try await get("stats/user/\(Self.escaped(name))/artists", ["range": range.rawValue, "count": "\(count)"])
        if status == 204 || data.isEmpty { return nil }
        return try Self.parsed { try ListenBrainz.topArtists(in: data) }
    }

    func listenCount(_ name: String) async throws -> Int {
        let data = try await body("user/\(Self.escaped(name))/listen-count")
        return try Self.parsed { try ListenBrainz.listenCount(in: data) }
    }

    /// The names an account follows.
    func following(_ name: String) async throws -> [String] {
        let data = try await body("user/\(Self.escaped(name))/following")
        return try Self.parsed { try ListenBrainz.following(in: data) }
    }

    private func body(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        try await get(path, query).data
    }

    private static func parsed<T>(_ parse: () throws -> T) throws -> T {
        do { return try parse() } catch { throw Failure.malformed }
    }

    /// Names can hold spaces and most anything else; in a path only these go as they are.
    static func escaped(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "-._~").union(.alphanumerics)) ?? name
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> (status: Int, data: Data) {
        var components = URLComponents(string: Self.base + path)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        await takeTurn()
        defer { endTurn() }
        // A 429 is answered by waiting as long as it says and asking once more.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let wait = notBefore - clock.now
            guard wait <= Self.longestWait else { throw Failure.rateLimited(retryIn: wait) }
            if wait > 0 { try await clock.sleep(for: wait) }
            // Counted from when the request leaves, and before its answer, so a failure is paced too.
            notBefore = clock.now + Self.spacing
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.network
            }
            let limited = response.statusCode == 429
            let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
            if limited || remaining == 0 {
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset-In").flatMap(Double.init)
                    ?? response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    ?? (limited ? Self.unstatedWait : 0)
                notBefore = max(notBefore, clock.now + max(0, reset))
            }
            switch response.statusCode {
            case 200..<300: return (response.statusCode, data)
            case 429 where attempt == 0: continue
            case 429: throw Failure.rateLimited(retryIn: max(0, notBefore - clock.now))
            case 404: throw Failure.noSuchUser
            case 401, 403: throw Failure.hidden
            default: throw Failure.http(response.statusCode)
            }
        }
        throw Failure.rateLimited(retryIn: max(0, notBefore - clock.now))
    }

    private func takeTurn() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { line.append($0) }
    }

    /// Hands the turn straight to whoever has waited longest.
    private func endTurn() {
        if line.isEmpty { busy = false } else { line.removeFirst().resume() }
    }
}
