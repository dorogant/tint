import ImageIO
import SwiftUI

/// Downloads cover art once (disk cache) and keeps only downsampled copies in
/// memory, so long lists cost a few MB instead of one full-size bitmap per row.
actor ArtworkCache {
    static let shared = ArtworkCache()

    /// Unsafe only to the compiler: NSCache is documented thread-safe but not marked
    /// Sendable. Synchronous lookups from views skip the actor through it.
    private nonisolated(unsafe) let memory = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var downloads: [URL: Task<Data?, Never>] = [:]
    private let session: URLSession

    init(session: URLSession? = nil) {
        memory.totalCostLimit = 24 * 1024 * 1024 // decoded bitmaps; the disk cache refills it
        if let session {
            self.session = session
            return
        }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.antonchurchyn.floe/Artwork")
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 * 1024 * 1024, directory: directory)
        config.requestCachePolicy = .returnCacheDataElseLoad // cover URLs are immutable
        self.session = URLSession(configuration: config)
    }

    nonisolated func cached(_ url: URL, pixels: Int) -> CGImage? {
        memory.object(forKey: Self.key(url, pixels))
    }

    func image(for url: URL, pixels: Int) async -> CGImage? {
        let key = Self.key(url, pixels)
        if let hit = memory.object(forKey: key) { return hit }
        if let running = inFlight[key as String] { return await running.value }
        let task = Task<CGImage?, Never> {
            guard let data = await self.data(for: url) else { return nil }
            return await Self.downsample(data, maxPixels: pixels)
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        if let image {
            memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// All sizes share the same HTTP request. Retain bytes only while downloading;
    /// decoded variants keep their existing bounded memory and disk caches.
    private func data(for url: URL) async -> Data? {
        if let running = downloads[url] { return await running.value }
        let task = Task<Data?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: url),
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { return nil }
            return data
        }
        downloads[url] = task
        let data = await task.value
        downloads[url] = nil
        return data
    }

    private nonisolated static func key(_ url: URL, _ pixels: Int) -> NSString {
        "\(url.absoluteString)#\(pixels)" as NSString
    }

    /// Off the actor, so a page of covers decodes in parallel instead of one by one.
    @concurrent private nonisolated static func downsample(_ data: Data, maxPixels: Int) async -> CGImage? {
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
    @ViewState private var loadedURL: URL?

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
        let cached = url.flatMap { ArtworkCache.shared.cached($0, pixels: pixels) }
        let image = cached ?? loaded
        let displayedURL = cached == nil ? loadedURL : url
        ZStack {
            Rectangle().fill(.white.opacity(0.06))
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
                    .id(displayedURL)
                    .transition(.opacity)
            } else {
                Image(systemName: circle ? "person.fill" : "music.note")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius)))
        .floeAnimation(value: displayedURL, duration: 0.22)
        .task(id: "\(url?.absoluteString ?? "")#\(pixels)") {
            guard let url else { loaded = nil; loadedURL = nil; return }
            var image = ArtworkCache.shared.cached(url, pixels: pixels)
            if image == nil { image = await ArtworkCache.shared.image(for: url, pixels: pixels) }
            guard !Task.isCancelled else { return }
            loaded = image
            loadedURL = url
        }
    }
}
