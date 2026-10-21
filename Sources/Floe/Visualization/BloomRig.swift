import Foundation
import simd

/// Bloom: an endless, slow dive into the Mandelbrot set that the music steers.
/// Each dive sets out from the whole set and spirals down one of its valleys,
/// past seahorses, spirals, fans and branches that keep changing as it goes,
/// to a small copy of the set; that copy is framed just as the whole set was,
/// so the next dive fades in over it and sets out again. It's coloured the
/// classic way, muted to sit behind the text: the cover's colours run in smooth
/// bands by how fast each point escapes, ever finer toward the set, whose
/// outline is drawn as fine lace; the set itself is dark. Nothing jumps or
/// shakes: the music sets how fast the dive goes, which way it leans and which
/// valley the next one takes.
///
/// | Music                              | Fractal                                                          |
/// |------------------------------------|------------------------------------------------------------------|
/// | Harmony (pitch class)              | which way the view leans, and the valley the next dive takes     |
/// | Loudness                           | the dive's pace                                                  |
/// | Bass envelope                      | a slow breath of the light round the set's structure             |
/// | Kick                               | a small push forward in the dive                                 |
/// | Snare, hat                         | glints running along the bands                                   |
/// | Mids envelope (vocals, leads)      | a faint light in the set's bulbs                                 |
/// | Highs envelope and brightness      | a finer outline, and quicker glints                              |
/// | Build, then drop                   | the dive quickens, then eases, with one wave of light from its centre |
/// | Beat phase (a steady groove)       | a faint swell of the light on each beat                          |
///
/// Hits change the pace, never the brightness, so nothing flashes. In silence
/// the dive all but stops.
struct BloomRig {
    /// Where the dives head, each from a point by the copy and its period. The
    /// harmony's pitch class picks among them, so C and G take different valleys.
    static let destinations: [BloomDestination] = [
        (-0.7436423016579, 0.1318265198126, 39), // seahorse valley: seahorses curl into spirals
        (0.3246403553786, 0.0464340732952, 55), // the far side of elephant valley: paisley fans
        (-0.1023215609855, 0.9571603093774, 19), // the dendrite above the top bulb: snowflake arms
        (-0.086506515, 0.650747446, 47), // triple spirals beside the top bulb
        (-0.5569848057422, 0.6352133829160, 20), // the upper bulbs' valley: curled spirals
        (0.2925037532342, 0.0149250689983, 16), // elephant valley: a herd of trunks
        (-1.769877323, 0.055722686, 10), // the branches beside the antenna
        (-0.749357578, 0.107516316, 31), // deeper in seahorse valley: double spirals
    ].map { BloomDestination(near: Complex($0.0, $0.1), period: $0.2) }
    /// The whole set's view, which every dive starts from: its centre and half-height.
    static let home = Complex(-0.6, 0)
    static let span = 1.25
    /// The dive's pace in e-folds a second: in silence, cruising with the music
    /// (more with loudness), and how much a full build adds.
    static let idlePace: Float = 0.001
    static let cruisingPace: Float = 0.045
    static let buildPace: Float = 0.15
    /// How far the harmony leans the view off the dive's line, in screen units.
    static let leanReach: Float = 0.15
    /// How many e-folds before a dive's end the next one starts fading in.
    static let handoff = 1.2
    /// Iterations per pixel. Pixels that haven't escaped or settled onto a
    /// cycle by then are drawn as the set, as classic renderings do.
    static let iterations: Float = 600

    /// The dive under way, and how far down it is (0…1).
    private(set) var destination: Int
    private(set) var progress: Double
    /// The dive fading in over this one's last stretch.
    private(set) var next: Int?
    /// The dive's pace (e-folds a second), and the kicks' extra push on top.
    private(set) var pace: Float = idlePace
    private(set) var surge: Float = 0
    /// Where on the screen the dive heads, in screen units (y runs −1…1, x the
    /// same scaled by the aspect ratio): the palette lies round it and the drop's
    /// wave runs out from it. It glides over to each new dive's.
    private var focusX = Spring(), focusY = Spring()
    /// How far the whole view leans off the dive's line, in screen units: the
    /// harmony steers it a little toward its own side, slower than the eye follows.
    private var leanX = Spring(), leanY = Spring()
    /// Smoothed layers, at display rate.
    private(set) var bass: Float = 0
    private(set) var energy: Float = 0
    private(set) var heart: Float = 0
    private(set) var detail: Float = 0
    private(set) var tonality: Float = 0
    private(set) var tension: Float = 0
    /// Decaying after each hat or snare.
    private(set) var glint: Float = 0
    /// Where along the filaments the glints sit; it moves on with the highs.
    private(set) var sparkle: Float = 0
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

