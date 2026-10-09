import CoreGraphics
import Foundation
import ImageIO
import Observation
import ObjectiveC

// Offline timings for the app's non-visual hot spots: cover decoding, the per-song
// cover appearance work, palette construction and core-event decoding. Synthetic
// covers come from an in-process URL protocol; no network, login or window.

/// Serves a distinct 640 px JPEG per URL path ("/<index>.jpg"), like Spotify's covers.
final class CoverHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var covers: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let index = Int(request.url!.deletingPathExtension().lastPathComponent) ?? 0
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "image/jpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.covers[index % Self.covers.count])
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func makeCovers(_ count: Int) -> [Data] {
        (0..<count).map { index in
            let side = 640
            let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let hue = Double(index) / Double(count)
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            for ring in 0..<12 {
                let t = Double(ring) / 12
                context.setFillColor(CGColor(red: 0.5 + 0.5 * cos(6.28 * (hue + t * 0.2)),
                                             green: 0.5 + 0.5 * cos(6.28 * (hue + 0.33 + t * 0.1)),
                                             blue: 0.5 + 0.5 * cos(6.28 * (hue + 0.66)), alpha: 1))
                let inset = CGFloat(ring * 24)
                context.fillEllipse(in: CGRect(x: inset, y: inset * 0.7, width: CGFloat(side) - inset * 1.5,
                                               height: CGFloat(side) - inset * 1.2))
            }
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            precondition(CGImageDestinationFinalize(destination))
            return data as Data
        }
    }
}

@MainActor private func milliseconds(_ body: () async -> Void) async -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    await body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

private func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CoverHTTP.self]
    config.urlCache = nil
    return URLSession(configuration: config)
}

private func url(_ index: Int, run: Int = 0) -> URL {
    URL(string: "https://covers.invalid/r\(run)/\(index).jpg")!
}

@main
struct CoreBenchmarks {
    @MainActor static func main() async {
        CoverHTTP.covers = CoverHTTP.makeCovers(32)

        // A page of cards: 32 covers requested at once at 2x of 160 pt.
        var grid: [Double] = []
        for run in 0..<5 {
            let cache = ArtworkCache(session: session())
            grid.append(await milliseconds {
                await withTaskGroup(of: CGImage?.self) { group in
                    for index in 0..<32 { group.addTask { await cache.image(for: url(index, run: run), pixels: 320) } }
                    for await image in group { precondition(image?.width == 320) }
                }
            })
        }
        print(String(format: "BENCH artwork: 32 covers at 320 px, all at once: %.1f ms (median of 5)", median(grid)))

        // A song change: cover, thumbnail, blurred backdrop and palette. The shared
        // cache builds its session from `.default`; route that offline (the script
        // also gives the harness a private home, so its disk cache is a temp folder).
        let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.default))!
        let replacement = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.offlineCovers))!
        method_exchangeImplementations(original, replacement)
        var loads: [Double] = []
        var counts = (image: 0, background: 0, palette: 0)
        let appearance = CoverAppearance()
        for index in 0..<12 {
            let cover = url(index, run: 99)
            // Warm the shared cache's decode so the timing isolates processing.
            _ = await prewarm(cover)
            var image = 0, background = 0, palette = 0
            track { _ = appearance.image } onChange: { image += 1 }
            track { _ = appearance.background } onChange: { background += 1 }
            track { _ = appearance.palette } onChange: { palette += 1 }
            loads.append(await milliseconds { await appearance.load(cover, blur: 9) })
            counts.image += image; counts.background += background; counts.palette += palette
        }
        print(String(format: "BENCH cover appearance: %.2f ms per song (median of 12, decode excluded); "
                     + "invalidations per song: image %.1f, background %.1f, palette %.1f", median(loads),
                     Double(counts.image) / 12, Double(counts.background) / 12, Double(counts.palette) / 12))
        var blurOnly: [Double] = []
        var paletteChanges = 0
        for blur in [4.0, 9, 14, 6, 12] {
            track { _ = appearance.palette } onChange: { paletteChanges += 1 }
            blurOnly.append(await milliseconds { await appearance.load(url(11, run: 99), blur: blur) })
        }
        print(String(format: "BENCH blur change: %.2f ms incl. 120 ms coalescing (median of 5); palette invalidations: %d",
                     median(blurOnly), paletteChanges))

        var palette = CoverPalette()
        let paletteTime = await milliseconds {
            for index in 0..<2000 { palette = CoverPalette.fixed(["blue", "green", "violet", "amber"][index % 4]) }
        }
        precondition(palette.rgb.r > 0)
        print(String(format: "BENCH CoverPalette.fixed: %.1f us per call", paletteTime * 1000 / 2000))

        let trackJSON = Data(#"{"type":"track","uri":"spotify:track:0000000000000000000000","name":"A synthetic song","artists":[{"name":"One","uri":"spotify:artist:1"},{"name":"Two","uri":"spotify:artist:2"}],"album":"Album","duration_ms":215000,"explicit":false,"cover_url":"https://i.scdn.co/image/ab67616d0000b273"}"#.utf8)
        let position = Data(#"{"type":"position","uri":"spotify:track:0000000000000000000000","position_ms":12345}"#.utf8)
        var decoded = 0
        let eventTime = await milliseconds {
            for _ in 0..<5000 {
                if CoreEvent(json: trackJSON) != nil { decoded += 1 }
                if CoreEvent(json: position) != nil { decoded += 1 }
            }
        }
        precondition(decoded == 10_000)
        print(String(format: "BENCH core events: %.1f us per event", eventTime * 1000 / 10_000))
    }

    /// Fetches through the shared cache, whose session the harness replaced.
    private static func prewarm(_ url: URL) async -> CGImage? {
        async let large = ArtworkCache.shared.image(for: url, pixels: 720)
        async let small = ArtworkCache.shared.image(for: url, pixels: 96)
        _ = await small
        return await large
    }

    @MainActor private static func track(_ read: @escaping () -> Void, onChange: @escaping @MainActor () -> Void) {
        withObservationTracking(read) { MainActor.assumeIsolated { onChange() } }
    }
}

extension URLSessionConfiguration {
    @objc class func offlineCovers() -> URLSessionConfiguration {
        let config = offlineCovers() // exchanged: this calls the system's `default`
        config.protocolClasses = [CoverHTTP.self]
        return config
    }
}
