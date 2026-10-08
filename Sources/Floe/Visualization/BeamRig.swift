import Foundation
import simd

/// Beams: a lighting rig that plays along with the song. Moving heads hang on a
/// truss along the top edge, and each layer of the music has its own job, so
/// you can tell the kick from the hats from the vocal with the sound off:
///
/// | Music                                | Light                                                         |
/// |--------------------------------------|---------------------------------------------------------------|
/// | Bass envelope (kick body, bassline)  | the outer beams' brightness and width                         |
/// | Kick                                 | the outer beams punch outward and wobble back; their lenses flare |
/// | Snare, clap (hits in the mids)       | the inner beams flick across each other, alternating sides    |
/// | Highs envelope (hats, cymbals, air)  | the inner beams' brightness                                   |
/// | Hat                                  | a glint on the inner beams and glitter in the haze they cross |
/// | Mids envelope (vocals, leads)        | the haze fills with the cover's colour                        |
/// | Loudness against the last seconds    | overall level and sweep size: a breakdown dims and calms, a drop brings in the floor beams |
/// | Tempo and beat phase                 | sweeps turn on the beat; the look changes every eight bars    |
///
/// Outer and inner blend across the truss, so with eight heads the middle pair
/// is almost all treble and the end pair almost all bass. Every head pivots on
/// damped springs, so beams swing with inertia, never jump, and settle when
/// the music goes quiet. Nothing moves that the music didn't move.
struct BeamRig {
    enum Pattern: Int, CaseIterable { case fan, sweep, scissors, converge }
    static let maximumHeads = 8
    /// Strobe flashes stay at three a second or fewer (WCAG 2.3.1).
    static let flashInterval: Float = 0.34
    /// Beats between looks when the tempo is known: eight bars of four.
    static let phrase: Float = 32
    private(set) var pattern = Pattern.fan
    /// The rig's beat clock: runs at the song's tempo, nudged into phase with it.
    private(set) var clock: Float = 0
    private(set) var haze: Float = 0
    /// Overall brightness. Starts dim rather than dark, so a paused frame shows the rig.
    private(set) var level: Float = 0.1
    private(set) var flash: Float = 0
    /// Strobe flashes so far.
    private(set) var flashes = 0
    /// The corner beams from the floor join in on drops.
    private(set) var floorLevel: Float = 0
    /// How much of the vocal/lead layer fills the haze.
    private(set) var hazeFill: Float = 0
    /// Smoothed layers, at display rate.
    private(set) var bass: Float = 0
    private(set) var high: Float = 0
    private(set) var energy: Float = 0
    /// Decaying after each kick and each hat.
    private(set) var kickGlow: Float = 0
    private(set) var sparkle: Float = 0
    /// How far the choreography swings: small in a quiet passage.
    private(set) var reach: Float = 0.4
    private var latest = BeatDetector.Pulse()
    private var rate: Float = 1.5
    private var confidence: Float = 0
    /// Each head's choreographed aim, and the hits riding on it.
    private(set) var aim = [Spring](repeating: Spring(), count: maximumHeads)
    private(set) var swing = [Spring](repeating: Spring(), count: maximumHeads)
    private var floorSwing = Spring()
    private var snareSide: Float = 1
    /// A new strobe flash is drawn at full strength before it starts to fade.
    private var flashHeld = false
    private var sincePattern: Float = 0
    private var sinceFlash: Float = 10
    private var scheme = 0
    private var heads = 6
    /// Until the music first moves it, the rig stands in its resting fan (what
    /// a paused or Reduce Motion frame shows).
    private var started = false

