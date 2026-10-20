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
/// the lens has section changes to glide at: a pad intro, a verse, an
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

    /// Plays analysis frames at 30 Hz into a 60 Hz display, rendering every display
    /// frame (the trails need each one); `each` sees the analysis frame's second render.
    static func playBloom(_ animator: inout BackgroundAnimator, _ frames: [SpectrumFrame], renderer: OffscreenRenderer,
                          each: (BackgroundAnimator, RenderedFrame, Int) -> Void = { _, _, _ in }) {
        renderer.forgetTrails()
        for (i, frame) in frames.enumerated() {
            animator.receive(frame)
            animator.step(by: 1 / 60)
            _ = renderer.render(animator)
            animator.step(by: 1 / 60)
            each(animator, renderer.render(animator), i)
        }
    }

    static func bloomChecks(device: MTLDevice) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 480, height: 300) else { fail("cannot build the offscreen renderer") }
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

        // A kick shatters the set and it knits back: against a twin that never heard it.
        let held = BloomSong.held(pitch: 0, tonality: 0, seconds: 4)
        var hit = held
        hit[60].layers.kick = 1
        var kicked = BackgroundAnimator(), twin = BackgroundAnimator()
        kicked.configure(settings, animated: false)
        twin.configure(settings, animated: false)
        var twinFrames: [RenderedFrame] = []
        playBloom(&twin, held, renderer: renderer) { _, frame, _ in twinFrames.append(frame) }
        var apart: [Float] = [], lumaRatio: [Float] = []
        playBloom(&kicked, hit, renderer: renderer) { _, frame, i in
            apart.append(frame.difference(from: twinFrames[i]))
            if i >= 60 { lumaRatio.append(frame.meanLuma / max(0.001, twinFrames[i].meanLuma)) }
        }
        let peak = apart[60...75].max()!, after = apart[60 + 45]
        print(String(format: "Bloom kick: frames differ %.4f at the shatter, %.4f 1.5 s on; mean luma within %.0f%%…%.0f%% of the twin",
                     peak, after, (lumaRatio.min()! - 1) * 100, (lumaRatio.max()! - 1) * 100))
        check(apart[..<60].allSatisfy { $0 == 0 }, "the twins must match before the kick")
        check(peak > 0.008, "a kick must shatter the set (\(peak))")
        check(after < peak * 0.25, "the set must knit back after a kick (\(after) vs \(peak))")
        check(lumaRatio.allSatisfy { abs($0 - 1) < 0.5 }, "a kick changes the shape, not the brightness (\(lumaRatio.min()!)…\(lumaRatio.max()!))")

        // Harmony picks the shape: two pitch classes held must draw different sets.
        var c = BackgroundAnimator(), g = BackgroundAnimator()
        c.configure(settings, animated: false)
        g.configure(settings, animated: false)
        var cFrame: RenderedFrame?, gFrame: RenderedFrame?
        playBloom(&c, BloomSong.held(pitch: 0, tonality: 1, seconds: 3), renderer: renderer) { _, frame, _ in cFrame = frame }
        playBloom(&g, BloomSong.held(pitch: 7, tonality: 1, seconds: 3), renderer: renderer) { _, frame, _ in gFrame = frame }
        check(cFrame!.difference(from: gFrame!) > 0.01, "C and G must play different shapes")

        // The heart's light is soft, with no lines in it: on a big-heart shape
        // with a vocal lighting it, the inside has hardly any fine structure.
        if let large = try? OffscreenRenderer(device: device, width: 640, height: 400) {
            for pitch in [0, 1] {
                var sung = BackgroundAnimator()
                sung.configure(settings, animated: false)
                var last: RenderedFrame?
                playBloom(&sung, BloomSong.held(pitch: Float(pitch), tonality: 1, mid: 0.8, seconds: 3), renderer: large) { _, frame, _ in last = frame }
                let (lines, share) = heartLines(last!, heart: heartPixels(sung.bloomUniforms(width: 640, height: 400), width: 640, height: 400))
                print(String(format: "Bloom heart (pitch class %d, vocal): fine structure %.4f over %.0f%% of the frame", pitch, lines, share * 100))
                check(share > 0.05 && lines < 0.004, "the heart must glow without lines (\(lines) over \(share) of the frame)")
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

        // Harmony: a held pitch class with clear tonality settles on its shape;
        // with none the shape only wanders slowly.
        for pitch in [0, 4, 7, 11] {
            let settled = rig(BloomSong.held(pitch: Float(pitch), tonality: 1, seconds: 4))
            let shape = BloomRig.shapes[pitch]
            check(abs(BloomRig.wrap(settled.theta.position - shape.theta)) < 0.02 && abs(settled.radius.position - shape.radius) < 0.02,
                  "pitch class \(pitch) must play its shape (θ \(settled.theta.position) vs \(shape.theta))")
        }
        var thetas: [Float] = []
        _ = rig(BloomSong.held(pitch: 7, tonality: 0, seconds: 4)) { rig, _ in thetas.append(rig.theta.position) }
        let drift = abs(thetas.last! - thetas.first!) / 4
        check(drift > 0.005 && drift < 0.2, "with no clear harmony the shape must wander slowly (\(drift) rad a second)")

        // Kick: a small pull in, then out past the cardioid's edge, and back within a second.
        var kick = BloomSong.held(pitch: 0, tonality: 1, seconds: 6)
        kick[90].layers.kick = 1
        var rhos: [Float] = []
        var rest: Float = 0
        _ = rig(kick) { rig, display in
            if display == 179 { rest = rig.rho }
            if display >= 180 { rhos.append(rig.rho) }
        }
        let pulledIn = rhos.prefix(3).min()!, peak = rhos.max()!, peakAt = rhos.firstIndex(of: peak)!
        print(String(format: "Bloom mapping: a kick pulls ρ in to %.3f, throws it to %.3f after %d ms, back to %.3f a second on (rest %.3f)",
                     pulledIn, peak, peakAt * 1000 / 60, rhos[60], rest))
        check(pulledIn < rest - 0.001, "a kick must gather the set in first (\(pulledIn) vs \(rest))")
        check(peak > 1.01 && peakAt < 12, "a kick must throw the set past the edge into dust within 200 ms (\(peak) at \(peakAt))")
        check(abs(rhos[60] - rest) < 0.01, "the set must knit back within a second (\(rhos[60]))")
        var calm = settings
        calm.punch = 0
        var calmRhos: [Float] = []
        _ = rig(kick, configuration: calm) { rig, display in if display >= 180 { calmRhos.append(rig.rho) } }
        check(calmRhos.max()! - calmRhos.min()! < 0.002, "Bass punch at 0 must leave the set whole")

        // Snare: the plane turns a facet, quickly, and stays there.
        var snare = BloomSong.held(pitch: 0, tonality: 1, seconds: 3)
        snare[45].layers.snare = 1
        var turns: [Float] = []
        _ = rig(snare) { rig, display in if display >= 90 { turns.append(rig.turn.position) } }
        let turned = turns.last! - turns.first!, quick = turns[12] - turns.first!
        check(abs(turned - BloomRig.facet) < 0.08 && quick > 0.8 * turned,
              "a snare must turn the plane a twelfth of a turn within 200 ms (\(turned), \(quick) after 200 ms)")

        // Hat: a glint that's gone within 120 ms.
        var hat = BloomSong.held(pitch: 0, tonality: 1, seconds: 2)
        hat[30].layers.hat = 1
        var glints: [Float] = []
        _ = rig(hat) { rig, display in if display >= 60 { glints.append(rig.glint) } }
        check(glints[0] > 0.5 && glints[7] < 0.05, "a hat must glint and fade within 120 ms (\(glints[0]) → \(glints[7]))")

        // Mids: a held vocal lights the heart; the drums alone don't.
        var vocal = BloomSong.held(pitch: 0, tonality: 1, seconds: 3)
        for i in vocal.indices { vocal[i].layers.mid = 0.8 }
        let lit = rig(vocal).heart, unlit = rig(BloomSong.held(pitch: 0, tonality: 1, seconds: 3).map { var f = $0; f.layers.mid = 0; return f }).heart
        check(lit > 0.4 && unlit < 0.05, "a vocal must light the heart (\(lit) vs \(unlit))")

        // Build and drop: the dive deepens with the build, mostly at its end, and
        // the drop releases it with one wave.
        var build = BloomSong.held(pitch: 0, tonality: 1, seconds: 10)
        for i in build.indices { build[i].layers.build = min(1, Float(i) / 240) }
        for i in 240..<build.count { build[i].layers.build = 0 }
        build[240].layers.drop = 1
        var zooms: [Float] = [], waves: [Float] = []
        _ = rig(build) { rig, _ in zooms.append(rig.zoom); waves.append(rig.wave.strength) }
        check(zooms[240] < 1.4 && zooms[479] > 2.2, "a build must dive in, mostly in its last stretch (\(zooms[240]) halfway, \(zooms[479]) at the end)")
        check(zooms[540] < 1.2 && waves[481] > 0.5, "the drop must release the dive with a wave (\(zooms[540]), wave \(waves[481]))")
    }

    // MARK: - Bloom renders

    /// Renders for looking at, when FLOE_BLOOM_RENDERS names a directory: the
    /// twelve pitch-class shapes, the scripted song frame by frame at 30 fps
    /// with a contact sheet of every tenth frame, and the GPU cost.
    static func bloomRenders(device: MTLDevice) {
        guard let directory = bloomOutput else { return }
        do {
            // One kick, frame by frame: the pull in, the shatter, the knit back.
            guard let renderer = try? OffscreenRenderer(device: device, width: 640, height: 400) else { return }
            var held = BloomSong.held(pitch: 7, tonality: 1, seconds: 3)
            held[45].layers.kick = 1
            var animator = BackgroundAnimator()
            animator.configure(BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset)), animated: false)
            var cells: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
            playBloom(&animator, held, renderer: renderer) { animator, frame, i in
                guard (44...67).contains(i) else { return }
                cells.append((frame, String(format: "%+d ms  ρ %.3f", (i - 45) * 33, animator.bloom.rho),
                              i == 45 ? CGColor(red: 1, green: 0.4, blue: 0.3, alpha: 1) : nil))
            }
            strip(cells, to: directory.appendingPathComponent("kick.png"), columns: 6, scale: 0.4)
        }
        let song = directory.appendingPathComponent("song")
        try? FileManager.default.createDirectory(at: song, withIntermediateDirectories: true)
        let colors = Covers.palette(Covers.sunset)
        let settings = BackgroundConfiguration(kind: .bloom, colors: colors)

        // The twelve shapes, each held with clear harmony until it settles.
        guard let small = try? OffscreenRenderer(device: device, width: 640, height: 400) else { return }
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        var shapes: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for (pitch, name) in names.enumerated() {
            var animator = BackgroundAnimator()
            animator.configure(settings, animated: false)
            var last: RenderedFrame?
            playBloom(&animator, BloomSong.held(pitch: Float(pitch), tonality: 1, seconds: 4), renderer: small) { _, frame, _ in last = frame }
            let shape = BloomRig.shapes[pitch]
            shapes.append((last!, String(format: "%@  θ %.2f  ρ %.3f", name, shape.theta, shape.radius), nil))
        }
        strip(shapes, to: directory.appendingPathComponent("shapes.png"), columns: 4, scale: 0.5)

        // Each kind of cover at the same moments: a held chord, the vocal swell, a shatter.
        var palettes: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for (name, cover) in [("sunset", Covers.palette(Covers.sunset)), ("ocean", Covers.palette(Covers.ocean)),
                              ("navy", Covers.palette(Covers.navy)), ("neutral", neutral)] {
            var animator = BackgroundAnimator()
            animator.configure(BackgroundConfiguration(kind: .bloom, colors: cover, neutral: name == "neutral"), animated: false)
            playBloom(&animator, BloomSong.frames().prefix(200).map { $0 }, renderer: small) { _, frame, i in
                if [55, 172, 182].contains(i) { palettes.append((frame, "\(name), \(String(format: "%.1f s", Float(i) / 30))", nil)) }
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
        var animator = BackgroundAnimator()
        animator.configure(settings, animated: false)
        var sheet: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        let frames = BloomSong.frames()
        playBloom(&animator, frames, renderer: renderer) { _, frame, i in
            save(frame.composited(), to: song.appendingPathComponent(String(format: "frame-%03d.png", i)))
            guard i % 10 == 0 else { return }
            let m = BloomSong.moment(at: Float(i) / 30, frame: i)
            var label = String(format: "%.1f s", Float(i) / 30)
            if m.build > 0 { label += String(format: " build %.2f", m.build) }
            if m.vocal > 0.1 { label += " vocal" }
            sheet.append((frame, label, m.kick ? CGColor(red: 1, green: 0.4, blue: 0.3, alpha: 1) : (m.snare ? CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1) : nil)))
        }
        strip(sheet, to: directory.appendingPathComponent("song-sheet.png"), columns: 6, scale: 0.3)

        // The same song as today's analyzer hears it: no harmony, brightness, build or drop.
        var today = BackgroundAnimator()
        today.configure(settings, animated: false)
        var todaySheet: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        let plain = frames.map { frame -> SpectrumFrame in
            var frame = frame
            (frame.layers.pitchClass, frame.layers.tonality, frame.layers.brightness) = (0, 0, 0)
            (frame.layers.build, frame.layers.drop) = (0, 0)
            return frame
        }
        playBloom(&today, plain, renderer: renderer) { _, frame, i in
            guard i % 10 == 0 else { return }
            let m = BloomSong.moment(at: Float(i) / 30, frame: i)
            todaySheet.append((frame, String(format: "%.1f s%@", Float(i) / 30, m.vocal > 0.1 ? " vocal" : ""),
                               m.kick ? CGColor(red: 1, green: 0.4, blue: 0.3, alpha: 1) : (m.snare ? CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1) : nil)))
        }
        strip(todaySheet, to: directory.appendingPathComponent("song-today-sheet.png"), columns: 6, scale: 0.3)
        print("Bloom renders: \(directory.path)/shapes.png, song-sheet.png and song/frame-000…\(frames.count - 1).png")
        bloomHeartRenders(device: device, directory: directory)
        bloomLongSongRenders(device: device, directory: directory)
    }

    /// Which pixels of a frame lie in the set's heart (orbits that settle onto
    /// the attracting fixed point), from the uniforms the frame was drawn with,
    /// iterated on the CPU the way the shader does.
    static func heartPixels(_ u: BloomUniforms, width: Int, height: Int) -> [Bool] {
        let aspect = Float(width) / Float(height)
        let c = SIMD2(u.c.x, u.c.y), axis = SIMD2(u.c.z, u.c.w), center = SIMD2(u.view.x, u.view.y)
        let alpha = 0.5 * expf(u.flags.z) * SIMD2(cosf(u.flags.w), sinf(u.flags.w))
        let n = Int(u.view.z)
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = SIMD2((2 * (Float(x) + 0.5) / Float(width) - 1) * aspect, 1 - 2 * (Float(y) + 0.5) / Float(height))
                var z = center + SIMD2(axis.x * v.x - axis.y * v.y, axis.x * v.y + axis.y * v.x)
                var dz = SIMD2<Float>(1, 0)
                var state = 0
                for _ in 0..<n {
                    dz = 2 * SIMD2(z.x * dz.x - z.y * dz.y, z.x * dz.y + z.y * dz.x)
                    z = SIMD2(z.x * z.x - z.y * z.y, 2 * z.x * z.y) + c
                    if simd_length_squared(z) > 1024 { state = 1; break }
                    if simd_distance_squared(z, alpha) < 0.0036 { state = 2; break }
                }
                // As in the shader: an orbit still going that has stopped stretching is settling slowly.
                mask[y * width + x] = state == 2 || state == 0 && simd_length_squared(dz) < 1e6
            }
        }
        return mask
    }

    /// Fine structure inside the heart: the mean absolute difference (0…1) between
    /// each heart pixel's luma and its 9×9 neighbourhood's mean, over pixels at
    /// least six pixels deep in the heart. Soft pools and gradients score near
    /// the dither's floor; contour lines score well above it.
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

    /// Big-heart shapes (ρ 0.975 and 0.96) held with and without a vocal, each
    /// cropped at 100% to where the heart fills most of the frame.
    static func bloomHeartRenders(device: MTLDevice, directory: URL) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 1280, height: 800) else { return }
        let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset))
        var cells: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for (pitch, name) in [(0, "C ρ 0.975"), (1, "C♯ ρ 0.960")] {
            for mid: Float in [0, 0.8] {
                var animator = BackgroundAnimator()
                animator.configure(settings, animated: false)
                var last: RenderedFrame?
                playBloom(&animator, BloomSong.held(pitch: Float(pitch), tonality: 1, mid: mid, seconds: 4), renderer: renderer) { _, frame, _ in
                    last = frame
                }
                guard let frame = last else { continue }
                let heart = heartPixels(animator.bloomUniforms(width: 1280, height: 800), width: 1280, height: 800)
                var best = (x: 0, y: 0, count: -1)
                for y in stride(from: 0, through: 400, by: 40) {
                    for x in stride(from: 0, through: 640, by: 40) {
                        var count = 0
                        for row in stride(from: y, to: y + 400, by: 4) { for column in stride(from: x, to: x + 640, by: 4) where heart[row * 1280 + column] { count += 1 } }
                        if count > best.count { best = (x, y, count) }
                    }
                }
                let (lines, share) = heartLines(frame, heart: heart)
                print(String(format: "Bloom heart, %@, %@: fine structure %.4f over %.0f%% of the frame",
                             name, mid > 0 ? "vocal" : "no vocal", lines, share * 100))
                cells.append((frame.crop(x: best.x, y: best.y, width: 640, height: 400),
                              String(format: "%@, %@, lines %.4f", name, mid > 0 ? "vocal" : "no vocal", lines), nil))
            }
        }
        strip(cells, to: directory.appendingPathComponent("heart.png"), columns: 2, scale: 1)
    }

    /// The long song, a frame every half second, with what the rig reports
    /// marked on each cell (`marks`: points in 0…1 frame coordinates, top-left origin).
    static func bloomLongSongRenders(device: MTLDevice, directory: URL,
                                     marks: (BackgroundAnimator, Int, Int) -> [(x: CGFloat, y: CGFloat, color: CGColor)] = { _, _, _ in [] }) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 640, height: 400) else { return }
        var animator = BackgroundAnimator()
        animator.configure(BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset)), animated: false)
        var sheet: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        var dots: [[(x: CGFloat, y: CGFloat, color: CGColor)]] = []
        playBloom(&animator, BloomLongSong.frames(), renderer: renderer) { animator, frame, i in
            guard i % 15 == 0 else { return }
            let t = Float(i) / 30
            let m = BloomLongSong.moment(at: t, frame: i)
            var label = String(format: "%.1f s %@", t, BloomLongSong.section(at: t))
            if m.vocal > 0.1 { label += " vocal" }
            sheet.append((frame, label, m.kick ? CGColor(red: 1, green: 0.4, blue: 0.3, alpha: 1) : (m.snare ? CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1) : nil)))
            dots.append(marks(animator, frame.width, frame.height))
        }
        strip(sheet, to: directory.appendingPathComponent("long-song-sheet.png"), columns: 8, scale: 0.3, dots: dots)
    }

    /// GPU time per Bloom frame at the sizes the app draws, in its costliest
    /// state (deep in a build, full detail, the heart lit).
    static func bloomPerformance(device: MTLDevice) {
        var animator = BackgroundAnimator()
        animator.configure(BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset)), animated: false)
        for frame in BloomSong.frames().prefix(Int(BloomSong.dropTime * 30) - 3) { animator.advance(by: 1 / 30, frame: frame) }
        var resting = BackgroundAnimator()
        resting.configure(BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset)), animated: false)
        for frame in BloomSong.held(pitch: 9, tonality: 1, seconds: 3) { resting.advance(by: 1 / 30, frame: frame) }
        let windows: [(String, CGSize)] = [("1200x750 pt window", CGSize(width: 1200, height: 750)),
                                           ("1440x900 pt window", CGSize(width: 1440, height: 900)),
                                           ("1728x1117 pt full screen", CGSize(width: 1728, height: 1117))]
        for (name, points) in windows {
            let size = BackgroundRenderer.drawableSize(points: points, scale: 2, kind: .bloom)
            guard let renderer = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) else { continue }
            let deep = renderer.gpuMilliseconds(animator)
            let rest = renderer.gpuMilliseconds(resting)
            print(String(format: "GPU per frame, %@, Bloom (%dx%d): %.2f ms deep in a build, %.2f ms held on a chord, %.1f%% of the GPU at 60 Hz",
                         name, Int(size.width), Int(size.height), deep, rest, max(deep, rest) * 6))
        }
    }

    /// Labelled thumbnails in rows, written to `url`.
    static func strip(_ cells: [(frame: RenderedFrame, label: String, mark: CGColor?)], to url: URL, columns: Int, scale: CGFloat,
                      dots: [[(x: CGFloat, y: CGFloat, color: CGColor)]] = []) {
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
            if n < dots.count {
                for dot in dots[n] {
                    let centre = CGPoint(x: CGFloat(x) + dot.x * CGFloat(cellW), y: CGFloat(top) - dot.y * CGFloat(cellH))
                    context.setStrokeColor(dot.color)
                    context.setLineWidth(1.5)
                    context.strokeEllipse(in: CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8))
                }
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
