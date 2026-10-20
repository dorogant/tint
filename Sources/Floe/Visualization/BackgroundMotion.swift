import Foundation
import simd

/// Everything a live background takes from settings and the cover. Compared on
/// each SwiftUI update, so an unchanged configuration never redraws.
struct BackgroundConfiguration: Equatable {
    var kind = VisualSettings.BackgroundKind.fluid
    var colors = CoverColorExtractor.shades(of: .fallback)
    /// A black-and-white or grey cover: its palette is silver with at most a faint
    /// cast, so Beams play it as clean white stage light on darker, untinted haze.
    var neutral = false
    var reactivity: Float = 1
    var speed: Float = 1
    var glow: Float = 1
    /// How hard kicks move things: Beams' outer beams and Fluid's breath.
    var punch: Float = 1
    var vividness: Float = 1
    var beamCount = 6
    var strobe = false
}

typealias Palette = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
typealias Heads = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                   SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

/// Matches `FluidUniforms` in `ReactiveShader`.
struct FluidUniforms {
    var colors: Palette
    /// Flow clock, energy, glow, fine detail (the highs).
    var motion: SIMD4<Float>
    /// Drawable width and height, the bass breath, the ink's body (the mids).
    var size: SIMD4<Float>
}

/// Matches `BeamUniforms` in `ReactiveShader`.
struct BeamUniforms {
    var colors: Palette
    /// Haze clock, a spare, strobe flash, glow.
    var motion: SIMD4<Float>
    /// Drawable width and height, head count, floor beams' intensity.
    var size: SIMD4<Float>
    /// The floor beams' angle and spread, the haze fill (the mids), the angle's sine.
    var floor: SIMD4<Float>
    /// The haze's colour, then 1 for a neutral cover.
    var haze: SIMD4<Float>
    /// The left and right floor beams' colours.
    var floorColors: (SIMD4<Float>, SIMD4<Float>)
    /// Per head: angle from straight down, intensity, spread, glint.
    var heads: Heads
    /// Per head: colour, then the sine of its angle.
    var tints: Heads
}

/// Matches `BloomLayer` in `ReactiveShader`: one dive as the shader draws it.
struct BloomLayerUniforms {
    /// The pixel's offset from the reference's c at screen point v is b + a·v: a, then b.
    var view: SIMD4<Float>
    /// The reference orbit's period, what brings escape counts to the whole set's, two spares.
    var counts: SIMD4<Float>
    /// The reference's c, and 1 over the scale its copy of the set is drawn at (complex).
    var bulbs: SIMD4<Float>
    /// The reference orbit, one period from 0.
    var orbit: InlineArray<64, SIMD2<Float>>
}

/// Matches `BloomPass` in `ReactiveShader`: one dive's field pass.
struct BloomPassUniforms {
    /// Which of the uniforms' layers.
    var layer: Int32
    /// How far apart the field's pixels are, in screen units.
    var pixel: Float
}

/// Matches `BloomUniforms` in `ReactiveShader`.
struct BloomUniforms {
    var colors: Palette
    /// Iterations, filament width in drawable pixels, how far the next dive has faded in, spare.
    var view: SIMD4<Float>
    /// Drawable width and height, then where the dive heads, in screen units.
    var size: SIMD4<Float>
    /// Glow, the heart's light (the mids), glints (hats and snares), the beat's swell.
    var light: SIMD4<Float>
    /// Where along the filaments the glints sit, two spares, the palette's walk.
    var glints: SIMD4<Float>
    /// The drop's wave (radius, strength), overall level, the bass's breath.
    var wave: SIMD4<Float>
    /// The dive under way, then the one fading in.
    var layers: (BloomLayerUniforms, BloomLayerUniforms)
}

