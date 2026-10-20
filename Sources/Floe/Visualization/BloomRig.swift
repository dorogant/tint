import Foundation
import simd

/// Bloom: a Julia set, z ← z² + c, that the music plays. Its outline glows as
/// thin filaments in the cover's colours on a dark ground. A lens frames part of
/// the set's edge off-centre rather than the whole set, and each layer of the
/// music has its own job and, apart from the harmony, its own place in the frame:
///
/// | Music                              | Fractal                                                          |
/// |------------------------------------|------------------------------------------------------------------|
/// | Harmony (pitch class, tonality)    | the shape, everywhere: each pitch class has its own c, and the set glides to the one playing |
/// | Bass envelope                      | the drift's pace and a slow breath toward finer filigree         |
/// | Kick                               | a patch of the set shatters to dust around its own epicentre and knits back, the shatter spreading out (a small pull in first); each kick lands somewhere else |
/// | Snare, clap                        | a local twist around its own point, across the frame from the last kick, that unwinds |
/// | Hat                                | glints in the outer filaments, where the orbits pass a small turning constellation |
/// | Mids envelope (vocals, leads)      | soft light pools in the bulbs under a slowly wandering voice     |
/// | Highs envelope and brightness      | finer filaments and deeper detail                                |
/// | Build, then drop                   | a slow dive toward the lens's edge point, released with one wave of light from it |
/// | Sections (a drop, every 32 beats)  | the lens glides to another part of the edge                      |
/// | Beat phase (a steady groove)       | a faint swell of the glow on each beat                           |
///
/// Kicks change the shape, never the brightness, so nothing flashes. With no
/// clear harmony (drums, noise, or analysis that doesn't report it) the shape
/// drifts slowly on its own; in silence it all but stops and the lens widens
/// to the whole set.
struct BloomRig {
    /// One shape per pitch class, C first, as the multiplier λ = ρe^{iθ} of the
    /// set's fixed point (see `c(theta:rho:)`): θ goes round the Mandelbrot set's
    /// main cardioid, and ρ just under 1 is a plump, joined set while past 1 it
    /// turns to dust. Picked from a contact sheet of the whole circle and
    /// rising round it, so a glide between neighbouring notes passes
    /// only through the shapes between them. Each angle is one where a kick's
    /// push leaves the Mandelbrot set cleanly (into dust, not into a bulb);
    /// the lower half mirrors the upper, so the radii alternate between fine
    /// filigree and plumper sets to tell each mirrored pair apart.
    static let shapes: [(theta: Float, radius: Float)] = [
        (0.44, 0.975), (0.87, 0.96), (1.31, 0.98), (1.75, 0.965), (2.27, 0.975), (2.88, 0.96),
        (3.40, 0.98), (3.84, 0.965), (4.45, 0.975), (4.97, 0.96), (5.41, 0.98), (5.85, 0.965),
    ]
    /// How far a full snare twists the plane at its point, at the peak.
    static let facet = Float.pi / 6
    /// The deepest a build dives toward the set's edge, beyond the lens.
    static let maximumZoom: Float = 4
    /// The lens's magnification while music plays; silence widens it to 1.
    static let lensDepth: Float = 2
    /// Kicks shattering at once, each in its own patch.
    static let kickSlots = 3
    /// How far past the cardioid's edge a full kick throws the set (at Bass punch
    /// 100%), wherever its shape sits: far enough to open it into spirals of dust.
    /// Softer kicks only pinch it.
    static let shatterPast: Float = 0.03

    /// The shape's angle round the cardioid (unwrapped) and its radius.
    private(set) var theta = Spring(position: shapes[0].theta)
    private(set) var radius = Spring(position: shapes[0].radius)
    /// Where the shape drifts on its own, with no clear harmony.
    private var wander = shapes[0].theta
    /// One kick's shatter, added to the radius around its epicentre.
    struct Kick {
        var shatter = Spring()
        /// In screen units: y runs −1…1, x the same scaled by the aspect ratio.
        var epicentre = SIMD2<Float>(0, 0)
        /// How far it reaches as it lands; it spreads further as it ages.
        var reach: Float = 0.5
        var age: Float = 10
        /// The outward push lands a moment after the small inward pull.
        var pending: (delay: Float, strength: Float)?

