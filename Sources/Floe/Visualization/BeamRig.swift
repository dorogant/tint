import Foundation
import simd

/// Beams: a lighting rig that plays along with the song. Moving heads hang on a
/// truss along the top edge, uplights stand along the floor in two wings, and
/// each layer of the music has its own job, so you can tell the kick from the
/// hats from the vocal with the sound off:
///
/// | Music                                | Light                                                         |
/// |--------------------------------------|---------------------------------------------------------------|
/// | Bass envelope (kick body, bassline)  | the outer beams' brightness and width                         |
/// | Kick                                 | the outer beams punch outward and wobble back; their lenses flare |
/// | Snare, clap (hits in the mids)       | the inner beams flick across each other, alternating sides    |
/// | Highs envelope (hats, cymbals, air)  | the inner beams' brightness                                   |
/// | Hat                                  | motes drifting down the inner beams catch the light          |
/// | Mids envelope (vocals, leads)        | the haze fills with the cover's colour                        |
/// | Loudness                             | the floor beams: the corner pair in a loud passage, the next pairs as it builds |
/// | Loudness against the last seconds    | overall level and sweep size: a breakdown dims and calms, a drop lights the whole floor |
/// | Tempo and beat phase                 | sweeps turn on the beat; the look changes every eight bars; the opt-in strobe flashes on the beat |
///
/// Outer and inner blend across the truss, so with eight heads the middle pair
/// is almost all treble and the end pair almost all bass. Every head pivots on
/// damped springs, so beams swing with inertia, never jump, and settle when
/// the music goes quiet. Nothing moves that the music didn't move.
///
/// The rig is mirrored about the centre line: a head and its twin on the other
/// side always point opposite ways with the same light. Looks that leaned the
/// whole rig to one side, or put a different colour in each floor corner, read
/// as a mistake rather than a look (the owner, 2026-11-27).
struct BeamRig {
    enum Pattern: Int, CaseIterable { case fan, wave, scissors, converge }
    /// The uniforms carry one slot per head, eight in all (see `heads`).
    static let maximumHeads = 8
    /// Floor heads come in mirrored pairs, three at most: the corners, then inward.
    static let maximumFloorPairs = 3
    /// Strobe flashes stay at three a second or fewer (WCAG 2.3.1), like beats.
    static let flashInterval = BeatDetector.minimumInterval
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
    /// The floor beams: about a half in a loud passage, 1 on a drop.
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
    /// Each floor pair's lean toward the centre; the right wing mirrors the left.
    private(set) var floorAim = [Spring](repeating: Spring(), count: maximumFloorPairs)
    private var floorSwing = Spring()
    private var snareSide: Float = 1
    /// A new strobe flash is drawn at full strength before it starts to fade.
    private var flashHeld = false
    private var sincePattern: Float = 0
    private var sinceFlash: Float = 10
    /// Seconds since a kick counted as a beat: the strobe needs drums playing.
    private var sinceBeat: Float = 10
    /// The strobe's last beat of the clock, so each beat flashes once, and
    /// how many beats of the clock it takes as one.
    private var strobeBeat: Float = 0
    private var strobeStride: Float = 1
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
                swing[i].velocity += pulse.kick * punch * Self.outer(s) * Self.side(s) * 1.9
            }
            floorSwing.velocity += pulse.kick * punch * 1.2
            kickGlow = max(kickGlow, min(1.2, pulse.kick * react))
        }
        if pulse.snare > 0 {
            // The inner pairs cross on one hit and open on the next.
            for i in 0..<heads {
                let s = Self.position(i, count: heads)
                swing[i].velocity += pulse.snare * punch * (1 - Self.outer(s)) * -Self.side(s) * snareSide * 1.3
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
            sinceBeat = 0
            if pulse.lift > 0.85, sincePattern > 4 { change() }
            // With no tempo to follow, the strobe takes the kicks as they come.
            if !locked, pulse.beat > 0.5 { strobe(configuration) }
        }
    }

    /// The tempo is steady enough for the beat clock to place the strobe.
    private var locked: Bool { latest.tempo > 0 && confidence > 0.3 }

    /// One strobe flash, if the strobe is on, the music is loud and the last
    /// flash is far enough back: brighter when the song has just stepped up.
    private mutating func strobe(_ configuration: BackgroundConfiguration) {
        guard configuration.strobe, latest.energy > 0.35, sinceFlash >= Self.flashInterval else { return }
        flash = 0.75 + 0.25 * BeatDetector.smoothstep(0.5, 0.85, latest.lift)
        flashHeld = true
        flashes += 1
        sinceFlash = 0
    }

    /// Moves the rig on by `dt` seconds of display time.
    mutating func step(by dt: Float, configuration: BackgroundConfiguration) {
        let react = configuration.reactivity
        if !started {
            started = true
            for i in 0..<heads { aim[i].position = Self.aim(.fan, head: i, count: heads, beats: 0, period: 8, reach: reach) }
            for k in 0..<Self.maximumFloorPairs { floorAim[k].position = Self.floorAim(.fan, pair: k, beats: 0, period: 8, reach: reach) }
        }
        sincePattern += dt
        sinceFlash += dt
        sinceBeat += dt
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
        // The strobe flashes as the clock passes a beat, so it keeps even time
        // through kicks the detector misses and ignores the stray ones between
        // beats: on the raw kicks it came and went at random. It stops within
        // a second of the drums stopping. Every other beat above 165 BPM, where
        // each beat would pass three flashes a second.
        let stride: Float = rate > 2.75 ? 2 : 1
        let beat = (clock / stride).rounded(.down)
        if stride != strobeStride {
            // Counting beats differently isn't a beat passing.
            strobeStride = stride
        } else if beat > strobeBeat, locked, sinceBeat < 1.2 {
            strobe(configuration)
        }
        strobeBeat = beat

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
        // The floor holds about half its light through a loud passage, a little
        // more or less as the song swells and eases, and takes the rest on a drop.
        let drop = BeatDetector.smoothstep(0.62, 0.92, latest.lift) * min(1, latest.energy * react * 1.4)
        let loud = BeatDetector.smoothstep(0.3, 0.65, latest.energy) * min(1, react) * (0.3 + 0.4 * latest.lift)
        follow(&floorLevel, min(1, max(drop, loud)), attack: 0.15, release: 0.6)

        // Heavy fixtures: the choreography pulls each head on a soft spring with
        // a top speed; hits ride on a quicker, looser spring around it.
        let period = Self.period(pattern, speed: configuration.speed)
        for i in 0..<Self.maximumHeads {
            guard i < heads else { aim[i] = Spring(); swing[i] = Spring(); continue }
            let goal = Self.aim(pattern, head: i, count: heads, beats: clock, period: period, reach: reach)
            aim[i].step(toward: goal, frequency: 0.9, damping: 0.8, dt: dt, maximumSpeed: 2.2)
            swing[i].step(toward: 0, frequency: 2.4, damping: 0.3, dt: dt)
        }
        for k in 0..<Self.maximumFloorPairs {
            let goal = Self.floorAim(pattern, pair: k, beats: clock, period: period, reach: reach)
            floorAim[k].step(toward: goal, frequency: 0.9, damping: 0.8, dt: dt, maximumSpeed: 2.2)
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
    /// angle's sine; unused heads are zero. Tuples, as the shader takes them.
    func heads(count: Int, palette: [SIMD3<Float>], pair: (bass: Int, treble: Int)) -> (heads: Heads, tints: Heads) {
        func head(_ i: Int) -> (SIMD4<Float>, SIMD4<Float>) {
            guard i < count else { return (.zero, .zero) }
            let s = Self.position(i, count: count)
            let outer = Self.outer(s), inner = 1 - outer
            let low = 0.4 + 0.7 * bass + 1.3 * kickGlow
            let top = 0.4 + 0.7 * high + 0.9 * sparkle
            // The truss gives up some light as the floor comes on: with nothing
            // held back, the floor took Intense past the brightness white text can
            // stand (mean luma 0.204 just after a kick, against a limit of 0.2;
            // 0.194 with this, and 0.147 before there was a floor rig).
            let intensity = level * (outer * low + inner * top) * (1 - 0.15 * floorLevel)
            let spread = 0.042 * (0.8 + 0.2 * outer) * (1 + outer * (0.35 * bass + 0.5 * kickGlow))
            let glint = inner * min(1.2, 0.4 * high + sparkle)
            let color = palette[pair.treble] + (palette[pair.bass] - palette[pair.treble]) * outer
            let angle = started ? aim[i].position + swing[i].position : Self.aim(.fan, head: i, count: count, beats: 0, period: 8, reach: reach)
            // The sine rides along, so the shader needn't take one per pixel per beam.
            return (SIMD4(angle, intensity, spread, glint), SIMD4(color, sin(angle)))
        }
        let h = (head(0), head(1), head(2), head(3), head(4), head(5), head(6), head(7))
        return ((h.0.0, h.1.0, h.2.0, h.3.0, h.4.0, h.5.0, h.6.0, h.7.0),
                (h.0.1, h.1.1, h.2.1, h.3.1, h.4.1, h.5.1, h.6.1, h.7.1))
    }

    /// The floor heads, a pair to every two slots (left, then right): source x
    /// (aspect-scaled), direction x and y, intensity; then colour and spread.
    /// They lean in toward the centre, move with the look and kick further in
    /// with the bass. The corner pair lights first and the others join as the
    /// floor level rises. Their colours run the other way from the truss's,
    /// treble at the corners, so both colours show on each side.
    func floorHeads(count: Int, palette: [SIMD3<Float>], pair: (bass: Int, treble: Int), aspect: Float) -> (heads: FloorHeads, tints: FloorHeads) {
        let pairs = Self.floorPairs(heads: count)
        let spread = 0.042 * (1 + 0.5 * kickGlow)
        func head(_ slot: Int) -> (SIMD4<Float>, SIMD4<Float>) {
            let k = slot / 2
            guard k < pairs else { return (.zero, .zero) }
            let fk = Float(k)
            let joined = BeatDetector.smoothstep(0.22 * fk, 0.22 * fk + 0.25, floorLevel)
            // Each pair inward is dimmer, so a full floor doesn't outshine the truss.
            let intensity = floorLevel * joined * (0.55 + 0.5 * kickGlow) * (1 - 0.22 * fk)
            let lean = min(1.15, max(0.05, floorAim[k].position + floorSwing.position * (1 - 0.2 * fk)))
            let left = slot % 2 == 0
            let x = Self.floorPosition(k)
            let color = palette[pair.treble] + (palette[pair.bass] - palette[pair.treble]) * (pairs > 1 ? fk / Float(pairs - 1) : 0)
            return (SIMD4((left ? x : 1 - x) * aspect, (left ? 1 : -1) * sin(lean), cos(lean), intensity), SIMD4(color, spread))
        }
        let h = (head(0), head(1), head(2), head(3), head(4), head(5))
        return ((h.0.0, h.1.0, h.2.0, h.3.0, h.4.0, h.5.0), (h.0.1, h.1.1, h.2.1, h.3.1, h.4.1, h.5.1))
    }

    /// Floor pairs for a truss of `heads`: a small rig keeps a small floor.
    static func floorPairs(heads: Int) -> Int { min(maximumFloorPairs, heads / 2) }

    /// Where a floor pair's left head stands, as a share of the width: the
    /// corner, then inward. The middle of the floor stays clear for the truss.
    static func floorPosition(_ pair: Int) -> Float { 0.13 * Float(pair) }

    /// Where a head sits on the truss, -1 (left) to 1 (right).
    static func position(_ i: Int, count: Int) -> Float {
        count > 1 ? Float(i) / Float(count - 1) * 2 - 1 : 0
    }

    /// Which half of the truss a head is on: -1, 1, or 0 for one in the middle,
    /// which has no twin and so may only point straight down.
    static func side(_ s: Float) -> Float { s < 0 ? -1 : (s > 0 ? 1 : 0) }

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
    /// the right), `beats` into the song. Every turning point lands on a beat,
    /// and a head's twin across the centre always gets the opposite angle.
    static func aim(_ pattern: Pattern, head i: Int, count: Int, beats: Float, period: Float, reach: Float) -> Float {
        let s = position(i, count: count)
        let t = 2 * Float.pi * beats / period
        switch pattern {
        case .fan: return s * (0.1 + 0.45 * reach * (0.5 - 0.5 * cos(t)))
        // Each pair opens and crosses in turn, a ripple running out from the middle.
        case .wave: return side(s) * (0.1 * abs(s) + 0.34 * reach * sin(t - 0.8 * .pi * abs(s)))
        // Neighbours swing against each other, counted in from the ends so the two halves match.
        case .scissors: return side(s) * (min(i, count - 1 - i) % 2 == 0 ? 1 : -1) * 0.38 * reach * sin(t) + s * 0.1
        // Every head aims at one spot on the centre line, which rises and sinks.
        case .converge: return atanf((0.5 - (Float(i) + 0.5) / Float(count)) * 1.6 / focusDistance(t, reach: reach))
        }
    }

    /// How far a floor head of pair `pair` leans toward the centre, in radians
    /// from straight up. The floor answers the truss: its fan opens as the
    /// truss's closes, the wave runs on into it, and its heads converge on a
    /// spot as high above the floor as the truss's is below the truss, so at
    /// full reach the two meet mid-air.
    static func floorAim(_ pattern: Pattern, pair: Int, beats: Float, period: Float, reach: Float) -> Float {
        let t = 2 * Float.pi * beats / period
        let k = Float(pair)
        switch pattern {
        case .fan: return 0.5 + (k - 1) * (0.03 + 0.13 * reach * (0.5 + 0.5 * cos(t)))
        case .wave: return 0.5 + 0.05 * (k - 1) + 0.17 * reach * sin(t - .pi * (1 + 0.2 * k))
        case .scissors: return 0.5 + (pair % 2 == 0 ? 1 : -1) * 0.2 * reach * sin(t)
        case .converge: return atanf((0.5 - floorPosition(pair)) * 1.6 / focusDistance(t, reach: reach))
        }
    }

    /// How far from its heads a converging rig's spot is, in frame heights.
    private static func focusDistance(_ t: Float, reach: Float) -> Float { 0.9 + 0.38 * reach * sin(t) }

    private mutating func change() {
        pattern = Pattern(rawValue: (pattern.rawValue + 1) % Pattern.allCases.count)!
        scheme += 1
        sincePattern = 0
    }
}