/// The live background's state between frames, apart from Metal so tests can
/// step it frame by frame: the beat detector, the palette crossfade and each
/// kind's motion. Analysis frames arrive at 30 Hz through `receive`; `step`
/// moves the motion on at whatever rate the display draws. Its clock only
/// moves while it's stepped, so it freezes on pause.
struct BackgroundAnimator {
    private(set) var configuration = BackgroundConfiguration()
    private(set) var pulse = BeatDetector.Pulse()
    private var detector = BeatDetector()
    private var from = [SIMD3<Float>](repeating: .zero, count: CoverColorExtractor.paletteSize)
    private var to = [SIMD3<Float>](repeating: .zero, count: CoverColorExtractor.paletteSize)
    private var fade: Float = 1
    /// The palette as drawn now, eased between the old cover's colours and the new.
    /// Kept up to date as the crossfade moves, so drawing a frame allocates nothing.
    private(set) var colors = [SIMD3<Float>](repeating: .zero, count: CoverColorExtractor.paletteSize)
    private(set) var fluid = FluidMotion()
    private(set) var beams = BeamRig()
    /// Settable so a test can start Bloom partway down a dive.
    var bloom = BloomRig()
    static let crossfade: Float = 1.6
    /// The analysis rate, which is the detector's time step whatever the display does.
    static let analysisInterval: Float = 1 / 30

    /// Running changes crossfade the palette; paused ones (and Reduce Motion) apply at once.
    mutating func configure(_ configuration: BackgroundConfiguration, animated: Bool) {
        self.configuration = configuration
        let target = Self.prepare(configuration.colors, vividness: configuration.vividness)
        guard target != to else { return }
        from = animated ? colors : target
        to = target
        fade = animated ? 0 : 1
        blend()
    }

    /// Finishes a crossfade at once; true if one was under way.
    mutating func settle() -> Bool {
        guard fade < 1 else { return false }
        fade = 1
        blend()
        return true
    }

    /// One new analysis frame. Hits are read here, exactly once each.
    mutating func receive(_ frame: SpectrumFrame) {
        pulse = detector.update(frame, dt: Self.analysisInterval)
        switch configuration.kind {
        case .fluid: fluid.receive(pulse, configuration: configuration)
        case .beams: beams.receive(pulse, configuration: configuration)
        case .bloom: bloom.receive(pulse, layers: frame.layers, configuration: configuration)
        }
    }

    /// Moves everything on by `dt` seconds of display time.
    mutating func step(by dt: Float) {
        let dt = min(max(dt, 0), 0.1)
        if fade < 1 {
            fade = min(1, fade + dt / Self.crossfade)
            blend()
        }
        switch configuration.kind {
        case .fluid: fluid.step(by: dt, pulse: pulse, configuration: configuration)
        case .beams: beams.step(by: dt, configuration: configuration)
        case .bloom: bloom.step(by: dt, configuration: configuration)
        }
    }

    /// One analysis frame and `dt` of motion, as tests and a 30 Hz display see it.
    mutating func advance(by dt: Float, frame: SpectrumFrame) {
        receive(frame)
        step(by: dt)
    }

    /// Updates `colors` for the crossfade's progress. Each slot turns at its own
    /// moment, so the ink changes colour blob by blob instead of every colour
    /// passing through grey together.
    private mutating func blend() {
        for i in colors.indices {
            let start = Float(i) * 0.12
            let x = min(1, max(0, (fade - start) / 0.52))
            colors[i] = from[i] + (to[i] - from[i]) * (x * x * (3 - 2 * x))
        }
    }

    func fluidUniforms(width: Float, height: Float) -> FluidUniforms {
        FluidUniforms(colors: Self.palette(colors),
                      motion: SIMD4(fluid.flow, min(1, pulse.energy * configuration.reactivity), fluid.glow, fluid.detail),
                      size: SIMD4(width, height, fluid.breath.position, fluid.body))
    }

    func beamUniforms(width: Float, height: Float) -> BeamUniforms {
        let count = min(BeamRig.maximumHeads, max(1, configuration.beamCount))
        let palette = colors
        // Paired from the palette being faded to, so a crossfade can't swap a pair midway.
        let pair = beams.colorPair(to)
        let rig = beams.heads(count: count, palette: palette, pair: pair)
        let average = palette.reduce(SIMD3<Float>.zero, +) / Float(palette.count)
        // The vocal colour: the cover's accent, softened toward the whole palette;
        // nearly grey for a neutral cover, so silver light isn't muddied.
        var haze = palette[0] * 0.6 + average * 0.4
        if configuration.neutral { haze = haze * 0.3 + SIMD3(repeating: (haze * SIMD3(0.2126, 0.7152, 0.0722)).sum()) * 0.7 }
        let fill = min(1.2, beams.hazeFill * configuration.reactivity) * (configuration.neutral ? 0.7 : 1)
        return BeamUniforms(colors: Self.palette(palette),
                            motion: SIMD4(beams.haze, 0, beams.flash, configuration.glow),
                            size: SIMD4(width, height, Float(count), beams.floorLevel * (0.75 + 0.5 * beams.kickGlow)),
                            floor: SIMD4(beams.floorAngle, beams.floorSpread, fill, sin(beams.floorAngle)),
                            haze: SIMD4(haze, configuration.neutral ? 1 : 0),
                            floorColors: (SIMD4(palette[pair.bass], 0), SIMD4(palette[pair.treble], 0)),
                            heads: rig.heads, tints: rig.tints)
    }

