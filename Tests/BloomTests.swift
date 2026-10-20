import AppKit
import ImageIO
import MetalKit
import UniformTypeIdentifiers

/// A song for Bloom written straight as analysis layers, so it can carry what
/// the analyzer reports once it hears harmony, builds and drops: chords, a beat
/// coming in, hats, snares, a vocal swell, a long build and its drop.
enum BloomSong {
    struct Moment {
        var pitch: Float = 0
        var tonality: Float = 0
        var kick: Bool = false
        var snare: Bool = false
        var hat: Bool = false
        var vocal: Float = 0
        var build: Float = 0
        var drop: Float = 0
        var loudness: Float = 0
        var brightness: Float = 0.3
        var tempo: Float = 0
    }

    /// Ten seconds at 30 frames a second. One bar is two seconds at 120 BPM.
    static let seconds: Float = 10
    static let dropTime: Float = 9.5

    static func moment(at t: Float, frame: Int) -> Moment {
        var m = Moment()
        // C, A minor, F, G, then C again on the drop: the root glides over a sixth of a second.
        let roots: [Float] = [0, 9, 5, 7, 0]
        let bar = min(roots.count - 1, Int(t / 2))
        let into = t - Float(bar) * 2
        let previous = bar > 0 ? roots[bar - 1] : roots[0]
        var step = roots[bar] - previous
        step -= (step / 12).rounded() * 12
        m.pitch = previous + step * min(1, into / 0.17)
        m.tonality = 0.85
        let beat = 0.5 as Float
        // A hit on the one frame each period starts on.
        func on(_ period: Float, offset: Float = 0) -> Bool {
            let since = frame - Int((offset * 30).rounded())
            return since >= 0 && since % Int((period * 30).rounded()) == 0
        }
        let roll = t > 7.5 && t < dropTime
        m.kick = t >= 2 && !roll && on(beat) || t >= dropTime && on(beat, offset: dropTime)
        m.hat = t >= 3 && !roll && on(beat / 2, offset: 0.25)
        // Snares on two and four, then a roll that doubles up into the drop.
        m.snare = t >= 4 && !roll && on(1, offset: 0.5) || roll && on(t > 8.7 ? 0.125 : 0.25, offset: 7.5)
        m.vocal = t >= 4.5 && t < 7.5 ? sinf((t - 4.5) / 3 * .pi) * 0.85 : 0
        m.build = t >= 1.5 && t < dropTime ? min(1, (t - 1.5) / 8) : 0
        m.drop = abs(t - dropTime) < 0.5 / 30 ? 1 : 0
        m.loudness = t < 2 ? 0.32 : (roll ? 0.42 + 0.1 * (t - 7.5) : (t >= dropTime ? 0.62 : 0.5))
        m.brightness = 0.25 + 0.5 * m.build + (t >= dropTime ? 0.3 : 0)
        m.tempo = t >= 2.5 ? 120 : 0
        return m
    }

    static func frames() -> [SpectrumFrame] {
        (0..<Int(seconds * 30)).map { i in
            let t = Float(i) / 30
            return frame(moment(at: t, frame: i), time: t)
        }
    }

    /// One analysis frame for a moment: the envelopes follow the hits as the analyzer's do.
    static func frame(_ m: Moment, time t: Float) -> SpectrumFrame {
        var layers = MusicLayers()
        let sinceKick = (t - 2).truncatingRemainder(dividingBy: 0.5)
        layers.bass = m.tempo > 0 || t >= 2 ? (m.loudness > 0.45 ? 0.75 * expf(-sinceKick / 0.18) + 0.15 : 0.1) : 0.08
        layers.lowMid = 0.25
        layers.mid = 0.15 + m.vocal * 0.7
        layers.high = t >= 3 ? 0.35 + 0.3 * m.build : 0.05
        layers.kick = m.kick ? 0.9 : 0
        layers.snare = m.snare ? 0.8 : 0
        layers.hat = m.hat ? 0.6 : 0
        layers.tempo = m.tempo
        layers.beats = m.tempo > 0 ? (t - 2) * 2 : 0
        layers.confidence = m.tempo > 0 ? min(1, (t - 2.5) * 0.8) : 0
        layers.pitchClass = m.pitch < 0 ? m.pitch + 12 : m.pitch
        layers.tonality = m.tonality
        layers.brightness = m.brightness
        layers.build = m.build
        layers.drop = m.drop
        let bands = [Float](repeating: m.loudness, count: 48)
        return SpectrumFrame(bands: bands, levels: bands, rms: m.loudness * 0.3, layers: layers)
    }

    /// Steady analysis with no hits: `pitch` held at `tonality`, at a given loudness.
    static func held(pitch: Float, tonality: Float, loudness: Float = 0.4, mid: Float = 0.3, seconds: Float) -> [SpectrumFrame] {
        var layers = MusicLayers()
        layers.pitchClass = pitch
        layers.tonality = tonality
        layers.mid = mid
        layers.bass = 0.2
        let bands = [Float](repeating: loudness, count: 48)
        return Array(repeating: SpectrumFrame(bands: bands, levels: bands, rms: loudness * 0.3, layers: layers), count: Int(seconds * 30))
    }
}