    init(destination: Int = 0, progress: Double = 0) {
        self.destination = destination
        self.progress = progress
        let focus = Self.destinations[destination].focus
        focusX.position = focus.x
        focusY.position = focus.y
    }

    var focus: SIMD2<Float> { SIMD2(focusX.position, focusY.position) - lean }
    var lean: SIMD2<Float> { SIMD2(leanX.position, leanY.position) }

    /// How far the next dive has faded in (0…1).
    var blend: Float {
        guard next != nil else { return 0 }
        let start = Self.handoffStart(destination)
        let x = Float(max(0, min(1, (progress - start) / (1 - start))))
        return x * x * (3 - 2 * x)
    }

    /// How far along the dive into `destination` the next one starts fading in.
    static func handoffStart(_ destination: Int) -> Double { 1 - handoff / destinations[destination].depth }

    /// The next dive: the one the harmony names when it's clear, else three on.
    static func destination(after current: Int, pitchClass: Float, tonality: Float) -> Int {
        let count = destinations.count
        let named = (Int(pitchClass.rounded()) % 12 + 12) % 12 % count
        let next = tonality > 0.5 ? named : (current + 3) % count
        return next == current ? (current + 1) % count : next
    }

    /// The plane under the screen for the dive under way and, while it hands
    /// over, the next one: c = nucleus + b + a·v at screen point v.
    var views: (current: BloomView, incoming: BloomView?) {
        let here = Self.destinations[destination]
        let lean = Complex(Double(lean.x), Double(lean.y))
        let current = here.view(along: here, at: progress, scale: pow(Double(here.period), -progress)).leaning(lean)
        // The next dive starts where this one ends: the whole set, seen as this
        // dive sees the copy it's arriving at, a little further out. Both lean
        // alike, so the copy and the whole set stay one over the other.
        let incoming = next.map { Self.destinations[$0].view(along: here, at: progress - 1, scale: 1).leaning(lean) }
        return (current, incoming)
    }

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
        }
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
        advance(by: Double((pace + surge) * speed * dt))

        let target = Self.destinations[destination].focus
        focusX.step(toward: target.x, frequency: 0.05, damping: 1, dt: dt, maximumSpeed: 0.05)
        focusY.step(toward: target.y, frequency: 0.05, damping: 1, dt: dt, maximumSpeed: 0.05)
        // A clear key leans the view toward the chord's own side of the circle;
        // each chord change sets it gliding off somewhere new. In silence it holds.
        let angle = layers.pitchClass * .pi / 6
        let reach = Self.leanReach * tonality
        let leaning = dt * speed * BeatDetector.smoothstep(0.02, 0.08, latest.energy)
        leanX.step(toward: reach * cos(angle), frequency: 0.04, damping: 1, dt: leaning, maximumSpeed: 0.012)
        leanY.step(toward: reach * sin(angle), frequency: 0.04, damping: 1, dt: leaning, maximumSpeed: 0.012)
        glint *= expf(-dt / 0.04)
        sparkle += dt * speed * (0.25 + 0.6 * latest.high)
        hue += dt * speed * 0.006 * (0.3 + sounding)
        wave.age += dt
        // A steady groove swells the glow on the beat, never a flash.
        let phase = latest.beats - latest.beats.rounded(.down)
        let steady = BeatDetector.smoothstep(0.3, 0.7, latest.confidence) * (latest.tempo > 0 ? 1 : 0)
        follow(&beat, steady * expf(-phase * 5), attack: 0.03, release: 0.12)
    }

    /// `efolds` further down; over the last stretch the next dive is picked and
    /// fades in, and at the copy it takes over.
    private mutating func advance(by efolds: Double) {
        var depth = Self.destinations[destination].depth
        progress += efolds / depth
        if next == nil, progress >= Self.handoffStart(destination) {
            next = Self.destination(after: destination, pitchClass: layers.pitchClass, tonality: tonality)
        }
        while progress >= 1 {
            let past = (progress - 1) * depth
            destination = next ?? Self.destination(after: destination, pitchClass: layers.pitchClass, tonality: tonality)
            next = nil
            depth = Self.destinations[destination].depth
            progress = past / depth
        }
    }
}