    /// One analysis frame: hits land here, once each, as impulses on the springs.
    mutating func receive(_ pulse: BeatDetector.Pulse, configuration: BackgroundConfiguration) {
        latest = pulse
        heads = min(Self.maximumHeads, max(1, configuration.beamCount))
        let react = configuration.reactivity
        let punch = configuration.punch * react
        if pulse.kick > 0 {
            // Outward, strongest on the end heads, like a punch from below.
            for i in 0..<heads {
                let s = Self.position(i, count: heads)
                swing[i].velocity += pulse.kick * punch * Self.outer(s) * (s < 0 ? -1 : 1) * 1.9
            }
            floorSwing.velocity += pulse.kick * punch * 1.2
            kickGlow = max(kickGlow, min(1.2, pulse.kick * react))
        }
        if pulse.snare > 0 {
            // The inner pairs cross on one hit and open on the next.
            for i in 0..<heads {
                let s = Self.position(i, count: heads)
                swing[i].velocity += pulse.snare * punch * (1 - Self.outer(s)) * (s < 0 ? 1 : -1) * snareSide * 1.3
            }
            snareSide = -snareSide
        }
        if pulse.hat > 0 { sparkle = max(sparkle, min(1.2, pulse.hat * react)) }
        if pulse.tempo > 0, pulse.confidence > 0.1 {
            // Slew into phase with the song instead of jumping to it.
            var error = (pulse.beats - pulse.beats.rounded(.down)) - (clock - clock.rounded(.down))
            error -= error.rounded()
            clock += error * 0.2 * min(1, pulse.confidence * 1.5)
        }
        if pulse.beat > 0 {
            if pulse.lift > 0.85, sincePattern > 4 { change() }
            if configuration.strobe, pulse.beat > 0.5, pulse.energy > 0.35, sinceFlash >= Self.flashInterval {
                flash = 1
                flashHeld = true
                flashes += 1
                sinceFlash = 0
            }
        }
    }

    /// Moves the rig on by `dt` seconds of display time.
    mutating func step(by dt: Float, configuration: BackgroundConfiguration) {
        let react = configuration.reactivity
        if !started {
            started = true
            for i in 0..<heads { aim[i].position = Self.aim(.fan, head: i, count: heads, beats: 0, period: 8, reach: reach) }
        }
        sincePattern += dt
        sinceFlash += dt
        haze += dt * configuration.speed * (0.4 + 0.5 * energy)

        // The clock runs at the song's tempo when there is one; otherwise at an
        // easy pace that slows down in quiet music and stops in silence, so the
        // rig comes to rest.
        confidence += (latest.confidence - confidence) * BeatDetector.rate(dt, 0.6)
        let free: Float = 1.6 * (0.35 + 0.65 * energy)
        let song = latest.tempo > 0 ? latest.tempo / 60 : free
        let sounding = BeatDetector.smoothstep(0, 0.12, energy)
        rate += ((free + (song - free) * min(1, confidence * 1.5)) * sounding - rate) * BeatDetector.rate(dt, 0.5)
        let previous = clock
        clock += dt * rate
        if (previous / Self.phrase).rounded(.down) != (clock / Self.phrase).rounded(.down), sincePattern > 6 { change() }

        func follow(_ value: inout Float, _ target: Float, attack: Float, release: Float) {
            value += (target - value) * BeatDetector.rate(dt, target > value ? attack : release)
        }
        follow(&bass, latest.bass, attack: 0.03, release: 0.14)
        follow(&high, latest.high, attack: 0.03, release: 0.1)
        follow(&energy, latest.energy, attack: 0.15, release: 0.4)
        // Slow to rise, quick to fall: a held vocal or lead fills the haze, while
        // the brief click of a kick in the mids barely registers.
        follow(&hazeFill, latest.mid * (0.6 + 0.4 * latest.energy), attack: 0.7, release: 0.25)
        kickGlow *= expf(-dt / 0.16)
        sparkle *= expf(-dt / 0.07)
        if flashHeld { flashHeld = false } else { flash *= expf(-dt / 0.045) }

        let target = min(1.3, 0.06 + react * (0.15 + 0.55 * latest.energy) * (0.35 + 1.05 * latest.lift))
        follow(&level, target, attack: 0.1, release: 0.5)
        let calm = BeatDetector.smoothstep(0.08, 0.55, latest.energy) * (0.45 + 0.55 * latest.lift)
        follow(&reach, 0.3 + 0.7 * min(1, calm * 1.4), attack: 0.6, release: 1.2)
        let drop = BeatDetector.smoothstep(0.62, 0.92, latest.lift) * min(1, latest.energy * react * 1.4)
        follow(&floorLevel, drop, attack: 0.15, release: 0.6)

        // Heavy fixtures: the choreography pulls each head on a soft spring with
        // a top speed; hits ride on a quicker, looser spring around it.
        let period = Self.period(pattern, speed: configuration.speed)
        for i in 0..<Self.maximumHeads {
            guard i < heads else { aim[i] = Spring(); swing[i] = Spring(); continue }
            let goal = Self.aim(pattern, head: i, count: heads, beats: clock, period: period, reach: reach)
            aim[i].step(toward: goal, frequency: 0.9, damping: 0.8, dt: dt, maximumSpeed: 2.2)
            swing[i].step(toward: 0, frequency: 2.4, damping: 0.3, dt: dt)
        }
        floorSwing.step(toward: 0, frequency: 2, damping: 0.35, dt: dt)
    }

