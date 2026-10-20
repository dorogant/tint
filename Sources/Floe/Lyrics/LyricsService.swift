import Foundation

/// Lyrics stay in a bounded memory cache; no URL cache, files or lyric logging.
actor LyricsService {
    enum Content: Equatable, Sendable {
        case synced([LyricLine]), plain(String), instrumental, missing
    }
    struct Signature: Hashable, Sendable {
        let title: String
        let artist: String
        let album: String?
        let duration: Double

        init(_ track: TrackInfo) {
            title = track.name
            artist = track.artists.first?.name ?? ""
            album = track.album
            duration = track.durationMs / 1000
        }
    }
    enum Failure: LocalizedError {
        case http(Int), rateLimited(Date)
        var errorDescription: String? {
            switch self {
            case .http: L10n.string("Couldn't load lyrics. Try again later.")
            case .rateLimited: L10n.string("The lyrics service is busy. Try again later.")
            }
        }
    }
    private struct Cached { let content: Content; let expires: Date }
    private let session: URLSession
    private var cache: [Signature: Cached] = [:]
    private var order: [Signature] = []
    private var busy = false
    private var nextRequest = Date.distantPast

    init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: config)
        }
    }

    static func request(for signature: Signature) -> URLRequest {
        var url = URLComponents(string: "https://lrclib.net/api/get")!
        url.queryItems = [URLQueryItem(name: "track_name", value: signature.title),
                          URLQueryItem(name: "artist_name", value: signature.artist)]
        if let album = signature.album, !album.isEmpty {
            url.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }
        if signature.duration.isFinite, (1...3600).contains(signature.duration) {
            url.queryItems?.append(URLQueryItem(name: "duration", value: String(signature.duration)))
        }
        var request = URLRequest(url: url.url!)
        request.setValue("Tint v0.1.0 (personal macOS client; com.antonchurchyn.floe)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func lyrics(for signature: Signature) async throws -> Content {
        guard !signature.title.isEmpty, !signature.artist.isEmpty else { return .missing }
        // Serialize even across actor reentrancy and waiters cancelled by track changes.
        while busy { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        if let hit = cache[signature], hit.expires > Date() { return hit.content }
        guard nextRequest <= Date() else { throw Failure.rateLimited(nextRequest) }
        busy = true
        defer { busy = false }
        try await Task.sleep(for: .milliseconds(250))
        let (data, response) = try await session.data(for: Self.request(for: signature))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.http(0) }
        if response.statusCode == 429 || response.statusCode == 503 {
            nextRequest = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After") ?? "")
            throw Failure.rateLimited(nextRequest)
        }
        let content: Content
        switch response.statusCode {
        case 404: content = .missing
        case 200:
            let record = try JSONDecoder().decode(Record.self, from: data)
            if signature.duration >= 1, signature.duration <= 3600,
               let duration = record.duration, abs(duration - signature.duration) > 2 {
                content = .missing
            } else { content = record.content }
        default: throw Failure.http(response.statusCode)
        }
        cache[signature] = Cached(content: content, expires: Date().addingTimeInterval(content == .missing ? 300 : 3600))
        order.removeAll { $0 == signature }
        order.append(signature)
        if order.count > 24 { cache.removeValue(forKey: order.removeFirst()) }
        return content
    }

    /// `Retry-After` is seconds or an HTTP date; without one, wait 30 s.
    private static func retryDate(_ header: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: header) ?? Date().addingTimeInterval(Double(header).map { max(1, $0) } ?? 30)
    }

    /// Unknown newer fields (hasWordSync / lyricsfile) are intentionally ignored;
    /// this view uses LRCLIB's line-synced LRC and plain-text representations.
    struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool
        let syncedLyrics: String?
        let plainLyrics: String?
        var content: Content {
            if instrumental { return .instrumental }
            let lines = LRC.parse(syncedLyrics ?? "")
            if lines.contains(where: { !$0.text.isEmpty }) { return .synced(lines) }
            if let plain = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
                return .plain(plain)
            }
            return .missing
        }
    }
}