/// Where a dive heads: a small copy of the Mandelbrot set, of period `period`,
/// at `nucleus`. The whole set maps onto the copy by c ↦ nucleus + scale·c, so
/// a dive spirals by that map's fractional powers about its fixed point, from
/// the whole set's view to the same view of the copy.
struct BloomDestination {
    let nucleus: Complex
    let period: Int
    let scale: Complex
    var inverseScale: Complex { Complex(1, 0) / scale }
    /// The dive's fixed point: where nucleus + scale·c leaves c where it is.
    let center: Complex
    /// e-folds of zoom from the whole set down to the copy.
    let depth: Double
    /// z ← z² + c from 0 at the nucleus, over one period: the reference each
    /// pixel's orbit is followed against, as its tiny offset from it.
    let orbit: InlineArray<64, SIMD2<Float>>
    /// Where the fixed point sits on the screen, in screen units.
    let focus: SIMD2<Float>

    /// The copy whose nucleus Newton's method finds from `point`.
    init(near point: Complex, period: Int) {
        precondition(period <= 64, "the shader holds orbits of up to 64 steps")
        var c = point
        for _ in 0..<60 {
            var z = Complex(0, 0), dz = Complex(0, 0)
            for _ in 0..<period {
                dz = 2 * z * dz + Complex(1, 0)
                z = z * z + c
            }
            let step = z / dz
            c = c - step
            if step.magnitude < 1e-17 { break }
        }
        nucleus = c
        self.period = period
        // The copy's size and turn, from the orbit's derivatives (after Robert Munafo).
        var z = Complex(0, 0), l = Complex(1, 0), b = Complex(1, 0)
        var orbit = InlineArray<64, SIMD2<Float>>(repeating: .zero)
        for n in 1..<period {
            z = z * z + c
            orbit[n] = SIMD2(Float(z.re), Float(z.im))
            l = 2 * z * l
            b = b + Complex(1, 0) / l
        }
        self.orbit = orbit
        scale = Complex(1, 0) / (b * l * l)
        center = c / (Complex(1, 0) - scale)
        depth = -log(scale.magnitude)
        let focus = (center - BloomRig.home) * (1 / BloomRig.span)
        self.focus = SIMD2(Float(focus.re), Float(focus.im))
    }

    /// The plane under the screen `progress` along `path`'s dive (negative:
    /// further out than its start), measured from this destination's nucleus.
    /// `scale` brings the escape counts there to the whole set's for colouring.
    func view(along path: BloomDestination, at progress: Double, scale colorScale: Double) -> BloomView {
        let zoom = path.scale.power(progress)
        return BloomView(perScreenUnit: zoom * BloomRig.span,
                         offset: path.center - nucleus + zoom * (BloomRig.home - path.center),
                         colorScale: colorScale)
    }
}

/// Bloom's bands: the cover's colours as a loop in OKLCH (lightness, chroma,
/// hue), which the shader runs round. The colours keep their hues, but each
/// takes a set place in lightness, so the loop runs from deep dark up to a
/// bright accent and back, and a chroma vivid enough to read as colour,
/// whatever the cover: the lightest of them becomes the accent, the darkest
/// the deep. A black-and-white cover stays grey.
enum BloomPalette {
    /// Lightness per place round the loop, from its darkest colour.
    static let lightness: InlineArray<5, Float> = [0.17, 0.4, 0.8, 0.58, 0.3]
    /// The least chroma a colour is given, and how much more each gets.
    static let minimumChroma: Float = 0.12
    static let boost: Float = 1.5