    func bloomUniforms(width: Float, height: Float) -> BloomUniforms {
        let rig = bloom
        let detail = rig.detail
        let wave = rig.wave.strength * expf(-rig.wave.age / 0.6)
        let views = rig.views
        let current = Self.layer(views.current, BloomRig.destinations[rig.destination])
        let incoming = rig.next.map { Self.layer(views.incoming ?? views.current, BloomRig.destinations[$0]) }
        return BloomUniforms(colors: Self.palette(colors),
                             view: SIMD4(BloomRig.iterations, 1.3 - 0.5 * detail, rig.blend, 0),
                             size: SIMD4(width, height, rig.focus.x, rig.focus.y),
                             light: SIMD4(configuration.glow, rig.heart, rig.glint, rig.beat),
                             glints: SIMD4(rig.sparkle, 0, 0, rig.hue),
                             wave: SIMD4(rig.wave.age * 1.5, wave, rig.level, rig.bass),
                             layers: (current, incoming ?? current))
    }

    /// A dive as the shader draws it: each pixel follows its tiny offset from
    /// the destination's reference orbit, so single precision holds all the way down.
    private static func layer(_ view: BloomView, _ destination: BloomDestination) -> BloomLayerUniforms {
        BloomLayerUniforms(view: SIMD4(Float(view.perScreenUnit.re), Float(view.perScreenUnit.im),
                                       Float(view.offset.re), Float(view.offset.im)),
                           counts: SIMD4(Float(destination.period), Float(view.colorScale), 0, 0),
                           bulbs: SIMD4(Float(destination.nucleus.re), Float(destination.nucleus.im),
                                        Float(destination.inverseScale.re), Float(destination.inverseScale.im)),
                           orbit: destination.orbit)
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

/// Fluid: ink in water that moves only as the music does. The current's pace
/// follows the song's loudness over a couple of seconds, so it never lurches;
/// the bass breathes the whole field in from the centre and out again (kicks
/// make it swell, never jolt); kicks and energy brighten the glow on the
/// brightest ink; vocals fill the ink out and the highs bring up fine strands.
struct FluidMotion {
    private(set) var flow: Float = 0
    private(set) var glow: Float = 0
    /// The bass breath: 0 at rest, about 1 on a full kick.
    private(set) var breath = Spring()
    /// The mids, filling the ink.
    private(set) var body: Float = 0
    /// The highs, sharpening the strands.
    private(set) var detail: Float = 0
    private var pace: Float = 0
    private var swell: Float = 0

    mutating func receive(_ pulse: BeatDetector.Pulse, configuration: BackgroundConfiguration) {
        if pulse.kick > 0 { swell = max(swell, min(1.2, pulse.kick * configuration.reactivity)) }
    }

    mutating func step(by dt: Float, pulse: BeatDetector.Pulse, configuration: BackgroundConfiguration) {
        let react = configuration.reactivity
        pace += (pulse.energy - pace) * BeatDetector.rate(dt, 1.5)
        flow += dt * configuration.speed * (0.35 + 0.65 * min(1, pace * react))
        swell *= expf(-dt / 0.3)
        // Critically damped: the field swells and settles without wobbling.
        let depth = configuration.punch * react * (0.45 * pulse.bass + 0.7 * swell)
        breath.step(toward: min(1.5, depth), frequency: 1.3, damping: 1, dt: dt)
        let target = configuration.glow * min(1.4, react * (0.3 * pulse.energy + 0.45 * swell + 0.15 * pulse.bass))
        glow += (target - glow) * BeatDetector.rate(dt, target > glow ? 0.08 : 0.4)
        body += (min(1, pulse.mid * react) - body) * BeatDetector.rate(dt, 0.4)
        detail += (min(1, pulse.high * react) - detail) * BeatDetector.rate(dt, 0.3)
    }
}
