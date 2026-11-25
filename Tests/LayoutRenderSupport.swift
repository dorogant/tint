import AppKit
import Foundation
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers

// The layout harness compiles the production views and models. Only the I/O
// boundary is synthetic: the playback core, audio output and Now Playing centre
// are stubs, and every Web API answer and cover image comes from this file. No
// login, saved credentials, audio engine or network request.

// MARK: - Playback core stubs

struct PlayRequest: Sendable {
    var contextURI: String?
    var tracks: [String]?
    var startURI: String?
    var startIndex: Int?
    var shuffle = false
    var repeatMode = 0
    var positionMs: UInt32?
    var startPlaying = true
}

@MainActor final class FloeCore {
    static let shared = FloeCore()
    var onEvent: ((CoreEvent) -> Void)?
    var engine: PlaybackEngine = .librespot
    var usesLocalAudioOutput: Bool { true }
    var sessionClientID: String { "layout-fixture" }

    func deliver(_ event: CoreEvent) { onEvent?(event) }
    func startSoloist(apiKey: String, volume: UInt16) {}
    func stopSoloist() {}
    func setSoloistTapRunning(_ running: Bool) {}
    func previous() {}
    func next() {}
    func seek(toMs ms: UInt32) {}
    func play() {}
    func pause() {}
    func transferPlayback() {}
    func load(_ request: PlayRequest) -> Bool { true }
    func configure(_ configuration: PlaybackConfiguration) {}
    func setShuffle(_ value: Bool) {}
    func setRepeat(_ value: RepeatMode) {}
    func setVolume(_ value: UInt16) {}
    func addToQueue(_ uri: String) -> Bool { true }
    func logIn(accessToken: String, volume: UInt16) {}
    func logIn(storedCredentials: Data, volume: UInt16) {}
    func logOut() {}
}

@MainActor final class AudioOutput {
    var volume: Float = 0
    func start() {}
    func pause() {}
}

@MainActor final class NowPlayingController {
    init(model: PlayerModel) {}
    func update() {}
}

struct FixtureTokens: TokenProvider {
    func accessToken() async throws -> String { "layout-fixture" }
    func invalidate() async {}
}

// MARK: - Fixture network

/// Answers `api.spotify.com` from `Fixture` and `art.fixture.invalid` with
/// generated covers. Responses are never cached.
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        let host = request.url?.host
        return host == "api.spotify.com" || host == Fixture.artHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (status, body, type) = url.host == Fixture.artHost
            ? Fixture.art(url)
            : Fixture.api(url, method: request.httpMethod ?? "GET")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `ArtworkCache.shared` builds its own session from the default
    /// configuration; route that through the fixture too.
    static func install() {
        let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.default))!
        let replacement = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.fixtureDefault))!
        method_exchangeImplementations(original, replacement)
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return URLSession(configuration: config)
    }
}

extension URLSessionConfiguration {
    @objc class func fixtureDefault() -> URLSessionConfiguration {
        let config = fixtureDefault() // exchanged: this calls the system's `default`
        config.protocolClasses = [FixtureProtocol.self] + (config.protocolClasses ?? [])
        config.urlCache = nil
        return config
    }
}

// MARK: - Fixture library

/// A realistic library: long and Cyrillic names, duplicates across recents,
/// playlists by the user and by others.
enum Fixture {
    static let artHost = "art.fixture.invalid"
    static let userID = "tokhidze"
    static let userName = "тохідзе"

    static func image(_ seed: String) -> [[String: Any]] {
        [["url": "https://\(artHost)/\(seed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? seed).png",
          "width": 640, "height": 640]]
    }

    static func artist(_ name: String) -> [String: Any] {
        let id = slug(name)
        return ["id": id, "uri": "spotify:artist:\(id)", "name": name]
    }

    static func fullArtist(_ name: String, genres: [String] = []) -> [String: Any] {
        var value = artist(name)
        value["images"] = image("artist-\(slug(name))")
        value["genres"] = genres
        return value
    }

    static func album(_ name: String, by artists: [String], year: String = "2015", type: String = "album",
                      tracks: Int = 12) -> [String: Any] {
        let id = slug(name)
        return ["id": id, "uri": "spotify:album:\(id)", "name": name, "images": image("album-\(id)"),
                "artists": artists.map(artist), "release_date": "\(year)-03-01", "total_tracks": tracks,
                "album_type": type]
    }

    static func track(_ name: String, _ album: [String: Any], number: Int = 1, ms: Int = 214_000,
                      explicit: Bool = false) -> [String: Any] {
        let id = slug("\(album["id"] as? String ?? "")-\(name)")
        return ["id": id, "uri": "spotify:track:\(id)", "name": name, "duration_ms": ms, "explicit": explicit,
                "artists": album["artists"] ?? [], "album": album, "track_number": number, "disc_number": 1,
                "is_local": false, "is_playable": true]
    }

