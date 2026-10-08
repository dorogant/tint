import Foundation
import simd

/// Everything a live background takes from settings and the cover. Compared on
/// each SwiftUI update, so an unchanged configuration never redraws.
struct BackgroundConfiguration: Equatable {
    var kind = VisualSettings.BackgroundKind.fluid
    var colors = CoverColorExtractor.shades(of: .fallback)
    var reactivity: Float = 1
    var speed: Float = 1
    var glow: Float = 1
    var shake: Float = 1
    var vividness: Float = 1
    var beamCount = 6
    var strobe = false
}

typealias Palette = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

/// Matches `FluidUniforms` in `ReactiveShader`.
struct FluidUniforms {
    var colors: Palette
    /// Flow clock, energy and glow pulse, then a spare.
    var motion: SIMD4<Float>
    /// Drawable width and height, then the jolt's punch-in and a spare.
    var size: SIMD4<Float>
    /// The whole field's jolt, then the ripple's strength and age.
    var shake: SIMD4<Float>
    /// Where the last ripple started.
    var ripple: SIMD4<Float>
}

/// Matches `BeamUniforms` in `ReactiveShader`.
struct BeamUniforms {
    var colors: Palette
    /// Haze clock, shimmer, strobe flash, glow.
    var motion: SIMD4<Float>
    /// Drawable width and height, head count, floor beams' intensity.
    var size: SIMD4<Float>
    /// The floor beams' angle, spread and two palette slots.
    var floor: SIMD4<Float>
    /// Per head: angle from straight down, intensity, spread, palette slot.
    var heads: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}

/// The live background's state between frames, apart from Metal so tests can
/// step it frame by frame: the beat detector, the palette crossfade and each
/// kind's motion. Its clock only moves while it's advanced, so it freezes on pause.
struct BackgroundAnimator {
    private(set) var configuration = BackgroundConfiguration()
    private(set) var pulse = BeatDetector.Pulse()
    private var detector = BeatDetector()
    private var from = [SIMD3<Float>](repeating: .zero, count: CoverColorExtractor.paletteSize)
    private var to = [SIMD3<Float>](repeating: .zero, count: CoverColorExtractor.paletteSize)
    private var fade: Float = 1
    private(set) var fluid = FluidMotion()
    private(set) var beams = BeamRig()
    static let crossfade: Float = 1.6

    /// Running changes crossfade the palette; paused ones (and Reduce Motion) apply at once.
    mutating func configure(_ configuration: BackgroundConfiguration, animated: Bool) {
        self.configuration = configuration
        let target = Self.prepare(configuration.colors, vividness: configuration.vividness)
        guard target != to else { return }
        from = animated ? colors : target
        to = target
        fade = animated ? 0 : 1
    }

    /// Finishes a crossfade at once; true if one was under way.
    mutating func settle() -> Bool {
        guard fade < 1 else { return false }
        fade = 1
        return true
    }

    mutating func advance(by dt: Float, frame: SpectrumFrame) {
        let dt = min(max(dt, 0), 0.1)
        pulse = detector.update(frame, dt: dt)
        fade = min(1, fade + dt / Self.crossfade)
        switch configuration.kind {
        case .fluid: fluid.advance(by: dt, pulse: pulse, configuration: configuration)
        case .beams: beams.advance(by: dt, pulse: pulse, configuration: configuration)
        }
    }

    /// The palette as drawn now, eased between the old cover's colours and the new.
    /// Each slot turns at its own moment, so the ink changes colour blob by blob
    /// instead of every colour passing through grey together.
    var colors: [SIMD3<Float>] {
        zip(from, to).enumerated().map { i, pair in
            let start = Float(i) * 0.12
            let x = min(1, max(0, (fade - start) / 0.52))
            return pair.0 + (pair.1 - pair.0) * (x * x * (3 - 2 * x))
        }
    }

