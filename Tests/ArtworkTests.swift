import Foundation
import ImageIO
import CoreGraphics

private final class ArtworkHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var statuses = [Int]()
    nonisolated(unsafe) private static var bytes = Data()

    static func reset(_ bytes: Data, statuses: [Int] = []) {
        lock.lock(); defer { lock.unlock() }
        self.bytes = bytes; self.statuses = statuses; count = 0
    }
    static func requestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    private static func response() -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return (statuses.isEmpty ? 200 : statuses.removeFirst(), bytes)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, bytes) = Self.response()
        // Keep the request pending so differently sized callers overlap.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main
struct ArtworkTests {
    static func main() async throws {
        let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        ArtworkHTTP.reset(data as Data)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkHTTP.self]
        let cache = ArtworkCache(session: URLSession(configuration: config))
        let url = URL(string: "https://artwork.invalid/shared.png")!
        async let small = cache.image(for: url, pixels: 96)
        async let medium = cache.image(for: url, pixels: 512)
        async let large = cache.image(for: url, pixels: 720)
        let images = await [small, medium, large]
        precondition(images.map { $0?.width } == [96, 512, 720])
        precondition(ArtworkHTTP.requestCount() == 1, "all cover sizes must share one download")
        let hit = await cache.image(for: url, pixels: 96)
        precondition(hit != nil && ArtworkHTTP.requestCount() == 1)

        ArtworkHTTP.reset(data as Data, statuses: [503, 200])
        let retryURL = URL(string: "https://artwork.invalid/retry.png")!
        let failure = await cache.image(for: retryURL, pixels: 96)
        precondition(failure == nil, "HTTP errors must not enter the image cache")
        let recovered = await cache.image(for: retryURL, pixels: 96)
        precondition(recovered != nil && ArtworkHTTP.requestCount() == 2)

        ArtworkHTTP.reset(data as Data)
        let cancelURL = URL(string: "https://artwork.invalid/cancel.png")!
        let row = Task { await cache.image(for: cancelURL, pixels: 80) }
        try await Task.sleep(for: .milliseconds(20))
        row.cancel()
        let cover = await cache.image(for: cancelURL, pixels: 720)
        _ = await row.value
        precondition(cover?.width == 720 && ArtworkHTTP.requestCount() == 1,
                     "a disappearing row must not cancel the shared cover download")

        // Playing covers (1.6 MB each) keep to a few in a cache of their own, so a
        // long session can't fill the browsing cache with them; trimming drops the
        // browsing covers and keeps the playing ones.
        ArtworkHTTP.reset(data as Data)
        let songs = (0..<6).map { URL(string: "https://artwork.invalid/song-\($0).png")! }
        for song in songs {
            _ = await cache.image(for: song, pixels: 720)
            _ = await cache.image(for: song, pixels: 96)
        }
        let coversKept = songs.filter { cache.cached($0, pixels: 720) != nil }.count
        precondition(coversKept <= 4 && cache.cached(songs[5], pixels: 720) != nil,
                     "only the last few playing covers stay decoded (\(coversKept) kept)")
        precondition(songs.allSatisfy { cache.cached($0, pixels: 96) != nil },
                     "playing covers must not push thumbnails out")
        cache.trim()
        precondition(songs.allSatisfy { cache.cached($0, pixels: 96) == nil }
                     && cache.cached(songs[5], pixels: 720) != nil,
                     "a trim drops the browsing covers and keeps the playing one")
        let again = await cache.image(for: songs[0], pixels: 96)
        precondition(again?.width == 96, "a trimmed cover must load again")
        print("PASS: shared artwork downloads, decoded cache, HTTP retry, cancelled callers, cover tier and trim")
    }
}