    static func playlist(_ name: String, owner: String = userID, ownerName: String = userName, count: Int = 42,
                         description: String = "") -> [String: Any] {
        let id = slug("pl-\(name)")
        return ["id": id, "uri": "spotify:playlist:\(id)", "name": name, "description": description,
                "images": image("playlist-\(id)"), "owner": ["id": owner, "display_name": ownerName],
                "collaborative": false, "items": ["total": count]]
    }

    // Albums
    nonisolated(unsafe) static let cyberpunk = album("Cyberpunk 2077: Radio, Vol. 2 (Original Soundtrack)", by: ["Połoz", "Tinnitus"], year: "2020")
    nonisolated(unsafe) static let limitless = album("Limitless (Original Motion Picture Soundtrack)", by: ["Paul Leonard-Morgan"], year: "2011")
    nonisolated(unsafe) static let socialNetwork = album("The Social Network (Soundtrack from the Motion Picture)",
                                     by: ["Trent Reznor and Atticus Ross"], year: "2010")
    nonisolated(unsafe) static let panchiko = album("D>E>A>T>H>M>E>T>A>L", by: ["Panchiko"], year: "2016", type: "single", tracks: 4)
    nonisolated(unsafe) static let somebody = album("som1callsomebody", by: ["saraunh0ly"], year: "2023", type: "single", tracks: 1)
    nonisolated(unsafe) static let currents = album("Currents", by: ["Tame Impala"], year: "2015", tracks: 13)
    nonisolated(unsafe) static let slowRush = album("The Slow Rush", by: ["Tame Impala"], year: "2020", tracks: 12)
    nonisolated(unsafe) static let deadbeat = album("Deadbeat", by: ["Tame Impala"], year: "2025", tracks: 12)
    nonisolated(unsafe) static let lonerism = album("Lonerism", by: ["Tame Impala"], year: "2012", tracks: 12)
    nonisolated(unsafe) static let innerspeaker = album("Innerspeaker", by: ["Tame Impala"], year: "2010", tracks: 11)
    nonisolated(unsafe) static let kunteynir = album("Основа", by: ["Kunteynir"], year: "2019")
    nonisolated(unsafe) static let brothers = album("Glory to the Heroes", by: ["Brothers Ivan"], year: "2022")
    nonisolated(unsafe) static let fortuna = album("Морфін", by: ["FORTUNA 812"], year: "2021", type: "single", tracks: 3)
    nonisolated(unsafe) static let kizaru = album("Born to Trap", by: ["kizaru"], year: "2018")
    nonisolated(unsafe) static let thug = album("Ice Cold Hits Vol. 1", by: ["FRIENDLY THUG 52 NGG"], year: "2023")

    nonisolated(unsafe) static let albums: [[String: Any]] = [cyberpunk, limitless, socialNetwork, panchiko, somebody, currents,
                                          slowRush, deadbeat, lonerism, kunteynir, brothers, fortuna, kizaru, thug]

    nonisolated(unsafe) static let playlists: [[String: Any]] = [
        playlist("{#}", count: 118),
        playlist("House", count: 64),
        playlist("Ambient", count: 37),
        playlist("Brazil", count: 22),
        playlist("Френдлі Технік Хайпо-Мадафака Бітз", count: 211,
                 description: "Все, що грає на кухні після другої ночі. Без пропусків."),
        playlist("таг", count: 9),
        playlist("андер ґопаца", count: 51),
        playlist("Late Night Drives Through An Empty City", count: 76),
        playlist("Lo-fi Focus", owner: "spotify-user-2", ownerName: "Marta K.", count: 140),
        playlist("Gym", count: 30),
    ]

    nonisolated(unsafe) static let topArtists: [[String: Any]] = [
        fullArtist("Paul Leonard-Morgan", genres: ["soundtrack"]),
        fullArtist("PureSnow"), fullArtist("FRIENDLY THUG 52 NGG", genres: ["russian hip hop"]),
        fullArtist("Kunteynir", genres: ["ukrainian hip hop"]), fullArtist("FORTUNA 812"),
        fullArtist("VILLIAN"), fullArtist("Brothers Ivan", genres: ["ukrainian folk"]),
        fullArtist("kizaru", genres: ["russian trap"]), fullArtist("Tame Impala", genres: ["psychedelic rock", "neo-psychedelia"]),
        fullArtist("Trent Reznor and Atticus Ross", genres: ["soundtrack", "industrial"]),
        fullArtist("Panchiko"), fullArtist("Френдлі Технік Хайпо"),
    ]