    func fluidUniforms(width: Float, height: Float) -> FluidUniforms {
        FluidUniforms(colors: Self.palette(colors),
                      motion: SIMD4(fluid.flow, min(1, pulse.energy * configuration.reactivity), fluid.glow, 0),
                      size: SIMD4(width, height, fluid.punch, 0),
                      shake: SIMD4(fluid.jolt.x, fluid.jolt.y, fluid.rippleStrength, fluid.rippleAge),
                      ripple: SIMD4(fluid.rippleCentre.x, fluid.rippleCentre.y, 0, 0))
    }

    func beamUniforms(width: Float, height: Float) -> BeamUniforms {
        let count = min(BeamRig.maximumHeads, max(1, configuration.beamCount))
        // Paired from the palette being faded to, so a crossfade can't swap a pair midway.
        let pair = beams.colorPair(to)
        let h = beams.heads(count: count, colors: pair)
        return BeamUniforms(colors: Self.palette(colors),
                            motion: SIMD4(beams.haze, beams.shimmer, beams.flash, configuration.glow),
                            size: SIMD4(width, height, Float(count), beams.floorLevel),
                            floor: SIMD4(beams.floorAngle, beams.spread, Float(pair.0), Float(pair.1)),
                            heads: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]))
    }

    /// Vividness pushes each colour away from (or toward) its own grey.
    private static func prepare(_ colors: [RGB], vividness: Float) -> [SIMD3<Float>] {
        let source = colors.isEmpty ? CoverColorExtractor.shades(of: .fallback) : colors
        return (0..<CoverColorExtractor.paletteSize).map { i in
            let c = source[i % source.count]
            let rgb = SIMD3<Float>(Float(c.r), Float(c.g), Float(c.b))
            let grey = SIMD3<Float>(repeating: (rgb * SIMD3(0.2126, 0.7152, 0.0722)).sum())
            return simd_clamp(grey + (rgb - grey) * vividness, .zero, .one)
        }
    }

    private static func palette(_ c: [SIMD3<Float>]) -> Palette {
        (SIMD4(c[0], 1), SIMD4(c[1], 1), SIMD4(c[2], 1), SIMD4(c[3], 1), SIMD4(c[4], 1))
    }
}

/// Fluid's motion: a flow clock that quickens with the music, a jolt and a
/// ripple on each beat that die out within a fraction of a second, and a glow
/// that swells with energy and flares on beats.
struct FluidMotion {
    private(set) var flow: Float = 0
    private(set) var glow: Float = 0
    private(set) var rippleCentre = SIMD2<Float>(0.8, 0.5)
    private(set) var rippleAge: Float = 10
    private(set) var rippleStrength: Float = 0
    private var joltAge: Float = 10
    private var joltStrength: Float = 0
    private var joltDirection = SIMD2<Float>(1, 0)
    private var random = SeededRandom(seed: 0x5EED)

    mutating func advance(by dt: Float, pulse: BeatDetector.Pulse, configuration: BackgroundConfiguration) {
        let react = configuration.reactivity
        flow += dt * configuration.speed * (0.4 + 0.6 * min(1, pulse.energy * react) + 0.8 * pulse.kick * react)
        joltAge += dt
        rippleAge += dt
        let hit = min(2.5, pulse.beat * react * configuration.shake)
        if hit > 0.02 {
            let angle = random.next() * 2 * .pi
            joltDirection = SIMD2(cos(angle), sin(angle))
            joltStrength = hit
            joltAge = 0
            rippleCentre = SIMD2(0.25 + 0.5 * random.next(), 0.25 + 0.5 * random.next())
            rippleStrength = hit
            rippleAge = 0
        }
        let target = configuration.glow * min(1.4, react * (0.3 * pulse.energy + 0.7 * pulse.kick))
        glow += (target - glow) * (target > glow ? 0.75 : BeatDetector.rate(dt, 0.3))
    }

    /// A short, damped back-and-forth: strongest on the beat's own frame.
    var jolt: SIMD2<Float> {
        joltDirection * joltStrength * 0.028 * cos(joltAge * 2 * .pi * 6) * expf(-joltAge * 11)
    }

    /// The field punches in slightly on a hit.
    var punch: Float { joltStrength * 0.025 * expf(-joltAge * 9) }
}

/// Deterministic, so test renders repeat exactly.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
}
