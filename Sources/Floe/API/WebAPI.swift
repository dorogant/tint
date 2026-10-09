import Foundation
import os

/// Spotify Web API client, authorised with Tint's own client ID (Development Mode).
final class WebAPI: Sendable {
    enum Failure: LocalizedError {
        case http(status: Int, message: String)
        case rateLimited(retryAfter: Double)

        var status: Int? {
            if case let .http(status, _) = self { status } else { nil }
        }

        var errorDescription: String? {
            switch self {
            case let .http(status, message): "Spotify returned \(status): \(message)"
            case let .rateLimited(seconds):
                L10n.string("Spotify is rate-limiting requests; try again in \(Int(seconds)) s.")
            }
        }
    }

    let user: UserTokenProvider
    private let base = URL(string: "https://api.spotify.com/v1/")!
    private let tokens: any TokenProvider
    private let http: URLSession
    private let decoder: JSONDecoder
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "webapi")

    init(user: UserTokenProvider, tokens: (any TokenProvider)? = nil, http: URLSession? = nil) {
        self.user = user
        self.tokens = tokens ?? user
        // API responses aren't worth caching; ephemeral sessions still keep 500 KB in memory.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        self.http = http ?? URLSession(configuration: config)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            // `added_at` has whole seconds, `played_at` fractional ones.
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            return try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
    }

    /// `path` is relative to /v1/ or an absolute `next` URL from a paging object.
    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        let data = try await send("GET", path, query)
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    func send(_ method: String, _ path: String, _ query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        var components = URLComponents(
            url: path.hasPrefix("https://") ? URL(string: path)! : base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? [])
                + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        for attempt in 0..<3 {
            request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await http.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return data
            case 401 where attempt == 0:
                await tokens.invalidate()
            case 401:
                await user.reportAuthorizationExpired()
                throw TokenError.notAuthorized
            case 429 where attempt < 2:
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 2
                guard retryAfter <= 15 else { throw Failure.rateLimited(retryAfter: retryAfter) }
                log.notice("429 on \(path, privacy: .public); retrying in \(retryAfter) s")
                try await Task.sleep(for: .seconds(retryAfter))
            case 429:
                throw Failure.rateLimited(retryAfter: 0)
            default:
                throw Failure.http(status: status, message: Self.message(in: data))
            }
        }
        throw Failure.http(status: 401, message: "unauthorized")
    }

    private static func message(in data: Data) -> String {
        struct Body: Decodable { struct E: Decodable { let message: String? }; let error: E? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error?.message
            ?? String(decoding: data.prefix(200), as: UTF8.self)
    }
}

// MARK: - Endpoints

extension WebAPI {
    func me() async throws -> UserProfile { try await get("me") }

    func myPlaylists() async throws -> [PlaylistRef] {
        try await all("me/playlists", ["limit": "50"])
    }

    /// Playlist metadata. Spotify-made playlists 404 for Development Mode apps.
    func playlist(_ id: String) async throws -> PlaylistRef {
        try await get("playlists/\(id)", [
            "fields": "id,uri,name,description,images,owner(id,display_name),collaborative,items(total),tracks(total)",
        ])
    }

    /// One page of playlist tracks. Development Mode only returns these for
    /// playlists the user owns or collaborates on.
    func playlistItems(_ id: String, offset: Int) async throws -> Paging<PlaylistItem> {
        try await get("playlists/\(id)/items", ["limit": "100", "offset": "\(offset)", "additional_types": "track"])
    }

    func savedTracks(offset: Int) async throws -> Paging<SavedTrack> {
        try await get("me/tracks", ["limit": "50", "offset": "\(offset)"])
    }

    func savedAlbums() async throws -> [AlbumRef] {
        let saved: [SavedAlbum] = try await all("me/albums", ["limit": "50"], max: 100)
        return saved.map(\.album)
    }

    func recentlyPlayed() async throws -> [PlayHistory] {
        let page: Paging<PlayHistory> = try await get("me/player/recently-played", ["limit": "50"])
        return page.items
    }

    func topArtists() async throws -> [Artist] {
        let page: Paging<Artist> = try await get("me/top/artists", ["limit": "12", "time_range": "short_term"])
        return page.items
    }

    /// Development Mode caps `limit` at 10.
    func search(_ text: String, offset: Int = 0) async throws -> SearchResults {
        try await get("search", [
            "q": text, "type": "track,artist,album,playlist",
            "limit": "10", "offset": "\(offset)",
        ])
    }

    func album(_ id: String) async throws -> Album {
        try await get("albums/\(id)")
    }

    func albumTracks(_ id: String, offset: Int) async throws -> Paging<Track> {
        try await get("albums/\(id)/tracks", ["limit": "50", "offset": "\(offset)"])
    }

    func track(_ id: String) async throws -> Track {
        try await get("tracks/\(id)")
    }

    func artist(_ id: String) async throws -> Artist {
        try await get("artists/\(id)")
    }

    func artistAlbums(_ id: String) async throws -> [AlbumRef] {
        try await all("artists/\(id)/albums",
                      ["include_groups": "album,single", "limit": "10"], max: 30) // Dev Mode max is 10
    }

    // Library (2026 URI-based endpoints; at most 40 URIs per call).

    func libraryContains(_ uris: [String]) async throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        for chunk in uris.chunked(into: 40) {
            let flags: [Bool] = try await get("me/library/contains", ["uris": chunk.joined(separator: ",")])
            for (uri, flag) in zip(chunk, flags) { result[uri] = flag }
        }
        return result
    }

    func saveToLibrary(_ uris: [String]) async throws {
        try await send("PUT", "me/library", ["uris": uris.joined(separator: ",")])
    }

    func removeFromLibrary(_ uris: [String]) async throws {
        try await send("DELETE", "me/library", ["uris": uris.joined(separator: ",")])
    }

    /// Follows `next` links until done or `max` items.
    private func all<T: Decodable & Sendable>(_ path: String, _ query: [String: String], max: Int = .max) async throws -> [T] {
        var page: Paging<T> = try await get(path, query)
        var items = page.items
        while let next = page.next, items.count < max {
            page = try await get(next)
            items += page.items
        }
        return items
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
