import CoreImage
import Observation
import SwiftUI

struct CoverPalette: Equatable {
    /// The interface accent, already readable on the dark glass: the cover's
    /// colour, a light silver for a black-and-white cover, or a fixed accent.
    let rgb: RGB
    /// Distinct cover colours for the live background, accent first; shades of
    /// the accent when there's no cover to read them from.
    let colors: [RGB]
    /// The cover has no colour of its own (black, white, grey): `rgb` is a
    /// silver and `colors` are the cover's tones with their faint cast.
    let isNeutral: Bool
    private let highlightRGB: RGB

    init(rgb: RGB = .fallback, colors: [RGB]? = nil, isNeutral: Bool = false) {
        self.rgb = rgb
        self.colors = colors ?? CoverColorExtractor.shades(of: rgb)
        self.isNeutral = isNeutral
        highlightRGB = CoverColorExtractor.highlight(of: rgb)
    }

    init(_ cover: CoverColorExtractor.Colors) {
        self.init(rgb: cover.accent, colors: cover.colors, isNeutral: cover.isNeutral)
    }

    var accent: Color { Color(red: rgb.r, green: rgb.g, blue: rgb.b) }
    /// The accent lightened for small text, icons and strokes on the dark glass,
    /// keeping its hue (lifting toward white turned deep reds dusty pink).
    var highlight: Color { Color(red: highlightRGB.r, green: highlightRGB.g, blue: highlightRGB.b) }
    var onAccent: Color { rgb.usesDarkText ? .black : .white }

    /// One of Settings' four fixed accents ("blue" for anything unknown). The app
    /// scene asks on every update, so each is built once (~6 µs of colour maths).
    static func fixed(_ name: String) -> CoverPalette {
        fixedPalettes[name] ?? fixedPalettes["blue"]!
    }

    private static let fixedPalettes: [String: CoverPalette] = [
        "green": CoverPalette(rgb: RGB(r: 0.12, g: 0.84, b: 0.38)),
        "violet": CoverPalette(rgb: RGB(r: 0.73, g: 0.5, b: 1)),
        "amber": CoverPalette(rgb: RGB(r: 1, g: 0.7, b: 0.3)),
        "blue": CoverPalette(rgb: .fallback),
    ]
}

private struct CoverPaletteKey: EnvironmentKey {
    static let defaultValue = CoverPalette()
}
extension EnvironmentValues {
    var coverPalette: CoverPalette {
        get { self[CoverPaletteKey.self] }
        set { self[CoverPaletteKey.self] = newValue }
    }
}

/// One cover and one tiny pre-blurred backdrop per track, shared by all views.
@MainActor
@Observable
final class CoverAppearance {
    private(set) var coverURL: URL?
    private(set) var image: CGImage?
    private(set) var imageURL: URL?
    private(set) var background: CGImage?
    private(set) var backgroundURL: URL?
    private(set) var palette = CoverPalette()
    @ObservationIgnored private var paletteURL: URL?

    func load(_ url: URL?, blur: Double = 9) async {
        guard !Task.isCancelled else { return }
        let sameCover = coverURL == url
        coverURL = url
        if url == nil {
            image = nil
            imageURL = nil
            background = nil
            backgroundURL = nil
            palette = CoverPalette()
            paletteURL = nil
        } else if sameCover {
            try? await Task.sleep(for: .milliseconds(120)) // coalesce slider drags
            guard !Task.isCancelled else { return }
        }
        guard let url else { return }
        if !sameCover {
            if let cached = ArtworkCache.shared.cached(url, pixels: 720)
                ?? ArtworkCache.shared.cached(url, pixels: 96) {
                image = cached
                imageURL = url
            }
        }
        async let cover = ArtworkCache.shared.image(for: url, pixels: 720)
        async let thumbnail = ArtworkCache.shared.image(for: url, pixels: 96)
        let loaded = await cover
        guard !Task.isCancelled else { return }
        image = loaded
        imageURL = url
        let small = await thumbnail
        guard !Task.isCancelled else { return }
        // A blur change reloads the same cover; its colours are already known.
        let known = paletteURL == url ? palette : nil
        let processed = await Self.process(small, blur: blur, known: known)
        guard !Task.isCancelled else { return }
        background = processed.background
        backgroundURL = url
        palette = processed.palette
        paletteURL = small == nil ? nil : url
    }

    /// The backdrop and (unless already known) the colours, off the main actor.
    @concurrent private nonisolated static func process(_ thumbnail: CGImage?, blur radius: Double,
                                                       known: CoverPalette?) async -> (background: CGImage?, palette: CoverPalette) {
        (thumbnail.flatMap { blur($0, radius: radius) }, known ?? thumbnail.map(palette) ?? CoverPalette())
    }

    /// The accent and the background's colours, read once per cover off the main thread.
    private nonisolated static func palette(of image: CGImage) -> CoverPalette {
        CoverColorExtractor.colors(of: image).map(CoverPalette.init) ?? CoverPalette()
    }

    /// The source is only 96 px: a CPU context, no full-window live blur or persistent
    /// GPU cache. Made once; building a context cost more than the blur itself.
    private nonisolated static let blurContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    private nonisolated static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(18, max(0, radius))])
        return blurContext.createCGImage(blurred, from: input.extent)
    }
}