        /// The reach in screen units as it stands.
        var spread: Float { min(2.2, reach + 1.4 * age) }
    }
    private(set) var kicks = [Kick](repeating: Kick(), count: kickSlots)
    private var kicksHeard = 0
    /// The plane's slow drift.
    private(set) var turn = Spring()
    private var turnGoal: Float = 0
    /// The snare's twist at its point, in radians: kicked, then unwinding.
    private(set) var twist = Spring()
    private(set) var twistCentre = SIMD2<Float>(-0.4, 0.3)
    private var snaresHeard = 0
    /// The build's dive: 0 at rest, 1 at the deepest zoom.
    private(set) var dive = Spring()
    /// Points on the set's edge the lens can frame: the repelling fixed point β,
    /// its twin −β and their first preimages, followed as the shape changes.
    private var anchors = [SIMD2<Float>](repeating: SIMD2(0.5, 0), count: 8)
    private var anchorIndex = 0
    /// The lens's centre on the plane, gliding toward the anchor it frames, so a
    /// chord change or a section never yanks the view.
    private var lensX = Spring(position: 0.5), lensY = Spring()
    private(set) var lensZoom = Spring(position: 1)
    private var sinceMove: Float = 0
    private var beatsAtMove: Float = 0
    /// Where the vocals' light pools, in screen units, and its slow clock.
    private(set) var voice = SIMD2<Float>(-0.3, 0.2)
    private var voicePhase: Float = 0
    /// Smoothed layers, at display rate.
    private(set) var bass: Float = 0
    private(set) var energy: Float = 0
    private(set) var heart: Float = 0
    private(set) var detail: Float = 0
    private(set) var tonality: Float = 0
    private(set) var tension: Float = 0
    /// Decaying after each hat.
    private(set) var glint: Float = 0
    /// The hat constellation's turn.
    private(set) var traps: Float = 0
    /// The drop's wave: seconds since it set out, and its strength.
    private(set) var wave: (age: Float, strength: Float) = (10, 0)
    /// The beat's swell, 0…1.
    private(set) var beat: Float = 0
    /// Overall brightness: dim in silence, full with the music.
    private(set) var level: Float = 0.5
    /// The palette's slow walk round the set.
    private(set) var hue: Float = 0
    /// The last step, for the trails' frame-rate independent fade.
    private(set) var lastStep: Float = 1 / 60
    private var latest = BeatDetector.Pulse()
    private var layers = MusicLayers()
    private var sinceSnare: Float = 1

    /// One analysis frame: hits land here, once each, as impulses on the springs.
    mutating func receive(_ pulse: BeatDetector.Pulse, layers: MusicLayers, configuration: BackgroundConfiguration) {
        latest = pulse
        self.layers = layers
        let react = configuration.reactivity
        let punch = configuration.punch * react
        if pulse.kick > 0, punch > 0 {
            let strength = min(1.4, pulse.kick * punch)
            // Each kick lands somewhere new: round the frame by the golden angle,
            // at varying distances from the middle.
            kicksHeard += 1
            let angle = Float(kicksHeard) * 2.39996
            let distance = 0.3 + 0.35 * (Float(kicksHeard) * 0.618034).truncatingRemainder(dividingBy: 1)
            let slot = quietestKick()
            // Anticipation: the set gathers itself in, then bursts.
            kicks[slot].shatter.velocity -= 0.15 * strength
            kicks[slot].epicentre = SIMD2(cos(angle), sin(angle)) * distance
            kicks[slot].reach = 0.5
            kicks[slot].age = 0
            kicks[slot].pending = (0.04, strength)
        }
        if pulse.snare > 0, punch > 0 {
            // Across the frame from the last kick, so the two never land together;
            // a roll twists no harder than a full hit every half second.
            snaresHeard += 1
            let last = kicks.min { $0.age < $1.age }.map(\.epicentre) ?? .zero
            let sway = Float(snaresHeard) * 1.3
            twistCentre = -last * 0.9 + SIMD2(cos(sway), sin(sway)) * 0.2
            let strength = min(1, pulse.snare * punch * 1.4) * min(1, sinceSnare / 0.5)
            twist.velocity += Self.twistVelocity * Self.facet * strength * (snaresHeard % 2 == 0 ? 1 : -1)
            sinceSnare = 0
        }
        if pulse.hat > 0 { glint = max(glint, min(1.2, pulse.hat * react)) }
        if layers.drop > 0 {
            let strength = min(1, layers.drop * react)
            wave = (0, max(strength, wave.age < 1 ? wave.strength : 0))
            // The drop bursts from the lens's own edge point, across most of the frame.
            let slot = quietestKick()
            kicks[slot].epicentre = focusOnScreen
            kicks[slot].reach = 1.2
            kicks[slot].age = 0
            kicks[slot].shatter.velocity += push(strength * min(1.5, configuration.punch))
            moveLens()
        }
    }

