import ImageIO
import SwiftUI

/// Downloads cover art once (disk cache) and keeps only downsampled copies in
/// memory, so long lists cost a few MB instead of one full-size bitmap per row.
actor ArtworkCache {
    static let shared = ArtworkCache()

    /// Unsafe only to the compiler: NSCache is documented thread-safe but not marked
    /// Sendable. Synchronous lookups from views skip the actor through it.
    private nonisolated(unsafe) let memory = NSCache<NSString, CGImage>()
    /// Now Playing's covers, apart from the browsing budget: each is 1.6 MB
    /// (640 px), and one arrives with every song, so in `memory` thirty songs
    /// of listening filled all of it with covers only Previous would show again.
    private nonisolated(unsafe) let covers = NSCache<NSString, CGImage>()
    /// From this size up an image is a playing cover, not a row or a card.
    private static let coverPixels = 600
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    /// Active (non-cancelled) callers per decoded size key. If every caller for
    /// a size scrolls away before the download returns, we skip downsampling so
    /// fast scrolling doesn't decode bitmaps nobody will display.
    private var waiters: [String: Int] = [:]
    private var downloads: [URL: Task<Data?, Never>] = [:]
    private let session: URLSession

    init(session: URLSession? = nil) {
        // Decoded bitmaps; the disk cache refills it. Room for a long shelf of
        // Standard-size cards, so scrolling back doesn't re-decode and re-fade covers.
        memory.totalCostLimit = 48 * 1024 * 1024
        // The playing song's, the one before and the one after, and one to spare.
        covers.countLimit = 4
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
        store(pixels).object(forKey: Self.key(url, pixels))
    }

    private nonisolated func store(_ pixels: Int) -> NSCache<NSString, CGImage> {
        pixels >= Self.coverPixels ? covers : memory
    }

    /// Drops the browsing covers; the few playing ones stay. For when nobody is
    /// looking: views on screen keep the images they show, and anything
    /// scrolled back to decodes again from the disk cache (a page in ~10 ms).
    nonisolated func trim() {
        memory.removeAllObjects()
    }

    func image(for url: URL, pixels: Int) async -> CGImage? {
        let key = Self.key(url, pixels), memory = store(pixels)
        if let hit = memory.object(forKey: key) { return hit }
        let keyString = key as String
        waiters[keyString, default: 0] += 1
        let task: Task<CGImage?, Never>
        let owner: Bool
        if let running = inFlight[keyString] {
            task = running
            owner = false
        } else {
            let created = Task<CGImage?, Never> {
                guard let data = await self.data(for: url) else { return nil }
                guard self.hasWaiters(for: keyString) else { return nil }
                return await Self.downsample(data, maxPixels: pixels)
            }
            inFlight[keyString] = created
            task = created
            owner = true
        }
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.dropWaiter(for: keyString) }
        }
        if !Task.isCancelled { dropWaiter(for: keyString) }
        if owner {
            inFlight[keyString] = nil
            if let image {
                memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            }
        }
        return image
    }

    private func hasWaiters(for key: String) -> Bool {
        waiters[key, default: 0] > 0
    }

    private func dropWaiter(for key: String) {
        let remaining = (waiters[key] ?? 0) - 1
        if remaining > 0 { waiters[key] = remaining } else { waiters[key] = nil }
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
    @Environment(\.listMotion) private var listMotion
    @ViewState private var loaded: CGImage?
    @ViewState private var loadedURL: URL?
    /// Keeps a synchronously cached image alive across `ArtworkCache.trim()`
    /// without writing `@ViewState` and causing a second layout pass on scroll-in.
    @ViewState private var retained = RetainedArtwork()

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

    private func resolvedImage() -> CGImage? {
        if let url, let cached = ArtworkCache.shared.cached(url, pixels: pixels) {
            retained.store(cached, for: url)
            return cached
        }
        if retained.url == url, let kept = retained.image { return kept }
        return loadedURL == url ? loaded : nil
    }

    var body: some View {
        let image = resolvedImage()
        let displayedURL = image == nil ? nil : url
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
            guard let url else {
                retained.clear()
                if loaded != nil || loadedURL != nil { loaded = nil; loadedURL = nil }
                return
            }
            if let cached = ArtworkCache.shared.cached(url, pixels: pixels) {
                retained.store(cached, for: url)
                return
            }
            let image = await ArtworkCache.shared.image(for: url, pixels: pixels)
            guard !Task.isCancelled else { return }
            if let image { retained.store(image, for: url) }
            // In a scrolling list a cover just appears: its fade would be an
            // animation, and each animation frame mid-scroll updates the whole window.
            var transaction = Transaction()
            transaction.disablesAnimations = listMotion?.isMoving == true
            withTransaction(transaction) {
                loaded = image
                loadedURL = url
            }
        }
    }
}

@MainActor
private final class RetainedArtwork {
    var image: CGImage?
    var url: URL?

    func store(_ image: CGImage, for url: URL) {
        self.image = image
        self.url = url
    }

    func clear() {
        image = nil
        url = nil
    }
}
