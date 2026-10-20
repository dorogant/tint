import Foundation
import simd

/// Bloom: an endless, slow zoom into a Julia set, toward the junction where its
/// arms meet, that the music steers. Its outline glows as thin filaments in the
/// cover's colours on a dark ground, and light pools in the bulbs between the
/// arms. Nothing jumps or shakes: the music sets how fast the zoom goes, where
/// on the screen it heads, and which set it heads into.
///
/// | Music                              | Fractal                                                          |
/// |------------------------------------|------------------------------------------------------------------|
/// | Harmony (pitch class)              | the shape, chosen at each new section: each pitch class has its own, from two arms to seven |
/// | Loudness                           | the zoom's pace                                                  |
/// | Bass envelope                      | a slow breath: the bulbs swell and the channels between them narrow |
/// | Kick                               | a small push forward in the zoom                                 |
/// | Snare, hat                         | glints in the outer filaments                                    |
/// | Mids envelope (vocals, leads)      | light pooling in the bulbs                                       |
/// | Highs envelope and brightness      | finer filaments, deeper detail, and a lean of the zoom's centre  |
/// | Build, then drop                   | the zoom quickens, then eases, with one wave of light from its centre |
/// | Sections (a drop, every 32 beats)  | the next shape dissolves in, and the zoom's centre drifts elsewhere |
/// | Beat phase (a steady groove)       | a faint swell of the glow on each beat                           |
///
/// Hits change the pace, never the brightness, so nothing flashes. In silence
/// the zoom all but stops.
struct BloomRig {
    /// One shape per pitch class, C first: the p/q bulb of the Mandelbrot set it
    /// sits in, so q arms meet at its junction. Neighbouring pitch classes have
    /// different arm counts, so a new section reads as a new shape.
    static let shapes: [(p: Int, q: Int)] = [
        (1, 3), (2, 5), (1, 4), (1, 2), (3, 5), (2, 3), (1, 5), (3, 4), (4, 5), (1, 6), (2, 7), (5, 6),
    ]
    /// How far into its bulb a shape sits at rest, in units of 1/q²: the bulb
    /// spans about 0…2, its centre (the fattest bulbs) near 1.
    static let restingDepth: Float = 1.2
    /// How much further in the bass breathes it.
    static let breath: Float = 0.25
    /// The plane per screen half-height at the start of each repeat of the zoom.
    static let span: Float = 0.6
    /// The zoom's pace in e-folds a second: in silence, cruising with the music
    /// (more with loudness), and how much a full build adds.
    static let idlePace: Float = 0.001
    static let cruisingPace: Float = 0.045
    static let buildPace: Float = 0.15
    /// Seconds a new shape takes to dissolve in.
    static let dissolve: Float = 4

    /// A shape being zoomed into, and how far into its current repeat the zoom is (0…1).
    struct Layer {
        let index: Int
        private(set) var shape: BloomShape
        private(set) var phase: Float = 0

        init(index: Int, depth: Float) {
            self.index = index
            shape = BloomShape(p: BloomRig.shapes[index].p, q: BloomRig.shapes[index].q, depth: depth)
        }

        /// `efolds` of zoom further in, with the shape breathed to `depth`.
        mutating func advance(by efolds: Float, depth: Float) {
            if abs(depth - shape.depth) > 0.0005 { shape = BloomShape(p: shape.p, q: shape.q, depth: depth) }
            phase += efolds / shape.period
            phase -= phase.rounded(.down)
        }
    }

    private(set) var layer = Layer(index: 0, depth: restingDepth)
    /// The shape dissolving in, and how far (0…1).
    private(set) var incoming: Layer?
    private(set) var blend: Float = 0
    /// The zoom's pace (e-folds a second), and the kicks' extra push on top.
    private(set) var pace: Float = idlePace
    private(set) var surge: Float = 0
    /// Where the zoom heads, in screen units (y runs −1…1, x the same scaled by
    /// the aspect ratio), gliding toward a point on a small circle round the middle.
    private var focusX = Spring(), focusY = Spring()
    private var heading: Float = 0.6
    private var sinceChange: Float = 0
    private var beatsAtChange: Float = 0
    /// Smoothed layers, at display rate.
    private(set) var bass: Float = 0
    private(set) var energy: Float = 0
    private(set) var heart: Float = 0
    private(set) var detail: Float = 0
    private(set) var tonality: Float = 0
    private(set) var tension: Float = 0
    /// Decaying after each hat or snare.
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
    private var latest = BeatDetector.Pulse()
    private var layers = MusicLayers()

    var focus: SIMD2<Float> { SIMD2(focusX.position, focusY.position) }