    /// Two contrasting palette slots per look: the bass colour (outer beams) leads
    /// with the next colour each time the look changes, and the treble colour
    /// (inner beams) is the one least like it.
    func colorPair(_ palette: [SIMD3<Float>]) -> (bass: Int, treble: Int) {
        let first = scheme % palette.count
        let second = palette.indices.max {
            simd_distance(palette[$0], palette[first]) < simd_distance(palette[$1], palette[first])
        } ?? first
        return (first, second)
    }

    /// Each head's angle, intensity, spread and glint, and its colour and the
    /// angle's sine; unused heads are zero.
    func heads(count: Int, palette: [SIMD3<Float>], pair: (bass: Int, treble: Int)) -> [(SIMD4<Float>, SIMD4<Float>)] {
        (0..<Self.maximumHeads).map { i in
            guard i < count else { return (.zero, .zero) }
            let s = Self.position(i, count: count)
            let outer = Self.outer(s), inner = 1 - outer
            let low = 0.4 + 0.7 * bass + 1.3 * kickGlow
            let top = 0.4 + 0.7 * high + 0.9 * sparkle
            let intensity = level * (outer * low + inner * top)
            let spread = 0.042 * (0.8 + 0.2 * outer) * (1 + outer * (0.35 * bass + 0.5 * kickGlow))
            let glint = inner * min(1.2, 0.4 * high + sparkle)
            let color = palette[pair.treble] + (palette[pair.bass] - palette[pair.treble]) * outer
            let angle = started ? aim[i].position + swing[i].position : Self.aim(.fan, head: i, count: count, beats: 0, period: 8, reach: reach)
            // The sine rides along, so the shader needn't take one per pixel per beam.
            return (SIMD4(angle, intensity, spread, glint), SIMD4(color, sin(angle)))
        }
    }

    /// The floor beams lean in from the corners, scissor slowly with the bars and
    /// kick outward with the bass.
    var floorAngle: Float { 0.5 + 0.18 * reach * sin(clock * .pi / 8) + floorSwing.position }
    var floorSpread: Float { 0.05 * (1 + 0.5 * kickGlow) }

    /// Where a head sits on the truss, -1 (left) to 1 (right).
    static func position(_ i: Int, count: Int) -> Float {
        count > 1 ? Float(i) / Float(count - 1) * 2 - 1 : 0
    }

    /// How much a head at `s` belongs to the bass: 1 at the ends, near 0 in the middle.
    static func outer(_ s: Float) -> Float { powf(abs(s), 1.4) }

    /// Beats per cycle. Speed picks the musical subdivision (half time, normal,
    /// double), so sweeps keep turning on the beat at any setting.
    static func period(_ pattern: Pattern, speed: Float) -> Float {
        let multiple = powf(2, min(1, max(-2, log2f(max(speed, 0.01)).rounded())))
        let beats: Float = pattern == .scissors ? 4 : 8
        return beats / multiple
    }

    /// Where a pattern points a head, in radians from straight down (positive to
    /// the right), `beats` into the song. Every turning point lands on a beat.
    static func aim(_ pattern: Pattern, head i: Int, count: Int, beats: Float, period: Float, reach: Float) -> Float {
        let s = position(i, count: count)
        let t = 2 * Float.pi * beats / period
        switch pattern {
        case .fan: return s * (0.1 + 0.45 * reach * (0.5 - 0.5 * cos(t)))
        case .sweep: return s * 0.12 + 0.42 * reach * sin(t - 0.35 * .pi * s)
        case .scissors: return (i % 2 == 0 ? 1 : -1) * 0.38 * reach * sin(t) + s * 0.1
        case .converge:
            // Every head aims at one spot on the floor that drifts across the stage.
            let x = (Float(i) + 0.5) / Float(count)
            let focus = 0.5 + 0.3 * reach * sin(t)
            return atanf((focus - x) * 1.6 / 0.9)
        }
    }

    private mutating func change() {
        pattern = Pattern(rawValue: (pattern.rawValue + 1) % Pattern.allCases.count)!
        scheme += 1
        sincePattern = 0
    }
}