    /// The kick slot that has most nearly knit back.
    private func quietestKick() -> Int {
        kicks.indices.min { abs(kicks[$0].shatter.position) + abs(kicks[$0].shatter.velocity) * 0.1
            < abs(kicks[$1].shatter.position) + abs(kicks[$1].shatter.velocity) * 0.1 } ?? 0
    }

    /// Frames the next anchor; stepping by three visits all eight, each far from the last.
    private mutating func moveLens() {
        anchorIndex = (anchorIndex + 3) % anchors.count
        sinceMove = 0
        beatsAtMove = latest.beats
    }

    /// Moves the fractal on by `dt` seconds of display time.
    mutating func step(by dt: Float, configuration: BackgroundConfiguration) {
        lastStep = dt
        sinceSnare += dt
        let react = configuration.reactivity
        let speed = configuration.speed
        func follow(_ value: inout Float, _ target: Float, attack: Float, release: Float) {
            value += (target - value) * BeatDetector.rate(dt, target > value ? attack : release)
        }
        follow(&bass, min(1, latest.bass * react), attack: 0.25, release: 0.8)
        follow(&energy, latest.energy, attack: 0.3, release: 1.2)
        follow(&heart, min(1, latest.mid * react * (0.7 + 0.3 * latest.energy)), attack: 0.35, release: 0.7)
        follow(&detail, min(1, 0.7 * latest.high * react + 0.5 * layers.brightness), attack: 0.4, release: 0.9)
        follow(&tonality, layers.tonality, attack: 0.3, release: 1.5)
        follow(&tension, min(1, layers.build), attack: 0.5, release: 0.25)
        let sounding = BeatDetector.smoothstep(0, 0.12, energy)
        follow(&level, 0.5 + 0.5 * min(1, energy * react * 1.4), attack: 0.4, release: 1.6)

        // Harmony picks the shape; without it the shape wanders, at the bass's pace.
        let gate = BeatDetector.smoothstep(0.25, 0.6, tonality)
        wander += dt * speed * (0.004 + sounding * (0.03 + 0.09 * bass))
        let played = Self.shape(at: layers.pitchClass)
        wander += Self.wrap(played.theta - wander) * gate * BeatDetector.rate(dt, 2)
        let goal = wander + Self.wrap(played.theta - wander) * gate
        let resting = Self.radius(at: wander)
        let shapeRadius = resting + (played.radius - resting) * gate
        // Bass breathes the set out toward its finer filigree.
        theta.step(toward: theta.position + Self.wrap(goal - theta.position), frequency: 0.45, damping: 1, dt: dt)
        radius.step(toward: shapeRadius + 0.018 * bass, frequency: 0.6, damping: 1, dt: dt)

        for i in kicks.indices {
            if let pending = kicks[i].pending {
                if pending.delay - dt <= 0 {
                    kicks[i].shatter.velocity += push(pending.strength)
                    kicks[i].pending = nil
                } else {
                    kicks[i].pending = (pending.delay - dt, pending.strength)
                }
            }
            // Underdamped: shattered dust overshoots into a plumper set as it knits back.
            kicks[i].shatter.step(toward: 0, frequency: Self.shatterFrequency, damping: 0.5, dt: dt)
            kicks[i].age += dt
        }
        turnGoal += dt * speed * 0.012 * sounding
        turn.step(toward: turnGoal, frequency: 2.8, damping: 0.75, dt: dt)
        // Underdamped too: the twist swings a little past straight as it unwinds.
        twist.step(toward: 0, frequency: Self.twistFrequency, damping: 0.5, dt: dt)
        voicePhase += dt * speed * (0.04 + 0.12 * heart)
        voice = SIMD2(0.75 * sin(voicePhase + 0.7), 0.5 * sin(voicePhase * 1.37))
        // The dive glides in slowly, most of it in the build's last stretch, and
        // springs back past rest when the build lets go.
        let depth = tension * tension * tension
        let rising = depth > dive.position
        dive.step(toward: depth, frequency: rising ? 0.4 : 0.9, damping: rising ? 1 : 0.5, dt: dt)

        // The lens: a new part of the edge each section (a drop moves it in
        // `receive`), every 32 beats of a steady groove or 20 s without one,
        // never sooner than 8 s; never in silence, when it widens to the whole set.
        followAnchors()
        sinceMove += dt
        let grooving = latest.tempo > 0 && latest.confidence > 0.3
        if sounding > 0.5, sinceMove > 8, dive.position < 0.1,
           grooving ? latest.beats - beatsAtMove >= 32 : sinceMove > 20 {
            moveLens()
        }
        let anchor = anchors[anchorIndex]
        lensX.step(toward: anchor.x, frequency: 0.12, damping: 1, dt: dt)
        lensY.step(toward: anchor.y, frequency: 0.12, damping: 1, dt: dt)
        lensZoom.step(toward: 1 + (Self.lensDepth - 1) * sounding, frequency: 0.1, damping: 1, dt: dt)

        glint *= expf(-dt / 0.04)
        traps += dt * speed * (0.25 + 0.6 * latest.high)
        hue += dt * speed * 0.006 * (0.3 + sounding)
        wave.age += dt
        // A steady groove swells the glow on the beat, never a flash.
        let phase = latest.beats - latest.beats.rounded(.down)
        let steady = BeatDetector.smoothstep(0.3, 0.7, latest.confidence) * (latest.tempo > 0 ? 1 : 0)
        follow(&beat, steady * expf(-phase * 5), attack: 0.03, release: 0.12)
    }

