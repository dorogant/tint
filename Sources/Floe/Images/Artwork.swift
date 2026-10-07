import ImageIO
import SwiftUI

/// Downloads cover art once (disk cache) and keeps only downsampled copies in
/// memory, so long lists cost a few MB instead of one full-size bitmap per row.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    // NSCache is thread-safe, so synchronous lookups don't need the actor.
    private nonisolated(unsafe) let memory = NSCache<NSString, Box>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.totalCostLimit = 24 * 1024 * 1024 // decoded bitmaps; the disk cache refills it
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.antonchurchyn.floe/Artwork")
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 * 1024 * 1024, directory: directory)
        config.requestCachePolicy = .returnCacheDataElseLoad // cover URLs are immutable
        session = URLSession(configuration: config)
    }

    nonisolated func cached(_ url: URL, pixels: Int) -> CGImage? {
        memory.object(forKey: Self.key(url, pixels))?.image
    }

    func image(for url: URL, pixels: Int) async -> CGImage? {
        let key = Self.key(url, pixels)
        if let hit = memory.object(forKey: key) { return hit.image }
        if let running = inFlight[key as String] { return await running.value }
        let task = Task<CGImage?, Never> { [session] in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixels: pixels)
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        if let image {
            memory.setObject(Box(image), forKey: key, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    private nonisolated static func key(_ url: URL, _ pixels: Int) -> NSString {
        "\(url.absoluteString)#\(pixels)" as NSString
    }

    private nonisolated static func downsample(_ data: Data, maxPixels: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// Square cover art (or a circle, for artists) at a fixed point size.
struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    var cornerRadius: CGFloat = 6
    var circle = false

    @Environment(\.displayScale) private var displayScale
    @ViewState private var loaded: CGImage?

    init(url: URL?, size: CGFloat, cornerRadius: CGFloat = 6, circle: Bool = false) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        self.circle = circle
    }

    init(images: [SpotifyImage]?, size: CGFloat, cornerRadius: CGFloat = 6, circle: Bool = false) {
        self.init(url: images?.best(forPixels: size * 2), size: size,
                  cornerRadius: cornerRadius, circle: circle)
    }

    private var pixels: Int { Int((size * displayScale).rounded(.up)) }

    var body: some View {
        let image = loaded ?? url.flatMap { ArtworkCache.shared.cached($0, pixels: pixels) }
        ZStack {
            Rectangle().fill(.white.opacity(0.06))
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: circle ? "person.fill" : "music.note")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius)))
        .task(id: url) {
            loaded = nil
            guard let url, ArtworkCache.shared.cached(url, pixels: pixels) == nil else { return }
            loaded = await ArtworkCache.shared.image(for: url, pixels: pixels)
        }
    }
}