    static var recent: [[String: Any]] {
        let plays: [([String: Any], String, [String: Any]?)] = [
            (cyberpunk, "On My Way to Hell", nil),
            (somebody, "som1callsomebody", nil),
            (panchiko, "D>E>A>T>H>M>E>T>A>L", nil),
            (limitless, "Limitless", ["type": "playlist", "uri": playlists[4]["uri"]!]),
            (limitless, "I Still Love You", nil),
            (socialNetwork, "Intriguing Possibilities", ["type": "playlist", "uri": playlists[2]["uri"]!]),
            (limitless, "Trading Up", nil),
            (socialNetwork, "In Motion", nil),
            (currents, "Let It Happen", ["type": "album", "uri": currents["uri"]!]),
            (kunteynir, "Сік", nil),
            (fortuna, "Морфін", nil),
            (brothers, "Glory to the Heroes", ["type": "playlist", "uri": playlists[0]["uri"]!]),
            (kizaru, "Narcotic", nil),
            (thug, "Rari", ["type": "playlist", "uri": playlists[4]["uri"]!]),
            (slowRush, "Borderline", nil),
            (currents, "Eventually", nil),
            (cyberpunk, "Night City Blues", nil),
            (panchiko, "Laputa", nil),
        ]
        // The API returns up to 50; fill with more plays from the user's playlists.
        let names = ["Сонце сходить", "Слава героям", "Нічне місто", "Trap Queen", "Blue Light", "Kosmos",
                     "Holding On", "Late Bloomer", "Wisteria", "Parade", "Zhovtyi", "Overture"]
        let filler: [([String: Any], String, [String: Any]?)] = (0..<32).map { index in
            (albums[(index * 5 + 3) % albums.count], names[index % names.count] + (index >= names.count ? " \(index / names.count + 1)" : ""),
             ["type": "playlist", "uri": playlists[[0, 1, 2, 3, 5, 6][index % 6]]["uri"]!])
        }
        return (plays + filler).enumerated().map { index, play in
            var item: [String: Any] = ["track": track(play.1, play.0, number: index + 1),
                                       "played_at": "2026-10-08T21:\(String(format: "%02d", 59 - index)):00.000Z"]
            if let context = play.2 { item["context"] = context }
            return item
        }
    }

    static var searchTracks: [[String: Any]] {
        [track("Let It Happen", currents, number: 1, ms: 467_000), track("Loser", deadbeat, number: 4, ms: 223_000, explicit: true),
         track("New Person, Same Old Mistakes", currents, number: 13, ms: 363_000),
         track("Borderline", slowRush, number: 3, ms: 237_000), track("Loser", deadbeat, number: 5, ms: 223_000, explicit: true),
         track("One More Hour", slowRush, number: 12, ms: 432_000), track("Eventually", currents, number: 8, ms: 318_000),
         track("My Old Ways", deadbeat, number: 1, ms: 298_000, explicit: true),
         track("Dracula", deadbeat, number: 2, ms: 205_000, explicit: true), track("The Less I Know the Better", currents, number: 7, ms: 216_000)]
    }

    static var playlistTracks: [[String: Any]] {
        let names = ["On My Way to Hell", "Limitless", "Сік", "Морфін", "Narcotic", "Rari",
                     "Glory to the Heroes (Слава героям) — Extended Folk Version", "In Motion", "Let It Happen",
                     "Laputa", "Borderline", "Intriguing Possibilities", "Night City Blues", "Eventually"]
        let sources = [cyberpunk, limitless, kunteynir, fortuna, kizaru, thug, brothers, socialNetwork, currents,
                       panchiko, slowRush, socialNetwork, cyberpunk, currents]
        return (0..<28).map { index in
            ["added_at": "2026-0\(1 + index % 9)-1\(index % 10)T12:00:00Z",
             "item": track(names[index % names.count], sources[index % sources.count], number: index + 1,
                           ms: 150_000 + index * 7_919 % 180_000, explicit: index % 5 == 1)]
        }
    }

    static func paging(_ items: [Any], total: Int? = nil) -> [String: Any] {
        ["items": items, "next": NSNull(), "total": total ?? items.count, "offset": 0]
    }

    static func json(_ value: Any) -> (Int, Data, String) {
        (200, (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), "application/json")
    }