/// A whole song in sections, written as analysis layers like `BloomSong`, so
/// Bloom has sections to change shape at: a pad intro, a verse, an
/// eight-second build ending in a snare roll, the drop into a chorus, a
/// breakdown and a last chorus. 120 BPM, one chord a bar (C, A minor, F, G).
enum BloomLongSong {
    static let seconds: Float = 42
    static let dropTime: Float = 20
    static let sections: [(start: Float, name: String)] = [(0, "intro"), (4, "verse"), (12, "build"), (20, "chorus"),
                                                           (30, "breakdown"), (34, "chorus")]

    static func section(at t: Float) -> String { sections.last { $0.start <= t }!.name }

    static func moment(at t: Float, frame: Int) -> BloomSong.Moment {
        var m = BloomSong.Moment()
        let name = section(at: t)
        let roots: [Float] = [0, 9, 5, 7]
        let bar = Int(t / 2)
        let previous = roots[(bar + 3) % 4]
        var step = roots[bar % 4] - previous
        step -= (step / 12).rounded() * 12
        m.pitch = bar == 0 ? roots[0] : previous + step * min(1, (t - Float(bar) * 2) / 0.17)
        m.tonality = name == "build" ? 0.6 : 0.85
        func on(_ period: Float, offset: Float = 0) -> Bool {
            let since = frame - Int((offset * 30).rounded())
            return since >= 0 && since % Int((period * 30).rounded()) == 0
        }
        let drums = name == "verse" || name == "chorus" || name == "build"
        let roll = name == "build" && t >= 16
        m.kick = drums && !roll && on(0.5)
        m.hat = drums && !roll && on(0.25, offset: 0.25)
        m.snare = drums && !roll && on(1, offset: 0.5) || roll && on(t > 18.5 ? 0.125 : 0.25, offset: 16)
        for (start, end) in [(6, 11), (22, 29), (35, 41)] as [(Float, Float)] where t >= start && t < end {
            m.vocal = sinf((t - start) / (end - start) * .pi) * 0.85
        }
        m.build = name == "build" ? min(1, (t - 12) / 8) : 0
        m.drop = abs(t - dropTime) < 0.5 / 30 ? 1 : 0
        switch name {
        case "intro": m.loudness = 0.3
        case "verse": m.loudness = 0.5
        case "build": m.loudness = 0.45 + 0.02 * (t - 12)
        case "breakdown": m.loudness = 0.26
        default: m.loudness = 0.62
        }
        m.brightness = 0.25 + 0.5 * m.build + (name == "chorus" ? 0.3 : 0)
        m.tempo = drums && t >= 4.5 ? 120 : 0
        return m
    }

    static func frames() -> [SpectrumFrame] {
        var lastKick: Float = -10
        var locked: Float?
        return (0..<Int(seconds * 30)).map { i in
            let t = Float(i) / 30
            let m = moment(at: t, frame: i)
            if m.kick { lastKick = t }
            if m.tempo > 0, locked == nil { locked = t }
            if m.tempo == 0 { locked = nil }
            var layers = MusicLayers()
            layers.bass = m.loudness > 0.45 ? 0.75 * expf(-(t - lastKick) / 0.18) + 0.15 : 0.1
            layers.lowMid = 0.25
            layers.mid = 0.15 + m.vocal * 0.7
            layers.high = m.kick || m.hat || t - lastKick < 1 ? 0.35 + 0.3 * m.build : 0.05
            layers.kick = m.kick ? 0.9 : 0
            layers.snare = m.snare ? 0.8 : 0
            layers.hat = m.hat ? 0.6 : 0
            layers.tempo = m.tempo
            layers.beats = (t - 4) * 2
            layers.confidence = locked.map { min(1, (t - $0) * 0.8) } ?? 0
            layers.pitchClass = m.pitch < 0 ? m.pitch + 12 : m.pitch
            layers.tonality = m.tonality
            layers.brightness = m.brightness
            layers.build = m.build
            layers.drop = m.drop
            let bands = [Float](repeating: m.loudness, count: 48)
            return SpectrumFrame(bands: bands, levels: bands, rms: m.loudness * 0.3, layers: layers)
        }
    }
}

extension BackgroundTests {
    // MARK: - Bloom

    static let bloomOutput = ProcessInfo.processInfo.environment["FLOE_BLOOM_RENDERS"].map { URL(fileURLWithPath: $0) }

    /// Plays analysis frames at 30 Hz into a 60 Hz display; `each` sees a render
    /// of each analysis frame's second display frame.
    static func playBloom(_ animator: inout BackgroundAnimator, _ frames: [SpectrumFrame], renderer: OffscreenRenderer,
                          each: (BackgroundAnimator, RenderedFrame, Int) -> Void = { _, _, _ in }) {
        for (i, frame) in frames.enumerated() {
            animator.receive(frame)
            animator.step(by: 1 / 60)
            animator.step(by: 1 / 60)
            each(animator, renderer.render(animator), i)
        }
    }

