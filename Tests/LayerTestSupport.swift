import Observation
import SwiftUI

// Minimal stand-ins for the app models the layer views read, so the views can
// be compiled and rendered without the Rust core.

@MainActor @Observable final class VisualizationModel {
    var frame = SpectrumFrame.quiet
    var flow = 0.0
    var framesAnalyzed: UInt64 = 1
    var isRunning = false
    @ObservationIgnored private(set) var listeners: [ObjectIdentifier: () -> Void] = [:]

    func setFrameListener(for owner: AnyObject, _ listener: (() -> Void)?) {
        listeners[ObjectIdentifier(owner)] = listener
    }

    /// What the analysis worker does with each frame.
    func publish(_ frame: SpectrumFrame) {
        self.frame = frame
        framesAnalyzed += 1
        flow += 1.0 / 30
        for listener in listeners.values { listener() }
    }
}

@MainActor @Observable final class VisualSettings {
    enum Shape { case rays, bars, wave }
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