    /// How far out the shape sits at the strongest kick's epicentre: the size of
    /// its fixed point's multiplier, under 1 inside the cardioid.
    var rho: Float {
        var strongest: Float = 0
        for kick in kicks where abs(kick.shatter.position) > abs(strongest) { strongest = kick.shatter.position }
        return max(0.5, radius.position + strongest)
    }

    /// c for the shape at rest, away from any kick.
    var c: SIMD2<Float> { Self.c(theta: theta.position, rho: max(0.5, radius.position)) }

    /// How deep the dive has gone, as a magnification (below 1 as it springs back).
    var zoom: Float { powf(Self.maximumZoom, dive.position) }

    /// The lens's magnification and the dive's together.
    var viewZoom: Float { lensZoom.position * zoom }

    /// The plane's span per screen half-height when the view isn't zoomed.
    static let span: Float = 1.3

    /// The edge point the lens frames, on the plane.
    var focus: SIMD2<Float> { SIMD2(lensX.position, lensY.position) }

    /// The plane's centre and its span per screen half-height, as a complex
    /// scale and turn. The focus glides from the middle of the screen at rest
    /// toward it as the view zooms, so the lens frames its edge off-centre.
    var view: (center: SIMD2<Float>, axis: SIMD2<Float>) {
        let zoom = viewZoom
        let axis = SIMD2(cos(turn.position), sin(turn.position)) * (Self.span / zoom)
        return (focus * (1 - 1 / (zoom * zoom)), axis)
    }

    /// Where the focus shows, in screen units.
    var focusOnScreen: SIMD2<Float> {
        let (center, axis) = view
        let d = focus - center
        return SIMD2(d.x * axis.x + d.y * axis.y, d.y * axis.x - d.x * axis.y) / max(simd_length_squared(axis), 1e-12)
    }