    /// Analysis frames holding `pitch`, with a drop a second in, so the rig takes
    /// that pitch class's shape (C is the shape it starts on, so it needs none).
    static func showing(_ pitch: Int, mid: Float = 0.3, seconds: Float) -> [SpectrumFrame] {
        var frames = BloomSong.held(pitch: Float(pitch), tonality: 1, mid: mid, seconds: seconds)
        if pitch != 0 { frames[30].layers.drop = 1 }
        return frames
    }

    static func bloomChecks(device: MTLDevice) {
        let renderer: OffscreenRenderer
        do { renderer = try OffscreenRenderer(device: device, width: 480, height: 300) } catch { fail("cannot build the offscreen renderer: \(error)") }
        let sunset = Covers.palette(Covers.sunset)
        let settings = BackgroundConfiguration(kind: .bloom, colors: sunset)

        // Silence: after settling, the picture all but stops.
        var silent = BackgroundAnimator()
        silent.configure(settings, animated: false)
        var silentFrames: [RenderedFrame] = []
        playBloom(&silent, Array(repeating: .quiet, count: 150), renderer: renderer) { _, frame, i in
            if i >= 90 { silentFrames.append(frame) }
        }
        let silentStep = zip(silentFrames.dropFirst(), silentFrames).map { $0.difference(from: $1) }.max()!
        let silentSecond = silentFrames.last!.difference(from: silentFrames.first!)
        print(String(format: "Bloom in silence: largest change per frame %.5f, over two seconds %.4f, mean luma %.3f",
                     silentStep, silentSecond, silentFrames.last!.meanLuma))
        check(silentStep < 0.0015 && silentSecond < 0.01, "Bloom must be still in silence (\(silentStep) a frame, \(silentSecond) over 2 s)")
        check(silentFrames.last!.meanLuma > 0.01, "Bloom in silence must stay visible, just dim")

        // The zoom is endless: where a repeat ends and the next begins, the
        // picture changes no more than between any two frames.
        var music = BackgroundAnimator()
        music.configure(BackgroundConfiguration(kind: .bloom, colors: sunset, speed: 2), animated: false)
        var steps: [Float] = [], wraps: [Int] = []
        var previous: RenderedFrame?, phase: Float = 0
        playBloom(&music, BloomSong.held(pitch: 0, tonality: 0, loudness: 0.6, seconds: 14), renderer: renderer) { animator, frame, i in
            if let previous { steps.append(frame.difference(from: previous)) }
            if animator.bloom.layer.phase < phase { wraps.append(steps.count - 1) }
            phase = animator.bloom.layer.phase
            previous = frame
        }
        let typical = steps.suffix(200).sorted()[100]
        let worstWrap = wraps.map { steps[$0] }.max() ?? 0
        print(String(format: "Bloom zoom: %d repeats in 14 s, change across a repeat's end %.5f, typical frame %.5f",
                     wraps.count, worstWrap, typical))
        check(!wraps.isEmpty, "the zoom must pass from one repeat into the next")
        check(worstWrap < 2.5 * typical + 0.0005, "the zoom must run seamlessly from one repeat into the next (\(worstWrap) vs \(typical))")
        check(typical > silentStep, "with music the zoom must move (\(typical) a frame)")

        // A kick pushes the zoom on, not the brightness: against a twin that never heard it.
        let held = BloomSong.held(pitch: 0, tonality: 0, seconds: 3)
        var hit = held
        hit[45].layers.kick = 1
        var kicked = BackgroundAnimator(), twin = BackgroundAnimator()
        kicked.configure(settings, animated: false)
        twin.configure(settings, animated: false)
        var twinFrames: [RenderedFrame] = []
        playBloom(&twin, held, renderer: renderer) { _, frame, _ in twinFrames.append(frame) }
        var apart: [Float] = [], lumaRatio: [Float] = []
        playBloom(&kicked, hit, renderer: renderer) { _, frame, i in
            apart.append(frame.difference(from: twinFrames[i]))
            if i >= 45 { lumaRatio.append(frame.meanLuma / max(0.001, twinFrames[i].meanLuma)) }
        }
        print(String(format: "Bloom kick: ahead of the twin by %.4f a second on; mean luma within %.1f%%…%.1f%% of it",
                     apart[75], (lumaRatio.min()! - 1) * 100, (lumaRatio.max()! - 1) * 100))
        check(apart[..<45].allSatisfy { $0 == 0 }, "the twins must match before the kick")
        check(apart[75] > 0, "a kick must push the zoom on")
        check(lumaRatio.allSatisfy { abs($0 - 1) < 0.1 }, "a kick must not change the brightness (\(lumaRatio.min()!)…\(lumaRatio.max()!))")

        // Harmony picks the next shape: G after a new section draws a different set from C.
        var c = BackgroundAnimator(), g = BackgroundAnimator()
        c.configure(settings, animated: false)
        g.configure(settings, animated: false)
        var cFrame: RenderedFrame?, gFrame: RenderedFrame?
        playBloom(&c, showing(0, seconds: 6), renderer: renderer) { _, frame, _ in cFrame = frame }
        playBloom(&g, showing(7, seconds: 6), renderer: renderer) { _, frame, _ in gFrame = frame }
        check(cFrame!.difference(from: gFrame!) > 0.01, "C and G must play different shapes")

        // The bulbs' light is soft, with no lines in it.
        if let large = try? OffscreenRenderer(device: device, width: 640, height: 400) {
            for pitch in [0, 3, 9] {
                let (frame, heart) = heldHeart(pitch: pitch, mid: 0.8, seconds: 6, renderer: large, settings: settings)
                let (lines, share) = heartLines(frame, heart: heart)
                print(String(format: "Bloom bulbs (pitch class %d, vocal): fine structure %.4f over %.0f%% of the frame", pitch, lines, share * 100))
                check(share > 0.03 && lines < 0.004, "the bulbs must glow without lines (\(lines) over \(share) of the frame)")
            }
        }

        // Photosensitivity and legibility through the song and through a frantic
        // groove at the brightest settings: no region flashes more than three
        // times a second, and text stays readable.
        let frantic = SyntheticTrack(kicksPerSecond: 8, kick: 0.95, bass: 0.3, pad: 0.25, hats: 0.12, snare: 0.4, kickOffset: 1)
        var franticFrames = SyntheticTrack.frames([(SyntheticTrack(pad: 0.08), 1), (frantic, 4)])
        for i in stride(from: 45, to: franticFrames.count, by: 20) { franticFrames[i].layers.drop = 1 }
        let brightest = BackgroundConfiguration(kind: .bloom, colors: [RGB(r: 1, g: 0.95, b: 0.6), RGB(r: 0.9, g: 1, b: 0.9)],
                                                reactivity: 2, speed: 2, glow: 2, punch: 2, vividness: 1.5)
        for (name, frames, configuration) in [("song, defaults", BloomSong.frames(), settings), ("frantic, brightest", franticFrames, brightest),
                                              ("frantic, defaults", franticFrames, settings)] {
            var animator = BackgroundAnimator()
            animator.configure(configuration, animated: false)
            var cells: [[Float]] = Array(repeating: [], count: 17)
            var brightestLuma: Float = 0, meanest: Float = 0
            playBloom(&animator, frames, renderer: renderer) { _, frame, i in
                guard i >= 15 else { return }
                let grid = frame.relativeLuminance(columns: 4, rows: 4)
                for (c, value) in grid.enumerated() { cells[c].append(value) }
                cells[16].append(grid.reduce(0, +) / 16)
                brightestLuma = max(brightestLuma, frame.maxLuma)
                meanest = max(meanest, frame.meanLuma)
            }
            let worst = cells.map { mostFlashesPerSecond(transitions($0)) }.max()!
            let whole = mostFlashesPerSecond(transitions(cells[16]))
            print(String(format: "Bloom %@: at most %d WCAG flashes a second over the frame, %d in any region; peak luma %.2f, mean at most %.3f",
                         name, whole, worst, brightestLuma, meanest))
            check(worst <= 3 && whole == 0, "\(name): Bloom must never flash (\(whole) a second over the frame, \(worst) in a region)")
            // As for Fluid: the presets' looks stay under 0.2, the brightest settings on a pale cover under 0.32.
            let darkEnough: Float = configuration == brightest ? 0.32 : 0.2
            check(brightestLuma <= legibleLuma && meanest < darkEnough, "\(name): Bloom must stay dark enough for text (peak \(brightestLuma), mean \(meanest))")
        }

        // The window-sized drawable renders like the small one.
        let size = BackgroundRenderer.drawableSize(points: CGSize(width: 1440, height: 900), scale: 2, kind: .bloom)
        check(size.width * size.height <= 1_320_000 && size.width < 2880, "Bloom must draw at reduced resolution (\(size))")
        if let large = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) {
            let frame = large.render(c)
            check(frame.meanLuma > 0.01 && frame.maxLuma <= legibleLuma, "the window-sized Bloom must render (\(frame.meanLuma))")
        }
    }

    /// What plays what, frame by frame on the rig alone, as the app steps it
    /// (analysis at 30 Hz, display at 60).
    static func bloomMappingChecks() {
        let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset))
        func rig(_ frames: [SpectrumFrame], configuration: BackgroundConfiguration = settings,
                 each: (BloomRig, Int) -> Void = { _, _ in }) -> BloomRig {
            var animator = BackgroundAnimator()
            animator.configure(configuration, animated: false)
            play(&animator, frames) { animator, _, display in each(animator.bloom, display) }
            return animator.bloom
        }

        // Every shape repeats itself unturned, so the zoom never spins, and is placed finely enough.
        for (index, (p, q)) in BloomRig.shapes.enumerated() {
            let shape = BloomShape(p: p, q: q, depth: BloomRig.restingDepth)
            let turn = Float(q) * atan2(shape.lambda.y, shape.lambda.x)
            check(abs(turn - (turn / (2 * .pi)).rounded() * 2 * .pi) < 1e-4, "shape \(index) must repeat unturned (\(turn))")
            check(shape.reach > 0.15 && shape.reach < 0.6, "shape \(index)'s series must reach out a fair way (\(shape.reach))")
            check(shape.settling > 0.001 && shape.contraction > 0.05, "shape \(index) must have bulbs to settle in (\(shape.settling), \(shape.contraction))")
        }

        // Pace: all but still in silence, faster when louder, quickest at a build's end; eased after the drop.
        let silent = rig(Array(repeating: .quiet, count: 120))
        let soft = rig(BloomSong.held(pitch: 0, tonality: 0, loudness: 0.2, seconds: 6))
        let loud = rig(BloomSong.held(pitch: 0, tonality: 0, loudness: 0.6, seconds: 6))
        print(String(format: "Bloom pace: %.3f e-folds a second in silence, %.3f soft, %.3f loud", silent.pace, soft.pace, loud.pace))
        check(silent.pace < 0.004 && soft.pace > silent.pace * 2 && loud.pace > soft.pace * 1.2 && loud.pace < 0.08,
              "the zoom's pace must follow the loudness, gently (\(silent.pace), \(soft.pace), \(loud.pace))")

        var build = BloomSong.held(pitch: 0, tonality: 1, loudness: 0.5, seconds: 16)
        for i in build.indices { build[i].layers.build = i < 240 ? Float(i) / 240 : 0 }
        build[240].layers.drop = 1
        var paces: [Float] = [], waves: [Float] = [], incoming: [Bool] = [], focuses: [SIMD2<Float>] = []
        _ = rig(build) { rig, _ in
            paces.append(rig.pace); waves.append(rig.wave.strength); incoming.append(rig.incoming != nil); focuses.append(rig.focus)
        }
        print(String(format: "Bloom build: pace %.3f halfway, %.3f at its end, %.3f 5 s after the drop", paces[240], paces[479], paces[780]))
        check(paces[240] < 0.08 && paces[479] > 0.11, "a build must quicken the zoom, mostly in its last stretch (\(paces[240]), \(paces[479]))")
        let cruise = rig(BloomSong.held(pitch: 0, tonality: 1, loudness: 0.5, seconds: 8)).pace
        check(paces[780] - cruise < 0.25 * (paces[479] - cruise) && waves[481] > 0.5, "the drop must ease the zoom with a wave (\(paces[780]), wave \(waves[481]))")
        check(incoming[482] && !incoming[482 + 300], "the drop must dissolve to the next shape over a few seconds")

        // Comfort: away from builds nothing crosses the screen faster than a few
        // percent of its height a second, even at the corners, and the zoom's centre only glides.
        var fastest: Float = 0, fastestAnywhere: Float = 0, glide: Float = 0
        var last = SIMD2<Float>.zero, tense = -1000
        _ = rig(BloomSong.frames() + BloomLongSong.frames()) { rig, display in
            let corner = 2.2 * (rig.pace + rig.surge) * settings.speed
            fastestAnywhere = max(fastestAnywhere, corner)
            if rig.tension > 0.3 { tense = display }
            if display - tense > 240 { fastest = max(fastest, corner) }
            if display > 0 { glide = max(glide, simd_distance(rig.focus, last) * 60) }
            last = rig.focus
        }
        print(String(format: "Bloom comfort: corners move at most %.2f half-heights a second outside builds, %.2f in them; the centre at most %.3f",
                     fastest, fastestAnywhere, glide))
        check(fastest < 0.25 && fastestAnywhere < 0.45, "the zoom must stay gentle (\(fastest) outside builds, \(fastestAnywhere) in them)")
        check(glide < 0.08, "the zoom's centre must only glide (\(glide) a second)")

        // Kick: a small push on, none at Bass punch 0.
        var kick = BloomSong.held(pitch: 0, tonality: 1, seconds: 3)
        kick[45].layers.kick = 1
        let pushed = rig(Array(kick.prefix(46))).surge
        var calm = settings
        calm.punch = 0
        let unpushed = rig(Array(kick.prefix(46)), configuration: calm).surge
        check(pushed > 0.015 && pushed < 0.06 && unpushed == 0, "a kick must push the zoom on a little (\(pushed), \(unpushed) at punch 0)")

        // Sections: harmony picks the next shape; the centre heads elsewhere.
        for pitch in [3, 7, 11] {
            let settled = rig(showing(pitch, seconds: 6))
            check(settled.layer.index == pitch && settled.incoming == nil, "pitch class \(pitch) must play its shape after a section change (\(settled.layer.index))")
        }
        check(rig(showing(0, seconds: 6).enumerated().map { var f = $1; if $0 == 30 { f.layers.drop = 1 }; return f }).layer.index != 0,
              "a new section on the same chord must still bring a new shape")
        let moved = simd_distance(focuses[479], focuses.last!)
        check(moved > 0.15, "a new section must move the zoom's centre (\(moved))")
        var changes: [Float] = []
        var index = 0
        _ = rig(BloomLongSong.frames()) { rig, display in
            if rig.layer.index != index { changes.append(Float(display) / 60); index = rig.layer.index }
        }
        print("Bloom long song: new shapes in at " + changes.map { String(format: "%.1f s", $0) }.joined(separator: ", "))
        check(changes.count >= 1 && changes.count <= 3, "the long song must change shape at its sections, not more (\(changes))")

        // Hat: a glint that's gone within 120 ms.
        var hat = BloomSong.held(pitch: 0, tonality: 1, seconds: 2)
        hat[30].layers.hat = 1
        var glints: [Float] = []
        _ = rig(hat) { rig, display in if display >= 60 { glints.append(rig.glint) } }
        check(glints[0] > 0.5 && glints[7] < 0.05, "a hat must glint and fade within 120 ms (\(glints[0]) → \(glints[7]))")

        // Mids: a held vocal lights the bulbs; the drums alone don't.
        var vocal = BloomSong.held(pitch: 0, tonality: 1, seconds: 3)
        for i in vocal.indices { vocal[i].layers.mid = 0.8 }
        let lit = rig(vocal).heart, unlit = rig(BloomSong.held(pitch: 0, tonality: 1, seconds: 3).map { var f = $0; f.layers.mid = 0; return f }).heart
        check(lit > 0.4 && unlit < 0.05, "a vocal must light the bulbs (\(lit) vs \(unlit))")
    }

    // MARK: - Bloom renders

    /// Renders for looking at, when FLOE_BLOOM_RENDERS names a directory: the
    /// twelve pitch-class shapes, the scripted song frame by frame at 30 fps
    /// with a contact sheet of every tenth frame, and the long song.
    static func bloomRenders(device: MTLDevice) {
        guard let directory = bloomOutput else { return }
        let song = directory.appendingPathComponent("song")
        try? FileManager.default.createDirectory(at: song, withIntermediateDirectories: true)
        let colors = Covers.palette(Covers.sunset)
        let settings = BackgroundConfiguration(kind: .bloom, colors: colors)

        // The twelve shapes, each settled in with clear harmony.
        guard let small = try? OffscreenRenderer(device: device, width: 640, height: 400) else { return }
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        var shapes: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for (pitch, name) in names.enumerated() {
            var animator = BackgroundAnimator()
            animator.configure(settings, animated: false)
            var last: RenderedFrame?
            playBloom(&animator, showing(pitch, seconds: 6), renderer: small) { _, frame, _ in last = frame }
            let (p, q) = BloomRig.shapes[pitch]
            shapes.append((last!, "\(name)  \(p)/\(q)", nil))
        }
        strip(shapes, to: directory.appendingPathComponent("shapes.png"), columns: 4, scale: 0.5)

        // One repeat of the zoom, in eight steps: the last frame leads back into the first.
        var zoom: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        var animator = BackgroundAnimator()
        animator.configure(settings, animated: false)
        let loud = BloomSong.held(pitch: 0, tonality: 0, loudness: 0.6, seconds: 1)[0]
        for _ in 0..<60 { animator.advance(by: 1 / 30, frame: loud) }
        for _ in 0..<8 {
            zoom.append((small.render(animator), String(format: "phase %.3f", animator.bloom.layer.phase), nil))
            let start = animator.bloom.layer.phase
            var progress: Float = 0
            while progress < 0.125 {
                animator.advance(by: 1 / 60, frame: loud)
                progress = animator.bloom.layer.phase - start
                progress -= progress.rounded(.down)
                if progress > 0.9 { progress = 0 }
            }
        }
        strip(zoom, to: directory.appendingPathComponent("zoom.png"), columns: 4, scale: 0.5)

        // Each kind of cover at the same moments: before the beat, the vocal swell, just after the drop.
        var palettes: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for (name, cover) in [("sunset", Covers.palette(Covers.sunset)), ("ocean", Covers.palette(Covers.ocean)),
                              ("navy", Covers.palette(Covers.navy)), ("neutral", neutral)] {
            var animator = BackgroundAnimator()
            animator.configure(BackgroundConfiguration(kind: .bloom, colors: cover, neutral: name == "neutral"), animated: false)
            playBloom(&animator, BloomSong.frames().prefix(300).map { $0 }, renderer: small) { _, frame, i in
                if [55, 172, 295].contains(i) { palettes.append((frame, "\(name), \(String(format: "%.1f s", Float(i) / 30))", nil)) }
            }
        }
        strip(palettes, to: directory.appendingPathComponent("palettes.png"), columns: 3, scale: 0.5)

        // At the drawable size of a 1440×900 pt window, as the app draws it, and a crop at 100%.
        let size = BackgroundRenderer.drawableSize(points: CGSize(width: 1440, height: 900), scale: 2, kind: .bloom)
        if let large = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) {
            var animator = BackgroundAnimator()
            animator.configure(settings, animated: false)
            var shot: RenderedFrame?
            playBloom(&animator, BloomSong.frames().prefix(190).map { $0 }, renderer: large) { _, frame, i in
                if i == 189 { shot = frame }
            }
            if let shot {
                save(shot.composited(), to: directory.appendingPathComponent("window.png"))
                save(shot.crop(x: shot.width / 4, y: shot.height / 4, width: shot.width / 2, height: shot.height / 2).composited(),
                     to: directory.appendingPathComponent("window-crop.png"))
            }
        }

        // The song, at 960×600, every frame.
        guard let renderer = try? OffscreenRenderer(device: device, width: 960, height: 600) else { return }
        var player = BackgroundAnimator()
        player.configure(settings, animated: false)
        var sheet: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        let frames = BloomSong.frames()
        playBloom(&player, frames, renderer: renderer) { _, frame, i in
            save(frame.composited(), to: song.appendingPathComponent(String(format: "frame-%03d.png", i)))
            guard i % 10 == 0 else { return }
            let m = BloomSong.moment(at: Float(i) / 30, frame: i)
            var label = String(format: "%.1f s", Float(i) / 30)
            if m.build > 0 { label += String(format: " build %.2f", m.build) }
            if m.vocal > 0.1 { label += " vocal" }
            sheet.append((frame, label, m.kick ? CGColor(red: 1, green: 0.4, blue: 0.3, alpha: 1) : (m.snare ? CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1) : nil)))
        }
        strip(sheet, to: directory.appendingPathComponent("song-sheet.png"), columns: 6, scale: 0.3)
        print("Bloom renders: \(directory.path)/shapes.png, zoom.png, song-sheet.png and song/frame-000…\(frames.count - 1).png")
        bloomHeartRenders(device: device, directory: directory)
        bloomLongSongRenders(device: device, directory: directory)
    }

    /// The last frame of a shape held for `seconds` with the mids at `mid`, and which of its pixels lie in the bulbs.
    static func heldHeart(pitch: Int, mid: Float, seconds: Float, renderer: OffscreenRenderer,
                          settings: BackgroundConfiguration) -> (frame: RenderedFrame, heart: [Bool]) {
        var animator = BackgroundAnimator()
        animator.configure(settings, animated: false)
        var last: RenderedFrame?
        playBloom(&animator, showing(pitch, mid: mid, seconds: seconds), renderer: renderer) { _, frame, _ in last = frame }
        let (width, height) = (last!.width, last!.height)
        return (last!, heartPixels(animator.bloomUniforms(width: Float(width), height: Float(height)), width: width, height: height))
    }

    /// Which pixels of a frame lie in the bulbs (orbits that settle onto the
    /// attracting cycle), from the uniforms the frame was drawn with, iterated
    /// on the CPU the way the shader does.
    static func heartPixels(_ u: BloomUniforms, width: Int, height: Int) -> [Bool] {
        func times(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { SIMD2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x) }
        let s = u.shapes.0
        let aspect = Float(width) / Float(height)
        let lambda = SIMD2(s.counts.x, s.counts.y)
        let c = SIMD2(s.fixed.x, s.fixed.y), alpha = SIMD2(s.fixed.z, s.fixed.w), cycle = SIMD2(s.cycle.x, s.cycle.y)
        let terms = [s.series.0, s.series.1, s.series.2, s.series.3].flatMap { [SIMD2($0.x, $0.y), SIMD2($0.z, $0.w)] }
        let focus = SIMD2(u.size.z, u.size.w)
        let n = Int(u.view.x)
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // As in the shader: the series near α, then out to the set by steps of z ← z² + c.
                let v = SIMD2((2 * (Float(x) + 0.5) / Float(width) - 1) * aspect, 1 - 2 * (Float(y) + 0.5) / Float(height))
                let w = s.zoom.x * (v - focus)
                let placing = min(160, max(0, Int(((logf(max(simd_length(w), 1e-15)) - s.zoom.w) / s.zoom.y).rounded(.up))))
                let turn = -Float(placing) * s.zoom.z
                let inward = expf(-Float(placing) * s.zoom.y) * SIMD2(cosf(turn), sinf(turn))
                let point = times(w, inward)
                var sum = terms[7], slope = SIMD2<Float>.zero
                for k in stride(from: 6, through: 0, by: -1) {
                    slope = times(slope, point) + sum
                    sum = times(sum, point) + terms[k]
                }
                var d = times(point, sum), dz = s.zoom.x * times(sum + times(point, slope), inward)
                var far = false
                for _ in 0..<placing {
                    dz = times(dz, lambda + 2 * d)
                    d = times(d, lambda + d)
                    if simd_length_squared(d) > 1024 { far = true; break }
                }
                if far { continue }
                var z = alpha + d
                var state = 0
                for _ in 0..<n {
                    dz = 2 * times(z, dz)
                    z = times(z, z) + c
                    if simd_length_squared(z) > 1024 { state = 1; break }
                    if simd_distance_squared(z, cycle) < s.cycle.w { state = 2; break }
                }
                // As in the shader: an orbit still going that has stopped stretching is settling slowly.
                mask[y * width + x] = state == 2 || state == 0 && simd_length_squared(dz) < 1e6
            }
        }
        return mask
    }

    /// Fine structure inside the bulbs: the mean absolute difference (0…1)
    /// between each bulb pixel's luma and its 9×9 neighbourhood's mean, over
    /// pixels at least six pixels deep in a bulb. Soft pools and gradients score
    /// near the dither's floor; contour lines score well above it.
    static func heartLines(_ frame: RenderedFrame, heart: [Bool]) -> (lines: Float, share: Float) {
        let w = frame.width, h = frame.height
        var deep = [Bool](repeating: false, count: w * h)
        for y in 6..<(h - 6) {
            for x in 6..<(w - 6) where heart[y * w + x] {
                var all = true
                for dy in stride(from: -6, through: 6, by: 3) where all {
                    for dx in stride(from: -6, through: 6, by: 3) where !heart[(y + dy) * w + x + dx] { all = false; break }
                }
                deep[y * w + x] = all
            }
        }
        var sum: Float = 0, count = 0
        for y in 4..<(h - 4) {
            for x in 4..<(w - 4) where deep[y * w + x] {
                var mean: Float = 0
                for dy in -4...4 { for dx in -4...4 { mean += frame.luma(x + dx, y + dy) } }
                sum += abs(frame.luma(x, y) - mean / 81)
                count += 1
            }
        }
        return (count > 0 ? sum / Float(count) : 0, Float(count) / Float(w * h))
    }

    /// Three shapes' bulbs with and without a vocal, at 100%.
    static func bloomHeartRenders(device: MTLDevice, directory: URL) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 1280, height: 800) else { return }
        let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset))
        var cells: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for pitch in [0, 3, 9] {
            for mid: Float in [0, 0.8] {
                let (frame, heart) = heldHeart(pitch: pitch, mid: mid, seconds: 6, renderer: renderer, settings: settings)
                let (lines, share) = heartLines(frame, heart: heart)
                let (p, q) = BloomRig.shapes[pitch]
                cells.append((frame.crop(x: 320, y: 200, width: 640, height: 400),
                              String(format: "%d/%d, %@, lines %.4f over %.0f%%", p, q, mid > 0 ? "vocal" : "no vocal", lines, share * 100), nil))
            }
        }
        strip(cells, to: directory.appendingPathComponent("heart.png"), columns: 2, scale: 1)
    }

    /// The long song, a frame every half second.
    static func bloomLongSongRenders(device: MTLDevice, directory: URL) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 640, height: 400) else { return }
        var animator = BackgroundAnimator()
        animator.configure(BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset)), animated: false)
        var sheet: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        playBloom(&animator, BloomLongSong.frames(), renderer: renderer) { _, frame, i in
            guard i % 15 == 0 else { return }
            let t = Float(i) / 30
            let m = BloomLongSong.moment(at: t, frame: i)
            var label = String(format: "%.1f s %@", t, BloomLongSong.section(at: t))
            if m.vocal > 0.1 { label += " vocal" }
            sheet.append((frame, label, m.kick ? CGColor(red: 1, green: 0.4, blue: 0.3, alpha: 1) : (m.snare ? CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1) : nil)))
        }
        strip(sheet, to: directory.appendingPathComponent("long-song-sheet.png"), columns: 8, scale: 0.3)
    }

    /// GPU time per Bloom frame at the sizes the app draws, in its costliest
    /// states (mid-dissolve, so two shapes, at full detail; and a seven-arm shape held).
    static func bloomPerformance(device: MTLDevice) {
        var dissolving = BackgroundAnimator()
        dissolving.configure(BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset)), animated: false)
        for frame in BloomSong.frames() + Array(BloomSong.held(pitch: 10, tonality: 1, seconds: 1)) { dissolving.advance(by: 1 / 30, frame: frame) }
        var resting = BackgroundAnimator()
        resting.configure(BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset)), animated: false)
        for frame in showing(10, seconds: 6) { resting.advance(by: 1 / 30, frame: frame) }
        let windows: [(String, CGSize)] = [("1200x750 pt window", CGSize(width: 1200, height: 750)),
                                           ("1440x900 pt window", CGSize(width: 1440, height: 900)),
                                           ("1728x1117 pt full screen", CGSize(width: 1728, height: 1117))]
        for (name, points) in windows {
            let size = BackgroundRenderer.drawableSize(points: points, scale: 2, kind: .bloom)
            guard let renderer = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) else { continue }
            let both = renderer.gpuMilliseconds(dissolving)
            let rest = renderer.gpuMilliseconds(resting)
            print(String(format: "GPU per frame, %@, Bloom (%dx%d): %.2f ms dissolving (%@), %.2f ms on a seven-arm shape, %.1f%% of the GPU at 60 Hz",
                         name, Int(size.width), Int(size.height), both, dissolving.bloom.incoming == nil ? "not" : "yes", rest, max(both, rest) * 6))
        }
    }

    /// Labelled thumbnails in rows, written to `url`.
    static func strip(_ cells: [(frame: RenderedFrame, label: String, mark: CGColor?)], to url: URL, columns: Int, scale: CGFloat) {
        guard let first = cells.first?.frame else { return }
        let cellW = Int(CGFloat(first.width) * scale), cellH = Int(CGFloat(first.height) * scale)
        let gap = 4, caption = 18
        let rows = (cells.count + columns - 1) / columns
        let width = columns * (cellW + gap) + gap, height = rows * (cellH + caption + gap) + gap
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for (n, cell) in cells.enumerated() {
            let x = gap + (n % columns) * (cellW + gap)
            let top = height - gap - (n / columns) * (cellH + caption + gap)
            context.draw(cell.frame.composited(), in: CGRect(x: x, y: top - cellH, width: cellW, height: cellH))
            if let mark = cell.mark {
                context.setFillColor(mark)
                context.fill(CGRect(x: x, y: top - cellH - 5, width: cellW, height: 4))
            }
            let text = NSAttributedString(string: cell.label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1),
            ])
            context.textPosition = CGPoint(x: x + 2, y: top - cellH - caption + 2)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        if let image = context.makeImage() { save(image, to: url) }
    }

    static func save(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