    static func loop(_ colors: [SIMD3<Float>], neutral: Bool) -> Palette {
        var lch = InlineArray<5, SIMD3<Float>>(repeating: .zero)
        var order = InlineArray<5, Int>(repeating: 0)
        for i in 0..<5 {
            lch[i] = toLCH(colors[i % colors.count])
            order[i] = i
        }
        // Darkest first, by insertion: no allocations per frame.
        for i in 1..<5 {
            var j = i
            while j > 0 && lch[order[j - 1]].x > lch[order[j]].x {
                (order[j - 1], order[j]) = (order[j], order[j - 1])
                j -= 1
            }
        }
        // Place round the loop for each, from darkest to lightest: deep, the
        // dark side's way down, the mid way up, the mid way down, the accent.
        let places: InlineArray<5, Int> = [0, 4, 1, 3, 2]
        let accentHue = lch[order[4]].z
        var out = InlineArray<5, SIMD4<Float>>(repeating: .zero)
        for rank in 0..<5 {
            var c = lch[order[rank]]
            // A grey has no hue of its own to keep: it takes the accent's.
            if c.y < 0.02 { c.z = accentHue }
            c.y = neutral ? min(c.y, 0.02) : max(minimumChroma, c.y * boost)
            c.x = lightness[places[rank]]
            out[places[rank]] = SIMD4(c.x, inGamut(c), c.z, 0)
        }
        return (out[0], out[1], out[2], out[3], out[4])
    }

    /// The most chroma up to `c`'s that sRGB can show at its lightness and hue.
    static func inGamut(_ c: SIMD3<Float>) -> Float {
        var low: Float = 0, high = c.y
        if fits(SIMD3(c.x, high, c.z)) { return high }
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if fits(SIMD3(c.x, mid, c.z)) { low = mid } else { high = mid }
        }
        return low
    }

    private static func fits(_ c: SIMD3<Float>) -> Bool {
        let rgb = linear(c)
        return rgb.min() >= -0.001 && rgb.max() <= 1.001
    }

    /// Gamma-encoded sRGB to OKLCH (hue in radians).
    static func toLCH(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        func decode(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4) }
        let r = decode(rgb.x), g = decode(rgb.y), b = decode(rgb.z)
        let l = cbrtf(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrtf(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrtf(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lab = SIMD3<Float>(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                               1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                               0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        return SIMD3(lab.x, (lab.y * lab.y + lab.z * lab.z).squareRoot(), atan2f(lab.z, lab.y))
    }

    /// OKLCH to linear sRGB (out of range where sRGB can't show it).
    static func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let a = c.y * cosf(c.z), b = c.y * sinf(c.z)
        let l = c.x + 0.3963377774 * a + 0.2158037573 * b
        let m = c.x - 0.1055613458 * a - 0.0638541728 * b
        let s = c.x - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return SIMD3(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                     -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                     -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }
}

/// The plane under the screen: c = nucleus + offset + perScreenUnit·v.
struct BloomView {
    let perScreenUnit: Complex
    let offset: Complex
    let colorScale: Double

    /// The same plane with screen point v showing what v + `lean` did.
    func leaning(_ lean: Complex) -> BloomView {
        BloomView(perScreenUnit: perScreenUnit, offset: offset + perScreenUnit * lean, colorScale: colorScale)
    }
}

struct Complex: Equatable {
    var re: Double, im: Double
    init(_ re: Double, _ im: Double) { self.re = re; self.im = im }

    var magnitude: Double { (re * re + im * im).squareRoot() }

    static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    static func * (a: Complex, b: Complex) -> Complex { Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    static func * (a: Double, b: Complex) -> Complex { Complex(a * b.re, a * b.im) }
    static func * (a: Complex, b: Double) -> Complex { Complex(a.re * b, a.im * b) }
    static func / (a: Complex, b: Complex) -> Complex {
        let size = b.re * b.re + b.im * b.im
        return Complex((a.re * b.re + a.im * b.im) / size, (a.im * b.re - a.re * b.im) / size)
    }

    /// self^t, turning by t times its angle.
    func power(_ t: Double) -> Complex {
        let size = pow(magnitude, t), angle = atan2(im, re) * t
        return Complex(size * cos(angle), size * sin(angle))
    }
}
