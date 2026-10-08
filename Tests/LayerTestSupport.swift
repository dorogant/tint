import Observation
import SwiftUI

// Minimal stand-ins for the app models the layer views read, so the views can
// be compiled and rendered without the Rust core.

@MainActor @Observable final class VisualizationModel {
    var frame = SpectrumFrame.quiet
    var flow = 0.0
    var framesAnalyzed: UInt64 = 1
    var isRunning = false
}

@MainActor @Observable final class VisualSettings {
    enum Shape { case bars, wave }
    var shape = Shape.bars
    var sensitivity = 1.0
}

struct CoverPalette { var highlight = Color.blue }

private struct CoverPaletteKey: EnvironmentKey {
    static var defaultValue: CoverPalette { CoverPalette() }
}

extension EnvironmentValues {
    var coverPalette: CoverPalette {
        get { self[CoverPaletteKey.self] }
        set { self[CoverPaletteKey.self] = newValue }
    }
}
