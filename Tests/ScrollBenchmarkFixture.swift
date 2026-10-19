import AppKit
import Foundation
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers

/// Long playlists for the scroll benchmark, answered ahead of the layout
/// harness's `FixtureProtocol`: 600 tracks paged 100 at a time as the Web API
/// does, nearly every one on its own album, with JPEG covers at Spotify's three
/// sizes. Covers are generated once per URL and served from memory, standing in
/// for the app's disk cache.
final class ScrollFixture: URLProtocol, @unchecked Sendable {
    static let trackCount = 600
    static let playlistIDs = ["pl-scroll-a", "pl-scroll-b"]
    private static let pageSize = 100

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        if url.host == Fixture.artHost { return url.lastPathComponent.hasPrefix("scroll-") }
        return url.host == "api.spotify.com" && url.path.hasPrefix("/v1/playlists/pl-scroll-")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (body, type) = url.host == Fixture.artHost ? (Self.cover(url), "image/jpeg") : (Self.api(url), "application/json")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Routes the Web API session and `ArtworkCache.shared` through this, then the layout fixture.
    static func install() {
        FixtureProtocol.install()
        let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.default))!
        let replacement = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.scrollFixtureDefault))!
        method_exchangeImplementations(original, replacement)
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScrollFixture.self, FixtureProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: Web API

    private static func api(_ url: URL) -> Data {
        let parts = url.path.split(separator: "/").map(String.init) // v1, playlists, id, items?
        let id = parts[2]
        let json: Any
        if parts.count == 3 {
            var playlist = Fixture.playlist(id == playlistIDs[0] ? "Scroll A" : "Scroll B", count: trackCount,
                                            description: "Six hundred songs, most on their own album.")
            playlist["images"] = images("scroll-\(id)-cover")
            json = playlist
        } else {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "") ?? 0
            let end = min(offset + pageSize, trackCount)
            let items: [[String: Any]] = (offset..<end).map { item($0, playlist: id) }
            json = ["items": items, "total": trackCount, "offset": offset,
                    "next": end < trackCount ? "https://api.spotify.com/v1/playlists/\(id)/items?offset=\(end)" as Any : NSNull()]
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    private static let words = ["Night", "City", "Blue", "Light", "Сонце", "сходить", "Holding", "On", "Late", "Bloomer",
                                "Wisteria", "Parade", "Жовтий", "Overture", "Glass", "Motion", "Неон", "Drive", "Static",
                                "Borderline", "Afterglow", "Kosmos", "Тиша", "Echoes", "Paper", "Moon", "Run", "Fade"]
    private static let artists = ["Tame Impala", "Połoz", "Kunteynir", "FORTUNA 812", "Brothers Ivan", "Panchiko",
                                  "Trent Reznor and Atticus Ross", "saraunh0ly", "kizaru", "Paul Leonard-Morgan",
                                  "Френдлі Технік Хайпо", "VILLIAN", "PureSnow", "Олександра Шевченко-Ковальчук"]

    private static func item(_ index: Int, playlist: String) -> [String: Any] {
        func pick(_ list: [String], _ salt: Int) -> String { list[(index &* 7 &+ salt &* 13) % list.count] }
        let title = (0..<(1 + index % 4)).map { pick(words, $0 + index / 5) }.joined(separator: " ")
            + (index % 11 == 0 ? " (Extended Version) — Live at the Kyiv Philharmonic" : "")
        let byline = index % 6 == 0 ? [pick(artists, 1), pick(artists, 2)] : [pick(artists, 1)]
        // Nearly every song on its own album, as in a mixed playlist.
        let albumIndex = index % 9 == 0 ? index - 3 : index
        var album = Fixture.album("\(pick(words, 3)) \(albumIndex)", by: byline, year: "\(2000 + index % 26)")
        album["id"] = "\(playlist)-album-\(albumIndex)"
        album["uri"] = "spotify:album:\(playlist)-album-\(albumIndex)"
        album["images"] = images("scroll-\(playlist)-album-\(albumIndex)")
        var track = Fixture.track(title, album, number: index + 1, ms: 150_000 + index * 7_919 % 180_000,
                                  explicit: index % 5 == 1)
        track["id"] = "\(playlist)-\(index)"
        track["uri"] = "spotify:track:\(playlist)-\(index)"
        return ["added_at": "2026-0\(1 + index % 9)-1\(index % 10)T12:00:00Z", "item": track]
    }

    /// Spotify's three sizes, largest first.
    private static func images(_ name: String) -> [[String: Any]] {
        [640, 300, 64].map { ["url": "https://\(Fixture.artHost)/\(name)-\($0).jpg", "width": $0, "height": $0] }
    }

    // MARK: Covers

    private nonisolated(unsafe) static var covers: [String: Data] = [:]
    private static let lock = NSLock()

    private static func cover(_ url: URL) -> Data {
        let name = url.deletingPathExtension().lastPathComponent
        if let data = lock.withLock({ covers[name] }) { return data }
        let parts = name.split(separator: "-")
        let pixels = Int(parts.last ?? "") ?? 640
        let seed = parts.dropLast().joined(separator: "-")
        let png = Fixture.art(URL(string: "https://\(Fixture.artHost)/\(seed).png")!).1
        var data = Data()
        if let source = CGImageSourceCreateWithData(png as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: pixels,
           ] as CFDictionary) {
            let output = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                CGImageDestinationFinalize(destination)
            }
            data = output as Data
        }
        lock.withLock { covers[name] = data }
        return data
    }
}

extension URLSessionConfiguration {
    @objc class func scrollFixtureDefault() -> URLSessionConfiguration {
        let config = scrollFixtureDefault() // exchanged: the layout fixture's default
        config.protocolClasses = [ScrollFixture.self] + (config.protocolClasses ?? [])
        return config
    }
}
