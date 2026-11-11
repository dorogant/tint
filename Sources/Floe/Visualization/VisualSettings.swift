import Foundation
import Observation

@MainActor
@Observable
final class VisualSettings {
    enum Style: String, CaseIterable, Identifiable { case normal, circular; var id: Self { self } }
    enum Shape: String, CaseIterable, Identifiable { case bars, wave; var id: Self { self } }
    enum BackgroundKind: String, CaseIterable, Identifiable { case fluid, beams; var id: Self { self } }
    nonisolated static let speedRange = 0.25...2.0
    nonisolated static let glowRange = 0.0...2.0
    nonisolated static let punchRange = 0.0...2.0
    nonisolated static let vividnessRange = 0.5...1.5
    nonisolated static let beamCountRange = 4...8
    var showVisualizer: Bool { didSet { defaults.set(showVisualizer, forKey: "showVisualizer") } }
    var style: Style { didSet { defaults.set(style.rawValue, forKey: "visualizerStyle") } }
    var shape: Shape { didSet { defaults.set(shape.rawValue, forKey: "visualizerShape") } }
    var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: "visualizerSensitivity") } }
    var liveBackground: Bool { didSet { defaults.set(liveBackground, forKey: "liveBackground") } }
    var backgroundKind: BackgroundKind { didSet { defaults.set(backgroundKind.rawValue, forKey: "backgroundKind"); edited() } }
    var reactivity: Double { didSet { defaults.set(reactivity, forKey: "backgroundReactivity"); edited() } }
    var motionSpeed: Double { didSet { defaults.set(motionSpeed, forKey: "backgroundSpeed"); edited() } }
    var glow: Double { didSet { defaults.set(glow, forKey: "backgroundGlow"); edited() } }
    /// How hard kicks move the light: Beams' outer beams, Fluid's breath.
    var punch: Double { didSet { defaults.set(punch, forKey: "backgroundPunch"); edited() } }
    var vividness: Double { didSet { defaults.set(vividness, forKey: "backgroundVividness"); edited() } }
    var beamCount: Int { didSet { defaults.set(beamCount, forKey: "backgroundBeamCount"); edited() } }
    /// Opt-in: beat-synced full-frame flashes, never more than three a second.
    /// No preset turns it on.
    var strobe: Bool { didSet { defaults.set(strobe, forKey: "backgroundStrobe") } }
    var backgroundBlur: Double { didSet { defaults.set(backgroundBlur, forKey: "backgroundBlur") } }
    /// Not part of any preset: it's about the Mac, not the look.
    /// The live background's preset; touching any knob it sets makes it `.custom`.
    private(set) var backgroundPreset: BackgroundPreset {
        didSet { defaults.set(backgroundPreset.rawValue, forKey: "backgroundPreset") }
    }
    /// Picks the preset for each song (see `AutoPresetController`). Choosing a
    /// preset or touching a knob by hand turns it off, so a look the user set
    /// never changes behind their back on the next song.
    var autoPreset: Bool {
        didSet {
            defaults.set(autoPreset, forKey: "backgroundAutoPreset")
            if !autoPreset { autoStatus = nil }
        }
    }
    /// What the auto preset chose for this song and why; nil while it's off.
    var autoStatus: AutoPresetStatus?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var applying = false

    init(defaults: UserDefaults = .standard) {
        func clamped<T: Comparable>(_ key: String, _ range: ClosedRange<T>, _ fallback: T) -> T {
            min(range.upperBound, max(range.lowerBound, defaults.object(forKey: key) as? T ?? fallback))
        }
        self.defaults = defaults
        // Someone who already tuned the knobs keeps them, as Custom; a fresh
        // install starts on Balanced.
        let tuned = ["backgroundKind", "backgroundReactivity", "backgroundSpeed", "backgroundGlow", "backgroundPunch",
                     "backgroundVividness", "backgroundBeamCount"].contains { defaults.object(forKey: $0) != nil }
        let preset = BackgroundPreset(rawValue: defaults.string(forKey: "backgroundPreset") ?? "") ?? (tuned ? .custom : .balanced)
        let fallback = BackgroundPreset.balancedLook
        showVisualizer = defaults.object(forKey: "showVisualizer") as? Bool ?? true
        style = Style(rawValue: defaults.string(forKey: "visualizerStyle") ?? "") ?? .circular
        shape = Shape(rawValue: defaults.string(forKey: "visualizerShape") ?? "") ?? .bars
        sensitivity = min(3, max(0.25, defaults.object(forKey: "visualizerSensitivity") as? Double ?? 1.2))
        liveBackground = defaults.bool(forKey: "liveBackground")
        backgroundKind = BackgroundKind(rawValue: defaults.string(forKey: "backgroundKind") ?? "") ?? fallback.kind
        backgroundBlur = min(18, max(0, defaults.object(forKey: "backgroundBlur") as? Double ?? 9))
        reactivity = min(2, max(0, defaults.object(forKey: "backgroundReactivity") as? Double ?? fallback.reactivity))
        motionSpeed = clamped("backgroundSpeed", Self.speedRange, fallback.speed)
        glow = clamped("backgroundGlow", Self.glowRange, fallback.glow)
        punch = clamped("backgroundPunch", Self.punchRange, fallback.punch)
        // "Shake" scaled Fluid's random jolt, which is gone; Punch is a new,
        // gentler effect on both kinds, so it starts fresh rather than inheriting it.
        defaults.removeObject(forKey: "backgroundShake")
        vividness = clamped("backgroundVividness", Self.vividnessRange, fallback.vividness)
        beamCount = clamped("backgroundBeamCount", Self.beamCountRange, fallback.beamCount)
        strobe = defaults.bool(forKey: "backgroundStrobe")
        // Bloom, a third kind, was removed; its detail setting goes with it.
        defaults.removeObject(forKey: "bloomQuality")
        autoPreset = defaults.bool(forKey: "backgroundAutoPreset")
        backgroundPreset = preset
    }

    /// The knobs as they stand.
    var backgroundLook: BackgroundLook {
        BackgroundLook(kind: backgroundKind, reactivity: reactivity, speed: motionSpeed, glow: glow,
                       vividness: vividness, punch: punch, beamCount: beamCount)
    }

    /// The look the user last tuned by hand, so Custom always brings it back.
    var customLook: BackgroundLook {
        defaults.dictionary(forKey: "backgroundCustomLook").flatMap(BackgroundLook.init(dictionary:)) ?? backgroundLook
    }

    /// One click per preset, for quick comparisons. Leaving Custom keeps its
    /// values; choosing Custom again brings them back. A choice by hand ends
    /// the auto preset.
    func choose(_ preset: BackgroundPreset) {
        autoPreset = false
        apply(preset)
    }

    /// The auto preset's choice for a song: like `choose`, but stays on auto.
    /// Never touches the strobe, which no preset turns on.
    func applyAutomatically(_ preset: BackgroundPreset) {
        apply(preset)
    }

    private func apply(_ preset: BackgroundPreset) {
        guard preset != backgroundPreset else { return }
        if backgroundPreset == .custom { defaults.set(backgroundLook.dictionary, forKey: "backgroundCustomLook") }
        let look = preset.look ?? customLook
        applying = true
        backgroundKind = look.kind
        reactivity = look.reactivity
        motionSpeed = look.speed
        glow = look.glow
        vividness = look.vividness
        punch = look.punch
        beamCount = look.beamCount
        applying = false
        backgroundPreset = preset
    }

    private func edited() {
        guard !applying else { return }
        if autoPreset { autoPreset = false }
        if backgroundPreset != .custom { backgroundPreset = .custom }
    }
}