    /// One analysis frame: hits land here, once each.
    mutating func receive(_ pulse: BeatDetector.Pulse, layers: MusicLayers, configuration: BackgroundConfiguration) {
        latest = pulse
        self.layers = layers
        let react = configuration.reactivity
        if pulse.kick > 0 { surge += 0.03 * min(1.4, pulse.kick * configuration.punch * react) }
        if pulse.hat > 0 { glint = max(glint, min(1.2, pulse.hat * react)) }
        if pulse.snare > 0 { glint = max(glint, min(1, 0.6 * pulse.snare * react)) }
        if layers.drop > 0 {
            let strength = min(1, layers.drop * react)
            wave = (0, max(strength, wave.age < 1 ? wave.strength : 0))
            changeSection()
        }
    }

    /// A new section: the zoom heads elsewhere and, unless one is already
    /// dissolving in, the shape the harmony asks for (or the next one) comes in.
    private mutating func changeSection() {
        heading += 2.39996
        sinceChange = 0
        beatsAtChange = latest.beats
        guard incoming == nil else { return }
        let asked = Int(layers.pitchClass.rounded()) % 12
        let next = tonality > 0.5 && asked != layer.index ? asked : (layer.index + 5) % 12
        incoming = Layer(index: next, depth: layer.shape.depth)
        blend = 0
    }

    /// Moves the fractal on by `dt` seconds of display time.
    mutating func step(by dt: Float, configuration: BackgroundConfiguration) {
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

        // The pace eases in and out over seconds; a build quickens it most at its end.
        let goal = Self.idlePace + sounding * (Self.cruisingPace * (0.5 + 0.8 * min(1, energy * react))
                                               + Self.buildPace * tension * tension * tension)
        follow(&pace, goal, attack: 1.2, release: 1.5)
        surge *= expf(-dt / 0.3)
        let efolds = (pace + surge) * speed * dt
        let depth = Self.restingDepth + Self.breath * bass
        layer.advance(by: efolds, depth: depth)
        if var next = incoming {
            next.advance(by: efolds, depth: depth)
            blend += dt / Self.dissolve
            if blend >= 1 {
                layer = next
                incoming = nil
                blend = 0
            } else {
                incoming = next
            }
        }

        // A new section every 32 beats of a steady groove, or 40 s without one,
        // never sooner than 16 s, never mid-build or in silence.
        sinceChange += dt
        let grooving = latest.tempo > 0 && latest.confidence > 0.3
        if sounding > 0.5, sinceChange > 16, tension < 0.25,
           grooving ? latest.beats - beatsAtChange >= 32 : sinceChange > 40 {
            changeSection()
        }
        // The highs lean the centre right and the vocals up, a little, slowly.
        let round = SIMD2(cos(heading), sin(heading)) * 0.28 * sounding
        let lean = SIMD2(0.15 * (detail - 0.5), 0.12 * (heart - 0.3)) * sounding
        focusX.step(toward: round.x + lean.x, frequency: 0.05, damping: 1, dt: dt)
        focusY.step(toward: round.y + lean.y, frequency: 0.05, damping: 1, dt: dt)

        glint *= expf(-dt / 0.04)
        traps += dt * speed * (0.25 + 0.6 * latest.high)
        hue += dt * speed * 0.006 * (0.3 + sounding)
        wave.age += dt
        // A steady groove swells the glow on the beat, never a flash.
        let phase = latest.beats - latest.beats.rounded(.down)
        let steady = BeatDetector.smoothstep(0.3, 0.7, latest.confidence) * (latest.tempo > 0 ? 1 : 0)
        follow(&beat, steady * expf(-phase * 5), attack: 0.03, release: 0.12)
    }
}

/// One of Bloom's shapes: c in the p/q bulb of the Mandelbrot set, where the
/// Julia set's fixed point α is repelling and q arms of the set meet at it. α's
/// multiplier λ = ρe^{2πip/q} turns a whole number of times over q steps, so
/// near α the set repeats itself, unturned, every ρ^q times closer: a zoom
/// toward α can go on forever while only ever drawing one repeat of it.
struct BloomShape {
    let p: Int, q: Int
    /// How far into the bulb, in units of 1/q²: ρ = 1 + depth/q².
    let depth: Float
    let lambda: SIMD2<Float>
    let c: SIMD2<Float>
    let alpha: SIMD2<Float>
    /// e-folds of zoom per repeat: q log ρ.
    let period: Float
    /// The zoom's linear coordinate w carried onto the set (its Poincaré
    /// function at α): a series out to `reach`, and beyond it, each factor of ρ
    /// further out one more step of z ← z² + c. `series` holds its first eight
    /// coefficients, as complex pairs.
    let reach: Float
    let series: SIMD16<Float>
    /// A point of the attracting q-cycle the bulbs' orbits settle onto, the log
    /// of how much each pass round it shrinks them, and how close counts as settled.
    let cycle: SIMD2<Float>
    let contraction: Float
    let settling: Float
    /// Straightens the passes near the cycle so each shrinks orbits evenly: e + b·e²
    /// for an orbit e from the cycle point (the start of its Koenigs coordinate).
    let straightening: SIMD2<Float>

