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

    func load(_ url: URL?) async {
        guard !Task.isCancelled else { return }
        coverURL = url
        image = nil
        background = nil
        palette = CoverPalette()
        guard let url else { return }
        async let cover = ArtworkCache.shared.image(for: url, pixels: 720)
        async let thumbnail = ArtworkCache.shared.image(for: url, pixels: 96)
        let (loaded, small) = await (cover, thumbnail)
        guard !Task.isCancelled else { return }
        let processed = await Task.detached(priority: .utility) {
            (small.flatMap(Self.blur), small.flatMap(CoverColorExtractor.extract))
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
        background = processed.0
        palette = CoverPalette(rgb: processed.1 ?? .fallback)
    }

    private nonisolated static func blur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
        // The source is only 96 px. No full-window live blur or persistent GPU cache.
        return CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
            .createCGImage(blurred, from: input.extent)
    }
}