    static func api(_ url: URL, method: String) -> (Int, Data, String) {
        let parts = url.path.split(separator: "/").map(String.init).dropFirst() // drop "v1"
        let path = parts.joined(separator: "/")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if method != "GET" { return json([:]) }
        switch path {
        case "me":
            return json(["id": userID, "display_name": userName, "images": image("avatar")])
        case "me/playlists": return json(paging(playlists))
        case "me/player/recently-played": return json(paging(recent))
        case "me/top/artists": return json(paging(Array(topArtists.prefix(12))))
        case "me/albums": return json(paging([currents, limitless, socialNetwork, lonerism, slowRush, brothers, kizaru, innerspeaker]
            .map { ["album": $0] }))
        case "me/tracks":
            return json(paging(playlistTracks.map { ["added_at": $0["added_at"]!, "track": $0["item"]!] }, total: 1_204))
        case "me/library/contains":
            let count = query.first { $0.name == "uris" }?.value?.split(separator: ",").count ?? 0
            return json((0..<count).map { $0 % 4 == 0 })
        case "search":
            return json([
                "tracks": paging(searchTracks).merging(["next": "https://api.spotify.com/v1/search?offset=10"]) { $1 },
                "artists": paging([fullArtist("Tame Impala"), fullArtist("Gorillaz"), fullArtist("The Neighbourhood"),
                                   fullArtist("sombr"), fullArtist("Tamed Impala"), fullArtist("Taco Hemingway"),
                                   fullArtist("Kevin Parker / Tame Impala Tribute Band"), fullArtist("sanah")]),
                "albums": paging([currents, slowRush, deadbeat, lonerism, innerspeaker]),
                "playlists": paging([playlist("This Is Tame Impala", owner: "spotify", ownerName: "Spotify"),
                                     playlist("Tame Impala Radio", owner: "spotify", ownerName: "Spotify"),
                                     playlist("psych rock but make it 2026", owner: "u3", ownerName: "Олександра Шевченко-Ковальчук")]),
            ])
        default: break
        }
        if parts.first == "playlists", let id = parts.dropFirst().first {
            let found = playlists.first { $0["id"] as? String == id } ?? playlists[4]
            return parts.count == 3 ? json(paging(playlistTracks)) : json(found)
        }
        if parts.first == "artists", parts.count >= 2 {
            let found = topArtists.first { $0["id"] as? String == parts[1] } ?? topArtists[8]
            return parts.count == 3 ? json(paging([deadbeat, slowRush, currents, lonerism, innerspeaker,
                                                   album("Live Versions", by: ["Tame Impala"], year: "2014"),
                                                   album("Lost in Yesterday", by: ["Tame Impala"], year: "2020", type: "single", tracks: 1)]))
                : json(found)
        }
        if parts.first == "albums", parts.count >= 2 {
            let found = albums.first { $0["id"] as? String == parts[1] } ?? currents
            let tracks = ["Let It Happen", "Nangs", "The Moment", "Yes I'm Changing", "Eventually", "Gossip",
                          "The Less I Know the Better", "Past Life", "Disciples", "'Cause I'm a Man",
                          "Reality in Motion", "Love/Paranoia", "New Person, Same Old Mistakes"]
                .enumerated().map { index, name -> [String: Any] in
                    var value = track(name, found, number: index + 1, ms: 180_000 + index * 13_000)
                    value["album"] = nil
                    return value
                }
            return json(found.merging(["tracks": paging(tracks)]) { $1 })
        }
        if parts.first == "tracks" { return json(searchTracks[0]) }
        return (404, Data(#"{"error":{"message":"fixture"}}"#.utf8), "application/json")
    }

    // MARK: Generated covers

    /// A deterministic cover per name: a two-tone gradient, a soft shape and
    /// initials, so cards are easy to tell apart in the renders.
    static func art(_ url: URL) -> (Int, Data, String) {
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "x"
        let size = 640
        var hash: UInt64 = 1469598103934665603
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let hue = Double(hash % 360) / 360
        let hue2 = (hue + 0.08 + Double((hash >> 9) % 20) / 100).truncatingRemainder(dividingBy: 1)
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (500, Data(), "text/plain")
        }
        let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1).cgColor
        let bottom = NSColor(hue: hue2, saturation: 0.7, brightness: 0.28, alpha: 1).cgColor
        let gradient = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])
        let person = name.hasPrefix("artist-") || name == "avatar"
        context.setFillColor(NSColor(white: 1, alpha: person ? 0.22 : 0.14).cgColor)
        if person {
            context.fillEllipse(in: CGRect(x: 220, y: 300, width: 200, height: 200))
            context.fillEllipse(in: CGRect(x: 120, y: -120, width: 400, height: 380))
        } else {
            let offset = CGFloat(hash % 200)
            context.fillEllipse(in: CGRect(x: 120 + offset, y: 60 + offset / 2, width: 420, height: 420))
        }
        let title = ["playlist-pl-", "album-", "artist-"].reduce(name) { label, prefix in
            label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
        }
        let label = title.split(separator: "-").prefix(2).map { $0.prefix(1) }.joined().uppercased()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 150, weight: .heavy),
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(label), attributes: attributes))
        context.textPosition = CGPoint(x: 44, y: 60)
        if !person { CTLineDraw(line, context) }
        guard let image = context.makeImage() else { return (500, Data(), "text/plain") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return (500, Data(), "text/plain")
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return (200, data as Data, "image/png")
    }

    static func slug(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? text
        let cleaned = latin.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(cleaned).split(separator: "-").joined(separator: "-")
    }
}
