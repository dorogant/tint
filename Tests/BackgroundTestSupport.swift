import Observation
import SwiftUI

// The production Metal renderer with synthetic analysis and no auth/audio core.
@MainActor @Observable final class VisualizationModel {
    var backgroundFailure: String?
    var backgroundFramesDrawn: UInt64 = 0
    var frame = SpectrumFrame.quiet
    var isRunning = false
}

@MainActor @Observable final class VisualSettings { var reactivity = 1.0 }
struct CoverPalette { var rgb = RGB.fallback }
private struct CoverPaletteKey: EnvironmentKey {
    static let defaultValue = CoverPalette()
}
extension EnvironmentValues {
    var coverPalette: CoverPalette {
        get { self[CoverPaletteKey.self] }
        set { self[CoverPaletteKey.self] = newValue }
    }
}
enum L10n { static func string(_ text: String) -> String { text } }
