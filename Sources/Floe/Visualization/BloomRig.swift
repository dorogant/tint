import Foundation
import simd

/// Bloom: a Julia set, z ← z² + c, that the music plays. Its outline glows as
/// thin filaments in the cover's colours on a dark ground, and each layer of
/// the music has its own job:
///
/// | Music                              | Fractal                                                          |
/// |------------------------------------|------------------------------------------------------------------|
/// | Harmony (pitch class, tonality)    | the shape: each pitch class has its own c, and the set glides to the one playing |
/// | Bass envelope                      | the drift's pace and a slow breath toward finer filigree         |
/// | Kick                               | the set shatters to dust and knits back on a spring (a small pull in first) |
/// | Snare, clap                        | the plane turns a twelfth of a turn, like a ratchet              |
/// | Hat                                | glints where the orbits pass a small turning constellation       |
/// | Mids envelope (vocals, leads)      | the set's heart fills with soft coloured light                   |
/// | Highs envelope and brightness      | finer filaments and deeper detail                                |
/// | Build, then drop                   | a slow dive toward the set's edge, released with one wave of light |
/// | Beat phase (a steady groove)       | a faint swell of the glow on each beat                           |
///
/// Kicks change the shape, never the brightness, so nothing flashes. With no
/// clear harmony (drums, noise, or analysis that doesn't report it) the shape
/// drifts slowly on its own; in silence it all but stops.
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
    /// The snare's ratchet: a twelfth of a turn, so six hits bring the set (which
    /// looks the same turned half way round) back to where it started.
    static let facet = Float.pi / 6
    /// The deepest a build dives toward the set's edge.
    static let maximumZoom: Float = 4
    /// How far past the cardioid's edge a full kick throws the set (at Bass punch
    /// 100%), wherever its shape sits: far enough to open it into spirals of dust.
    /// Softer kicks only pinch it.
    static let shatterPast: Float = 0.03

    /// The shape's angle round the cardioid (unwrapped) and its radius.
    private(set) var theta = Spring(position: shapes[0].theta)
    private(set) var radius = Spring(position: shapes[0].radius)
    /// Where the shape drifts on its own, with no clear harmony.
    private var wander = shapes[0].theta
    /// The kick's shatter, added to the radius.
    private(set) var shatter = Spring()
    /// The plane's turn: the snare's ratchet and a slow drift.
    private(set) var turn = Spring()
    private var turnGoal: Float = 0
    /// The build's dive: 0 at rest, 1 at the deepest zoom.
    private(set) var dive = Spring()
    /// Where the dive heads: the edge point β of the shape at rest, eased so a
    /// kick or a chord change doesn't yank a deep zoom sideways.
    private(set) var focus = SIMD2<Float>(0.5, 0)
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
    /// A kick's outward push lands a moment after its small inward pull.
    private var pendingKick: (delay: Float, strength: Float)?

    /// One analysis frame: hits land here, once each, as impulses on the springs.
    mutating func receive(_ pulse: BeatDetector.Pulse, layers: MusicLayers, configuration: BackgroundConfiguration) {
        latest = pulse
        self.layers = layers
        let react = configuration.reactivity
        let punch = configuration.punch * react
        if pulse.kick > 0, punch > 0 {
            let strength = min(1.4, pulse.kick * punch)
            // Anticipation: the set gathers itself in, then bursts.
            shatter.velocity -= 0.15 * strength
            pendingKick = (0.04, strength)
        }
        if pulse.snare > 0, punch > 0 {
            // A roll turns no faster than a facet every half second.
            turnGoal += Self.facet * min(1, pulse.snare * punch * 1.4) * min(1, sinceSnare / 0.5)
            sinceSnare = 0
        }
        if pulse.hat > 0 { glint = max(glint, min(1.2, pulse.hat * react)) }
        if layers.drop > 0 {
            let strength = min(1, layers.drop * react)
            wave = (0, max(strength, wave.age < 1 ? wave.strength : 0))
            shatter.velocity += push(strength * min(1.5, configuration.punch))
        }
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

        if var kick = pendingKick {
            kick.delay -= dt
            if kick.delay <= 0 {
                shatter.velocity += push(kick.strength)
                pendingKick = nil
            } else {
                pendingKick = kick
            }
        }
        // Underdamped: shattered dust overshoots into a plumper set as it knits back.
        shatter.step(toward: 0, frequency: Self.shatterFrequency, damping: 0.5, dt: dt)
        turnGoal += dt * speed * 0.012 * sounding
        turn.step(toward: turnGoal, frequency: 2.8, damping: 0.75, dt: dt)
        // The dive glides in slowly, most of it in the build's last stretch, and
        // springs back past rest when the build lets go.
        let depth = tension * tension * tension
        let rising = depth > dive.position
        dive.step(toward: depth, frequency: rising ? 0.4 : 0.9, damping: rising ? 1 : 0.5, dt: dt)
        let edge = SIMD2<Float>(1, 0) - SIMD2(cos(theta.position), sin(theta.position)) * radius.position / 2
        focus += (edge - focus) * BeatDetector.rate(dt, 0.5)

        glint *= expf(-dt / 0.04)
        traps += dt * speed * (0.25 + 0.6 * latest.high)
        hue += dt * speed * 0.006 * (0.3 + sounding)
        wave.age += dt
        // A steady groove swells the glow on the beat, never a flash.
        let phase = latest.beats - latest.beats.rounded(.down)
        let steady = BeatDetector.smoothstep(0.3, 0.7, latest.confidence) * (latest.tempo > 0 ? 1 : 0)
        follow(&beat, steady * expf(-phase * 5), attack: 0.03, release: 0.12)
    }

    /// How far out the shape sits as it stands, kick included: the size of
    /// its fixed point's multiplier, under 1 inside the cardioid.
    var rho: Float { max(0.5, radius.position + shatter.position) }

    /// c for the shape as it stands.
    var c: SIMD2<Float> { Self.c(theta: theta.position, rho: rho) }

    /// How deep the dive has gone, as a magnification (below 1 as it springs back).
    var zoom: Float { powf(Self.maximumZoom, dive.position) }

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
