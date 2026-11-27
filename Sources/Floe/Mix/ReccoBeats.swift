import Foundation

/// A song as a mix knows it: what ReccoBeats says of it, which is enough to
/// queue it and name it. The cover and the album come from Spotify later, for
/// the few rows on screen.
struct MixSong: Equatable, Hashable, Sendable, Identifiable {
    /// The Spotify track ID.
    let id: String
    var title: String
    var artists: [String]
    var durationMs: Int

    var uri: String { "spotify:track:\(id)" }
    var artistLine: String { artists.joined(separator: ", ") }

    /// Spotify IDs are 22 letters and digits. Anything else (a local file, a
    /// podcast episode) never leaves the Mac.
    static func isTrackID(_ text: String) -> Bool {
        text.utf8.count == 22 && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }

    /// The ID in `spotify:track:<id>` or `https://open.spotify.com/track/<id>`.
    static func trackID(in address: String) -> String? {
        let tail: Substring
        if address.hasPrefix("spotify:track:") {
            tail = address.dropFirst("spotify:track:".count)
        } else if let range = address.range(of: "open.spotify.com/track/") {
            tail = address[range.upperBound...].prefix { $0 != "?" && $0 != "/" }
        } else {
            return nil
        }
        return isTrackID(String(tail)) ? String(tail) : nil
    }
}

/// The two of ReccoBeats' audio features a mix steers by, each 0…1: valence
/// (sad to happy) and energy (calm to energetic). And the one it refuses by:
/// how much of the track is speech.
struct MixFeatures: Equatable, Sendable {
    var valence: Double
    var energy: Double
    var speechiness: Double = 0

    /// Above this a track is all talk. Asked for calm, sad neighbours,
    /// ReccoBeats answered with chapters of audiobooks and children's radio
    /// plays among the songs (captured in `MixFixtures.calm`); they score low
    /// on valence and energy, so a quiet mix ranked them first.
    static let spoken = 0.66
    var isSpoken: Bool { speechiness > Self.spoken }
}

/// Where a mix's suggestions come from. ReccoBeats in the app, a stub in the tests.
protocol MixCatalog: Sendable {
    /// Songs near `seeds` (one to five Spotify track IDs), at most a hundred.
    func recommendations(seeds: [String], valence: Double?, energy: Double?) async throws -> [MixSong]
    /// Features by track ID. Songs the service doesn't know are missing from the answer.
    func features(for ids: [String]) async throws -> [String: MixFeatures]
}

/// The one edge that touches the network: a request in, the body and the HTTP status out.
protocol MixTransport: Sendable {
    /// Not named `data(for:)`: on `URLSession` that would shadow the system's own
    /// call of that name (which takes a second, defaulted argument), and every
    /// `session.data(for:)` in the app, Spotify's and the lyrics' included, would
    /// quietly get this one's status code where it expects a response.
    func answer(to request: URLRequest) async throws -> (Data, Int)
}

/// ReccoBeats (https://reccobeats.com): recommendations and audio features by
/// Spotify track ID, free and without a key. Spotify's own versions of both are
/// closed to Development Mode apps. Only track IDs are ever sent.
///
/// Measured on 2026-11-27 with public chart songs:
/// - Asked for 100, it answers with 83–92 distinct songs, never the seeds, and a
///   different set each time (two identical requests shared 18 of 88).
/// - `valence` and `energy` change nothing that can be measured: with three pop
///   seeds the answers' median valence was 0.54 unasked, 0.62 asked for 0.15 and
///   0.58 asked for 0.9. They are still sent, in case that changes.
/// - The seeds decide everything. One quiet piano piece as the seed gave 78 of 92
///   songs with energy under 0.45; three pop songs gave none. Two seeds from
///   opposite ends gave songs in between. So a mix reaches a mood by choosing
///   seeds that already have it (`MixSeeds`) and ranking what comes back.
/// - Audio features take at most 40 IDs a request (41 answers 400).
struct ReccoBeats: MixCatalog {
    enum Failure: Error, Equatable {
        /// Status 4002: none of the seeds is in their catalogue.
        case unknownSeeds
        /// Status 4004 and other 4xx: the request itself was wrong.
        case rejected(String)
        /// 429: too many requests for now.
        case busy
        case server(Int)
        /// A 200 whose body isn't what the endpoint answers.
        case unreadable
    }

    static let seedLimit = 5
    static let sizeLimit = 100
    static let featureBatch = 40
    private static let base = "https://api.reccobeats.com/v1"

    let transport: any MixTransport

    init(transport: (any MixTransport)? = nil) {
        self.transport = transport ?? Self.session
    }

