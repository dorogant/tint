import CoreImage
import Observation
import SwiftUI

struct CoverPalette: Equatable {
    var rgb = RGB.fallback
    var accent: Color { Color(red: rgb.r, green: rgb.g, blue: rgb.b) }
    /// Lift dark cover colors only for small text/icons on the dark glass.
    var highlight: Color {
        let lift = rgb.luminance < 0.2 ? 0.4 : 0.0
        return Color(red: rgb.r + (1 - rgb.r) * lift,
                     green: rgb.g + (1 - rgb.g) * lift,
                     blue: rgb.b + (1 - rgb.b) * lift)
    }
    static func fixed(_ name: String) -> CoverPalette {
        let rgb: RGB = switch name {
        case "blue": RGB(r: 0.32, g: 0.65, b: 1)
        case "violet": RGB(r: 0.73, g: 0.5, b: 1)
        case "amber": RGB(r: 1, g: 0.7, b: 0.3)
        default: .fallback
        }
        return CoverPalette(rgb: rgb)
    }
    var onAccent: Color { rgb.usesDarkText ? .black : .white }
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
    private(set) var background: CGImage?
    private(set) var palette = CoverPalette()

    func load(_ url: URL?, blur: Double = 9) async {
        guard !Task.isCancelled else { return }
        let sameCover = coverURL == url
        coverURL = url
        if !sameCover {
            image = nil
            background = nil
            palette = CoverPalette()
        } else {
            try? await Task.sleep(for: .milliseconds(120)) // coalesce slider drags
            guard !Task.isCancelled else { return }
        }
        guard let url else { return }
        if !sameCover {
            image = ArtworkCache.shared.cached(url, pixels: 720)
                ?? ArtworkCache.shared.cached(url, pixels: 96)
        }
        async let cover = ArtworkCache.shared.image(for: url, pixels: 720)
        async let thumbnail = ArtworkCache.shared.image(for: url, pixels: 96)
        let loaded = await cover
        guard !Task.isCancelled else { return }
        image = loaded
        let small = await thumbnail
        guard !Task.isCancelled else { return }
        let processed = await Task.detached(priority: .utility) {
            (small.flatMap { Self.blur($0, radius: blur) }, small.flatMap(CoverColorExtractor.extract))
        }.value
        guard !Task.isCancelled else { return }
        background = processed.0
        palette = CoverPalette(rgb: processed.1 ?? .fallback)
    }

    private nonisolated static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(18, max(0, radius))])
        // The source is only 96 px. No full-window live blur or persistent GPU cache.
        return CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
            .createCGImage(blurred, from: input.extent)
    }
}
