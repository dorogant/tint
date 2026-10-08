import Foundation
import Observation

@MainActor
@Observable
final class VisualSettings {
    enum Style: String, CaseIterable, Identifiable { case normal, circular; var id: Self { self } }
    enum Shape: String, CaseIterable, Identifiable { case bars, wave; var id: Self { self } }
    enum BackgroundKind: String, CaseIterable, Identifiable { case fluid, beams; var id: Self { self } }
    static let speedRange = 0.25...2.0
    static let glowRange = 0.0...2.0
    static let shakeRange = 0.0...2.0
    static let vividnessRange = 0.5...1.5
    static let beamCountRange = 4...8
    var showVisualizer: Bool { didSet { defaults.set(showVisualizer, forKey: "showVisualizer") } }
    var style: Style { didSet { defaults.set(style.rawValue, forKey: "visualizerStyle") } }
    var shape: Shape { didSet { defaults.set(shape.rawValue, forKey: "visualizerShape") } }
    var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: "visualizerSensitivity") } }
    var liveBackground: Bool { didSet { defaults.set(liveBackground, forKey: "liveBackground") } }
    var backgroundKind: BackgroundKind { didSet { defaults.set(backgroundKind.rawValue, forKey: "backgroundKind") } }
    var reactivity: Double { didSet { defaults.set(reactivity, forKey: "backgroundReactivity") } }
    var motionSpeed: Double { didSet { defaults.set(motionSpeed, forKey: "backgroundSpeed") } }
    var glow: Double { didSet { defaults.set(glow, forKey: "backgroundGlow") } }
    var shake: Double { didSet { defaults.set(shake, forKey: "backgroundShake") } }
    var vividness: Double { didSet { defaults.set(vividness, forKey: "backgroundVividness") } }
    var beamCount: Int { didSet { defaults.set(beamCount, forKey: "backgroundBeamCount") } }
    /// Opt-in: beat-synced full-frame flashes, never more than three a second.
    var strobe: Bool { didSet { defaults.set(strobe, forKey: "backgroundStrobe") } }
    var backgroundBlur: Double { didSet { defaults.set(backgroundBlur, forKey: "backgroundBlur") } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        func clamped<T: Comparable>(_ key: String, _ range: ClosedRange<T>, _ fallback: T) -> T {
            min(range.upperBound, max(range.lowerBound, defaults.object(forKey: key) as? T ?? fallback))
        }
        self.defaults = defaults
        showVisualizer = defaults.object(forKey: "showVisualizer") as? Bool ?? true
        style = Style(rawValue: defaults.string(forKey: "visualizerStyle") ?? "") ?? .circular
        shape = Shape(rawValue: defaults.string(forKey: "visualizerShape") ?? "") ?? .bars
        sensitivity = min(3, max(0.25, defaults.object(forKey: "visualizerSensitivity") as? Double ?? 1.2))
        liveBackground = defaults.bool(forKey: "liveBackground")
        backgroundKind = BackgroundKind(rawValue: defaults.string(forKey: "backgroundKind") ?? "") ?? .fluid
        backgroundBlur = min(18, max(0, defaults.object(forKey: "backgroundBlur") as? Double ?? 9))
        reactivity = min(2, max(0, defaults.object(forKey: "backgroundReactivity") as? Double ?? 1))
        motionSpeed = clamped("backgroundSpeed", Self.speedRange, 1)
        glow = clamped("backgroundGlow", Self.glowRange, 1)
        shake = clamped("backgroundShake", Self.shakeRange, 1)
        vividness = clamped("backgroundVividness", Self.vividnessRange, 1)
        beamCount = clamped("backgroundBeamCount", Self.beamCountRange, 6)
        strobe = defaults.bool(forKey: "backgroundStrobe")
    }
}