    /// Nothing kept between requests: no cache, no cookies.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    func recommendations(seeds: [String], valence: Double?, energy: Double?) async throws -> [MixSong] {
        guard let request = Self.recommendationRequest(seeds: seeds, valence: valence, energy: energy) else {
            throw Failure.unknownSeeds
        }
        return try Self.songs(in: try await answer(to: request))
    }

    func features(for ids: [String]) async throws -> [String: MixFeatures] {
        var result: [String: MixFeatures] = [:]
        for request in Self.featureRequests(ids: ids) {
            result.merge(try Self.features(in: try await answer(to: request))) { $1 }
        }
        return result
    }

    private func answer(to request: URLRequest) async throws -> Data {
        let (data, status) = try await transport.answer(to: request)
        guard (200..<300).contains(status) else { throw Self.failure(status: status, body: data) }
        return data
    }

    // MARK: Requests

    /// nil when no seed is a Spotify track ID. More than five seeds are cut to the first five.
    static func recommendationRequest(seeds: [String], size: Int = sizeLimit, valence: Double?, energy: Double?) -> URLRequest? {
        let ids = distinct(seeds).prefix(seedLimit)
        guard !ids.isEmpty else { return nil }
        var query = [URLQueryItem(name: "size", value: "\(min(max(size, 1), sizeLimit))"),
                     URLQueryItem(name: "seeds", value: ids.joined(separator: ","))]
        if let valence { query.append(URLQueryItem(name: "valence", value: number(valence))) }
        if let energy { query.append(URLQueryItem(name: "energy", value: number(energy))) }
        return request("track/recommendation", query)
    }

    /// One request per forty IDs, in order; none for no IDs.
    static func featureRequests(ids: [String]) -> [URLRequest] {
        let ids = distinct(ids)
        return stride(from: 0, to: ids.count, by: featureBatch).map { start in
            request("audio-features", [URLQueryItem(name: "ids", value: ids[start..<min(start + featureBatch, ids.count)].joined(separator: ","))])
        }
    }

    private static func request(_ path: String, _ query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(string: "\(base)/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func distinct(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { MixSong.isTrackID($0) && seen.insert($0).inserted }
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", min(max(value, 0), 1))
    }

    // MARK: Answers

    /// The songs of a recommendation answer, in its order, each once. Entries
    /// without a Spotify link are skipped.
    static func songs(in data: Data) throws -> [MixSong] {
        struct Body: Decodable { let content: [Entry<Item>] }
        struct Item: Decodable {
            struct Artist: Decodable { let name: String? }
            let trackTitle: String?
            let artists: [Artist]?
            let durationMs: Int?
            let href: String
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw Failure.unreadable }
        var seen = Set<String>()
        return body.content.compactMap { entry -> MixSong? in
            guard let item = entry.value, let id = MixSong.trackID(in: item.href), seen.insert(id).inserted else { return nil }
            return MixSong(id: id, title: item.trackTitle ?? "", artists: (item.artists ?? []).compactMap(\.name),
                           durationMs: max(item.durationMs ?? 0, 0))
        }
    }

    static func features(in data: Data) throws -> [String: MixFeatures] {
        struct Body: Decodable { let content: [Entry<Item>] }
        struct Item: Decodable {
            let href: String
            let valence: Double
            let energy: Double
            let speechiness: Double?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw Failure.unreadable }
        var result: [String: MixFeatures] = [:]
        for case let item? in body.content.map(\.value) {
            guard let id = MixSong.trackID(in: item.href) else { continue }
            result[id] = MixFeatures(valence: min(max(item.valence, 0), 1), energy: min(max(item.energy, 0), 1),
                                     speechiness: min(max(item.speechiness ?? 0, 0), 1))
        }
        return result
    }

    /// What an answer that isn't 2xx means. Their own `status` in the body tells
    /// seeds they don't know (4002) from a malformed request (4004).
    static func failure(status: Int, body: Data) -> Failure {
        struct Body: Decodable {
            struct Detail: Decodable { let path: String?; let message: String? }
            let status: Int?
            let error: String?
            let errors: [Detail]?
        }
        let decoded = try? JSONDecoder().decode(Body.self, from: body)
        if decoded?.status == 4002 { return .unknownSeeds }
        if status == 429 { return .busy }
        if (400..<500).contains(status) {
            let detail = decoded?.errors?.compactMap { detail in
                [detail.path, detail.message].compactMap { $0 }.joined(separator: ": ")
            }.joined(separator: "; ")
            return .rejected(detail.flatMap { $0.isEmpty ? nil : $0 } ?? decoded?.error ?? "HTTP \(status)")
        }
        return .server(status)
    }

    /// One entry of a list, or nil when it isn't shaped as expected: one odd
    /// song mustn't cost the other ninety-nine.
    private struct Entry<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Value.self)
        }
    }
}

extension URLSession: MixTransport {
    func answer(to request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
