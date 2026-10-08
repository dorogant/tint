import Foundation
import Observation

@MainActor
@Observable
final class VisualSettings {
    enum Style: String, CaseIterable, Identifiable { case normal, circular; var id: Self { self } }
    enum Shape: String, CaseIterable, Identifiable { case bars, wave; var id: Self { self } }
    var showVisualizer: Bool { didSet { defaults.set(showVisualizer, forKey: "showVisualizer") } }
    var style: Style { didSet { defaults.set(style.rawValue, forKey: "visualizerStyle") } }
    var shape: Shape { didSet { defaults.set(shape.rawValue, forKey: "visualizerShape") } }
    var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: "visualizerSensitivity") } }
    var liveBackground: Bool { didSet { defaults.set(liveBackground, forKey: "liveBackground") } }
    var reactivity: Double { didSet { defaults.set(reactivity, forKey: "backgroundReactivity") } }
    var backgroundBlur: Double { didSet { defaults.set(backgroundBlur, forKey: "backgroundBlur") } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showVisualizer = defaults.object(forKey: "showVisualizer") as? Bool ?? true
        style = Style(rawValue: defaults.string(forKey: "visualizerStyle") ?? "") ?? .circular
        shape = Shape(rawValue: defaults.string(forKey: "visualizerShape") ?? "") ?? .bars
        sensitivity = min(3, max(0.25, defaults.object(forKey: "visualizerSensitivity") as? Double ?? 1.2))
        liveBackground = defaults.bool(forKey: "liveBackground")
        backgroundBlur = min(18, max(0, defaults.object(forKey: "backgroundBlur") as? Double ?? 9))
        reactivity = min(2, max(0, defaults.object(forKey: "backgroundReactivity") as? Double ?? 1))
    }
}