    init(p: Int, q: Int, depth: Float) {
        self.p = p
        self.q = q
        self.depth = depth
        let rho = 1 + Double(depth) / Double(q * q)
        let angle = 2 * Double.pi * Double(p) / Double(q)
        let l = (re: rho * cos(angle), im: rho * sin(angle))
        // c = λ/2 − λ²/4, whose fixed point α = λ/2 has multiplier λ.
        let c = (re: l.re / 2 - (l.re * l.re - l.im * l.im) / 4, im: l.im / 2 - l.re * l.im / 2)
        lambda = SIMD2(Float(l.re), Float(l.im))
        self.c = SIMD2(Float(c.re), Float(c.im))
        alpha = lambda / 2
        period = Float(Double(q) * log(rho))
        // ψ(λw) = ψ(w)(λ + ψ(w)) term by term, in δ = z − α.
        var re = SIMD16<Double>(), im = SIMD16<Double>()
        re[1] = 1
        var power = l
        for k in 2...9 {
            power = (power.re * l.re - power.im * l.im, power.re * l.im + power.im * l.re)
            var sum = (re: 0.0, im: 0.0)
            for i in 1..<k {
                sum.re += re[i] * re[k - i] - im[i] * im[k - i]
                sum.im += re[i] * im[k - i] + im[i] * re[k - i]
            }
            let over = (re: power.re - l.re, im: power.im - l.im), size = over.re * over.re + over.im * over.im
            re[k] = (sum.re * over.re + sum.im * over.im) / size
            im[k] = (sum.im * over.re - sum.re * over.im) / size
        }
        var series = SIMD16<Float>()
        for k in 1...8 { series[2 * k - 2] = Float(re[k]); series[2 * k - 1] = Float(im[k]) }
        self.series = series
        // Out to where the first term left out moves the picture a fifth of a pixel at the screen's edge.
        reach = Float(pow(1.5e-4 / (re[9] * re[9] + im[9] * im[9]).squareRoot(), 1.0 / 8))
        // The critical orbit falls onto the attracting cycle; a whole number of
        // turns round it always lands on the same point of it.
        var z = (re: 0.0, im: 0.0)
        for _ in 0..<(64 * q) { z = (z.re * z.re - z.im * z.im + c.re, 2 * z.re * z.im + c.im) }
        cycle = SIMD2(Float(z.re), Float(z.im))
        // A pass round the cycle, e ↦ m·e + A·e² near it: m and 2A are its first two derivatives.
        var multiplier = (re: 1.0, im: 0.0), bend = (re: 0.0, im: 0.0)
        for _ in 0..<q {
            bend = (2 * (multiplier.re * multiplier.re - multiplier.im * multiplier.im + z.re * bend.re - z.im * bend.im),
                    2 * (2 * multiplier.re * multiplier.im + z.re * bend.im + z.im * bend.re))
            multiplier = (2 * (multiplier.re * z.re - multiplier.im * z.im), 2 * (multiplier.re * z.im + multiplier.im * z.re))
            z = (z.re * z.re - z.im * z.im + c.re, 2 * z.re * z.im + c.im)
        }
        // b = A / (m − m²) makes e + b·e² shrink by exactly m each pass, to second order.
        let over = (re: multiplier.re - (multiplier.re * multiplier.re - multiplier.im * multiplier.im),
                    im: multiplier.im - 2 * multiplier.re * multiplier.im)
        let size = max(1e-12, over.re * over.re + over.im * over.im)
        straightening = SIMD2(Float((bend.re / 2 * over.re + bend.im / 2 * over.im) / size),
                              Float((bend.im / 2 * over.re - bend.re / 2 * over.im) / size))
        contraction = Float(max(0.05, -0.5 * log(max(1e-12, multiplier.re * multiplier.re + multiplier.im * multiplier.im))))
        // A thirtieth of the way to the cycle's next point: close enough, straightened, that each pass shrinks orbits evenly.
        let next = SIMD2(Float(z.re * z.re - z.im * z.im + c.re), Float(2 * z.re * z.im + c.im))
        settling = simd_distance(next, cycle) / 30
    }
}