/// What the auto preset shows under its checkbox.
enum AutoPresetStatus: Equatable {
    /// Looking up the genre, or listening to the song.
    case choosing
    /// From the artist's Spotify genre (as Spotify spells it).
    case genre(BackgroundPreset, String)
    /// From the sound, when Spotify had no genre.
    case sound(BackgroundPreset)
    /// No genre, and no analysis to listen with (Reduce Motion): the look stays.
    case noGenre(BackgroundPreset)
}

/// Every knob a preset sets. The strobe isn't one: it stays opt-in.
struct BackgroundLook: Equatable {
    var kind: VisualSettings.BackgroundKind
    var reactivity: Double
    var speed: Double
    var glow: Double
    var vividness: Double
    var punch: Double
    var beamCount: Int

    var dictionary: [String: Any] {
        ["kind": kind.rawValue, "reactivity": reactivity, "speed": speed, "glow": glow,
         "vividness": vividness, "punch": punch, "beamCount": beamCount]
    }

    init(kind: VisualSettings.BackgroundKind, reactivity: Double, speed: Double, glow: Double,
         vividness: Double, punch: Double, beamCount: Int) {
        self.kind = kind
        self.reactivity = reactivity
        self.speed = speed
        self.glow = glow
        self.vividness = vividness
        self.punch = punch
        self.beamCount = beamCount
    }