    /// Keeps the anchors on the set as its shape moves, each preimage taking the
    /// square root nearer where it was, so they glide rather than jump.
    private mutating func followAnchors() {
        let lambda = SIMD2(cos(theta.position), sin(theta.position)) * radius.position
        let c = Self.c(theta: theta.position, rho: radius.position)
        let beta = SIMD2<Float>(1, 0) - lambda / 2
        func root(_ z: SIMD2<Float>, near previous: SIMD2<Float>) -> SIMD2<Float> {
            let r = Self.squareRoot(z)
            return simd_distance_squared(r, previous) <= simd_distance_squared(-r, previous) ? r : -r
        }
        let r1 = root(-beta - c, near: anchors[2])
        let s1 = root(r1 - c, near: anchors[4]), s2 = root(-r1 - c, near: anchors[6])
        anchors[0] = beta; anchors[1] = -beta
        anchors[2] = r1; anchors[3] = -r1
        anchors[4] = s1; anchors[5] = -s1
        anchors[6] = s2; anchors[7] = -s2
    }

    private static func squareRoot(_ z: SIMD2<Float>) -> SIMD2<Float> {
        let r = simd_length(z)
        let x = sqrt(max(0, (r + z.x) / 2)), y = sqrt(max(0, (r - z.x) / 2))
        return SIMD2(x, z.y < 0 ? -y : y)
    }

    /// The shape a pitch class (fractional, gliding) plays.
    static func shape(at pitchClass: Float) -> (theta: Float, radius: Float) {
        let p = pitchClass - (pitchClass / 12).rounded(.down) * 12
        let i = Int(p) % 12, j = (i + 1) % 12
        let f = p - Float(Int(p))
        let a = shapes[i], b = shapes[j]
        return (a.theta + wrap(b.theta - a.theta) * f, a.radius + (b.radius - a.radius) * f)
    }

    /// The resting radius at an angle, between the two shapes it lies between.
    static func radius(at theta: Float) -> Float {
        let t = theta - (theta / (2 * .pi)).rounded(.down) * 2 * .pi
        guard let i = shapes.lastIndex(where: { $0.theta <= t }) else {
            let a = shapes[shapes.count - 1], b = shapes[0]
            let span = b.theta + 2 * .pi - a.theta
            return a.radius + (b.radius - a.radius) * (t + 2 * .pi - a.theta) / span
        }
        let a = shapes[i], b = shapes[(i + 1) % shapes.count]
        let span = wrapPositive(b.theta - a.theta)
        return a.radius + (b.radius - a.radius) * min(1, (t - a.theta) / span)
    }

    /// The c whose fixed point α = λ/2 has multiplier λ = ρe^{iθ}: c = λ/2 − λ²/4.
    /// At ρ = 1 that's the main cardioid's edge.
    static func c(theta: Float, rho: Float) -> SIMD2<Float> {
        let lambda = SIMD2(cos(theta), sin(theta)) * rho
        return lambda / 2 - SIMD2(lambda.x * lambda.x - lambda.y * lambda.y, 2 * lambda.x * lambda.y) / 4
    }

    /// The shatter spring's pace.
    static let shatterFrequency: Float = 2
    /// The push that peaks the shatter spring at 1 with damping 0.5: ω / e^(−ζ/√(1−ζ²)·acos ζ).
    static let kickVelocity: Float = 2 * .pi * shatterFrequency / 0.546
    /// The twist spring's pace, and the push that peaks it at 1 (same damping).
    static let twistFrequency: Float = 1.2
    static let twistVelocity: Float = 2 * .pi * twistFrequency / 0.546

    /// The push for a hit of `strength`: a full one carries the set from where it
    /// rests to `shatterPast` beyond the edge.
    private func push(_ strength: Float) -> Float {
        Self.kickVelocity * strength * (max(0, 1 - radius.position) + Self.shatterPast)
    }

    /// An angle difference brought into −π…π.
    static func wrap(_ angle: Float) -> Float {
        angle - (angle / (2 * .pi)).rounded() * 2 * .pi
    }

    private static func wrapPositive(_ angle: Float) -> Float {
        angle - (angle / (2 * .pi)).rounded(.down) * 2 * .pi
    }
}
