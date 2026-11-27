import Foundation
import Synchronization
import simd

/// What the analysis hands the live background and what the background reports
/// back, without either going through the main thread: the background draws on
/// a thread of its own, and a busy interface must not hold up a frame.
final class BackgroundFeed: Sendable {
    private struct Unread {
        var frame: SpectrumFrame?
        var count = 0
    }
    private let unread = Mutex(Unread())
    private let drawn = Atomic<UInt64>(0)

    /// From the analysis queue, 30 times a second. The newest frame carries the
    /// hits of the few before it that nobody drew, so a kick between two draws
    /// isn't lost; more than a few means nobody is drawing (the background is
    /// off), and old hits don't pile up.
    func post(_ frame: SpectrumFrame) {
        unread.withLock { unread in
            unread.count += 1
            if unread.count <= 4, let earlier = unread.frame {
                unread.frame = frame.folding(onsetsOf: earlier)
            } else {
                unread.frame = frame
            }
        }
    }

    /// For the background's display link: each analysis frame once, or nil when
    /// nothing new has arrived since the last draw.
    func take() -> SpectrumFrame? {
        unread.withLock { unread in
            defer { unread = Unread() }
            return unread.frame
        }
    }

    func clear() { unread.withLock { $0 = Unread() } }

    /// Frames that reached the screen.
    var framesDrawn: UInt64 { drawn.load(ordering: .relaxed) }
    func countFrame() { drawn.add(1, ordering: .relaxed) }
}

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
typealias Blobs = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
typealias Heads = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                   SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
typealias FloorHeads = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

/// Matches `FluidUniforms` in `ReactiveShader`.
struct FluidUniforms {
    var colors: Palette
    /// Flow clock, energy, glow, fine detail (the highs).
    var motion: SIMD4<Float>
    /// Drawable width and height, the bass breath, the ink's body (the mids).
    var size: SIMD4<Float>
    /// Per blob: centre x (aspect-scaled), centre y, inverse squared radius, spare.
    /// Precomputed on the CPU so the fragment shader skips 18 sines and 6 divides per pixel.
    var blobs: Blobs
}

/// Matches `BeamUniforms` in `ReactiveShader`.
struct BeamUniforms {
    var colors: Palette
    /// Haze clock, the haze fill (the mids), strobe flash, glow.
    var motion: SIMD4<Float>
    /// Drawable width and height, head count, floor head count.
    var size: SIMD4<Float>
    /// The haze's colour, then 1 for a neutral cover.
    var haze: SIMD4<Float>
    /// Average palette colour, then a spare.
    var average: SIMD4<Float>
    /// Per head: angle from straight down, intensity, spread, glint.
    var heads: Heads
    /// Per head: colour, then the sine of its angle.
    var tints: Heads
    /// Per head: source x (aspect-scaled), direction x, direction y, spare.
    var geometry: Heads
    /// Per floor head: source x (aspect-scaled), direction x, direction y, intensity.
    var floorHeads: FloorHeads
    /// Per floor head: colour, then spread.
    var floorTints: FloorHeads
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
        let fade = fade
        func share(_ i: Int) -> Float {
            let x = min(1, max(0, (fade - Float(i) * 0.12) / 0.52))
            return x * x * (3 - 2 * x)
        }
        for i in colors.indices { colors[i] = from[i] + (to[i] - from[i]) * share(i) }
    }

    func fluidUniforms(width: Float, height: Float) -> FluidUniforms {
        let t = fluid.flow
        let aspect = width / max(height, 1)
        func blob(_ i: Int) -> SIMD4<Float> {
            let fi = Float(i)
            let cx = (0.5 + 0.4 * sinf(t * (0.21 + 0.037 * fi) + fi * 2.39)) * aspect
            let cy = 0.5 + 0.38 * sinf(t * (0.17 + 0.045 * fi) + fi * 1.31 + 1.6)
            let radius = 0.2 + 0.05 * sinf(t * 0.4 + fi * 1.9)
            return SIMD4(cx, cy, 1 / (radius * radius), 0)
        }
        return FluidUniforms(colors: Self.palette(colors),
                             motion: SIMD4(t, min(1, pulse.energy * configuration.reactivity), fluid.glow, fluid.detail),
                             size: SIMD4(width, height, fluid.breath.position, fluid.body),
                             blobs: (blob(0), blob(1), blob(2), blob(3), blob(4), blob(5)))
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
        let aspect = width / max(height, 1)
        let invCount = aspect / Float(count)
        func geom(_ i: Int, _ tint: SIMD4<Float>) -> SIMD4<Float> {
            let s = tint.w
            return SIMD4((Float(i) + 0.5) * invCount, s, -sqrtf(max(0, 1 - s * s)), 0)
        }
        let geometry: Heads = (
            geom(0, rig.tints.0), geom(1, rig.tints.1), geom(2, rig.tints.2), geom(3, rig.tints.3),
            geom(4, rig.tints.4), geom(5, rig.tints.5), geom(6, rig.tints.6), geom(7, rig.tints.7)
        )
        let floor = beams.floorHeads(count: count, palette: palette, pair: pair, aspect: aspect)
        return BeamUniforms(colors: Self.palette(palette),
                            motion: SIMD4(beams.haze, fill, beams.flash, configuration.glow),
                            size: SIMD4(width, height, Float(count), Float(2 * BeamRig.floorPairs(heads: count))),
                            haze: SIMD4(haze, configuration.neutral ? 1 : 0),
                            average: SIMD4(average, 0),
                            heads: rig.heads, tints: rig.tints, geometry: geometry,
                            floorHeads: floor.heads, floorTints: floor.tints)
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