    init?(dictionary d: [String: Any]) {
        guard let kind = (d["kind"] as? String).flatMap(VisualSettings.BackgroundKind.init(rawValue:)),
              let reactivity = d["reactivity"] as? Double, let speed = d["speed"] as? Double, let glow = d["glow"] as? Double,
              let vividness = d["vividness"] as? Double, let punch = d["punch"] as? Double, let beams = d["beamCount"] as? Int
        else { return nil }
        func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T { min(range.upperBound, max(range.lowerBound, value)) }
        self.init(kind: kind, reactivity: clamp(reactivity, 0...2), speed: clamp(speed, VisualSettings.speedRange),
                  glow: clamp(glow, VisualSettings.glowRange), vividness: clamp(vividness, VisualSettings.vividnessRange),
                  punch: clamp(punch, VisualSettings.punchRange), beamCount: clamp(beams, VisualSettings.beamCountRange))
    }
}

/// Starting points for the live background, tuned to how each kind of music
/// lands on the layers (see `BeamRig`): general ones by intensity, genre ones
/// by what carries the music.
enum BackgroundPreset: String, CaseIterable, Identifiable {
    case custom, subtle, balanced, intense, club, hipHop, rock, chill, acoustic
    var id: Self { self }
    static let general: [Self] = [.subtle, .balanced, .intense]
    static let genres: [Self] = [.club, .hipHop, .rock, .chill, .acoustic]
    static let balancedLook = BackgroundLook(kind: .beams, reactivity: 1, speed: 1, glow: 1, vividness: 1, punch: 1, beamCount: 6)

    /// The localization key.
    var title: String {
        switch self {
        case .custom: "Custom"
        case .subtle: "Subtle"
        case .balanced: "Balanced"
        case .intense: "Intense"
        case .club: "Club"
        case .hipHop: "Hip-hop"
        case .rock: "Rock"
        case .chill: "Chill"
        case .acoustic: "Acoustic"
        }
    }

    /// Nil for Custom, which is whatever the user last tuned.
    var look: BackgroundLook? {
        switch self {
        case .custom: nil
        // Fluid, slow and soft: there, but never asking for attention.
        case .subtle: BackgroundLook(kind: .fluid, reactivity: 0.6, speed: 0.6, glow: 0.6, vividness: 0.85, punch: 0.4, beamCount: 6)
        // Everything at its natural strength.
        case .balanced: Self.balancedLook
        // The full rig, loud and bright, kicks shoving the outer beams.
        case .intense: BackgroundLook(kind: .beams, reactivity: 1.4, speed: 1.3, glow: 1.3, vividness: 1.25, punch: 1.8, beamCount: 8)
        // Four-on-the-floor: eight heads so the hats have a bright middle to
        // glint in, sweeps on the beat, strong kick punches.
        case .club: BackgroundLook(kind: .beams, reactivity: 1.3, speed: 1, glow: 1.3, vividness: 1.2, punch: 1.6, beamCount: 8)
        // Laid back: half-time sweeps, and the heaviest punch for 808s.
        case .hipHop: BackgroundLook(kind: .beams, reactivity: 1.2, speed: 0.5, glow: 1.2, vividness: 1.1, punch: 2, beamCount: 6)
        // Fewer, bolder heads: two for the kick and bass, two for the cymbals,
        // with guitars and vocals filling the smoke.
        case .rock: BackgroundLook(kind: .beams, reactivity: 1.1, speed: 1, glow: 1.2, vividness: 1.1, punch: 1.3, beamCount: 4)
        // Slow ink that breathes gently with soft bass.
        case .chill: BackgroundLook(kind: .fluid, reactivity: 0.85, speed: 0.45, glow: 1, vividness: 1.05, punch: 0.6, beamCount: 6)
        // Little bass and few drums: the slowest, calmest ink, following the playing's dynamics.
        case .acoustic: BackgroundLook(kind: .fluid, reactivity: 0.75, speed: 0.35, glow: 0.8, vividness: 0.9, punch: 0.3, beamCount: 6)
        }
    }
}
