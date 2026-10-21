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
/// Bloom has sections to play through: a pad intro, a verse, an
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

    /// An animator `progress` along the dive into `destination`, as configured.
    static func diving(_ destination: Int, at progress: Double, _ configuration: BackgroundConfiguration) -> BackgroundAnimator {
        var animator = BackgroundAnimator()
        animator.configure(configuration, animated: false)
        animator.bloom = BloomRig(destination: destination, progress: progress)
        return animator
    }

    /// Where along the dive into `destination` the next one starts fading in.
    static func handoffStart(_ destination: Int) -> Double {
        1 - BloomRig.handoff / BloomRig.destinations[destination].depth
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

        // The dive is endless: as one dive hands over to the next, and where the
        // next takes over, the picture changes no more than between any two frames.
        let fast = BackgroundConfiguration(kind: .bloom, colors: sunset, speed: 2)
        var music = diving(0, at: handoffStart(0) - 0.4 / BloomRig.destinations[0].depth, fast)
        var steps: [Float] = [], blending: [Int] = [], takeover: Int?
        var previous: RenderedFrame?
        playBloom(&music, BloomSong.held(pitch: 7, tonality: 1, loudness: 0.6, seconds: 18), renderer: renderer) { animator, frame, _ in
            if let previous { steps.append(frame.difference(from: previous)) }
            if animator.bloom.next != nil { blending.append(steps.count - 1) }
            if takeover == nil, animator.bloom.destination != 0 { takeover = steps.count - 1 }
            previous = frame
        }
        let typical = steps.prefix(60).sorted()[30]
        let worstBlend = blending.map { steps[$0] }.max() ?? 0
        let atTakeover = takeover.map { steps[$0] } ?? 0
        print(String(format: "Bloom handoff: %.1f s fading in, change at most %.5f a frame meanwhile and %.5f as it takes over, typical %.5f",
                     Float(blending.count) / 30, worstBlend, atTakeover, typical))
        check(takeover != nil && music.bloom.destination == 7, "the next dive must take over, the one the harmony names (\(music.bloom.destination))")
        check(blending.count > 60, "the next dive must fade in over seconds (\(blending.count) frames)")
        check(worstBlend < 2.5 * typical + 0.0005 && atTakeover < 2.5 * typical + 0.0005,
              "one dive must run seamlessly into the next (\(worstBlend), \(atTakeover) vs \(typical))")
        check(typical > silentStep, "with music the dive must move (\(typical) a frame)")

        // A kick pushes the dive on, not the brightness: against a twin that never heard it.
        let held = BloomSong.held(pitch: 0, tonality: 0, seconds: 3)
        var hit = held
        hit[45].layers.kick = 1
        var kicked = diving(0, at: 0.4, settings), twin = diving(0, at: 0.4, settings)
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
        check(apart[75] > 0, "a kick must push the dive on")
        check(lumaRatio.allSatisfy { abs($0 - 1) < 0.1 }, "a kick must not change the brightness (\(lumaRatio.min()!)…\(lumaRatio.max()!))")

        // Harmony picks the next dive: G as the handoff begins sends it down a
        // different valley from C. Every dive sets out from the whole set, so
        // they part only once the next has taken over.
        let early = handoffStart(0) - 0.15 / BloomRig.destinations[0].depth
        var c = diving(0, at: early, fast), g = diving(0, at: early, fast)
        var cFrame: RenderedFrame?, gFrame: RenderedFrame?
        playBloom(&c, BloomSong.held(pitch: 0, tonality: 1, loudness: 0.6, seconds: 22), renderer: renderer) { _, frame, _ in cFrame = frame }
        playBloom(&g, BloomSong.held(pitch: 7, tonality: 1, loudness: 0.6, seconds: 22), renderer: renderer) { _, frame, _ in gFrame = frame }
        check(c.bloom.destination != 0 && c.bloom.destination != g.bloom.destination,
              "C and G must take different dives (\(c.bloom.destination), \(g.bloom.destination))")
        check(cFrame!.difference(from: gFrame!) > 0.01, "C and G must head into different valleys (\(cFrame!.difference(from: gFrame!)))")

        // The bulbs' light is soft, with no lines in it.
        if let large = try? OffscreenRenderer(device: device, width: 640, height: 400) {
            for (destination, progress) in Self.hearts {
                let (frame, heart) = heldHeart(destination, at: progress, mid: 0.8, renderer: large, settings: settings)
                let (lines, share) = heartLines(frame, heart: heart)
                print(String(format: "Bloom bulbs (dive %d at %.2f, vocal): fine structure %.4f over %.0f%% of the frame", destination, progress, lines, share * 100))
                check(share > 0.02 && lines < 0.004, "the bulbs must glow without lines (\(lines) over \(share) of the frame)")
            }
        }

        // Photosensitivity and legibility through the song and through a frantic
        // groove at the brightest settings, at the start of a dive and near its
        // end: no region flashes more than three times a second, and text stays readable.
        let frantic = SyntheticTrack(kicksPerSecond: 8, kick: 0.95, bass: 0.3, pad: 0.25, hats: 0.12, snare: 0.4, kickOffset: 1)
        var franticFrames = SyntheticTrack.frames([(SyntheticTrack(pad: 0.08), 1), (frantic, 4)])
        for i in stride(from: 45, to: franticFrames.count, by: 20) { franticFrames[i].layers.drop = 1 }
        let brightest = BackgroundConfiguration(kind: .bloom, colors: [RGB(r: 1, g: 0.95, b: 0.6), RGB(r: 0.9, g: 1, b: 0.9)],
                                                reactivity: 2, speed: 2, glow: 2, punch: 2, vividness: 1.5)
        for (name, frames, configuration) in [("song, defaults", BloomSong.frames(), settings), ("frantic, brightest", franticFrames, brightest),
                                              ("frantic, defaults", franticFrames, settings)] {
            for (destination, progress) in [(0, 0.0), (3, 0.5), (1, handoffStart(1))] {
                var animator = diving(destination, at: progress, configuration)
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
                let label = "\(name), dive \(destination) at \(String(format: "%.2f", progress))"
                print(String(format: "Bloom %@: at most %d WCAG flashes a second over the frame, %d in any region; peak luma %.2f, mean at most %.3f",
                             label, whole, worst, brightestLuma, meanest))
                check(worst <= 3 && whole == 0, "\(label): Bloom must never flash (\(whole) a second over the frame, \(worst) in a region)")
                // As for Fluid: the presets' looks stay under 0.2, the brightest settings on a pale cover under 0.32.
                let darkEnough: Float = configuration == brightest ? 0.32 : 0.2
                check(brightestLuma <= legibleLuma && meanest < darkEnough, "\(label): Bloom must stay dark enough for text (peak \(brightestLuma), mean \(meanest))")
            }
        }

        // The window-sized drawable renders like the small one: at full Retina,
        // from a field that stays within its budget.
        let size = BackgroundRenderer.drawableSize(points: CGSize(width: 1440, height: 900), scale: 2, kind: .bloom)
        let budget = BackgroundRenderer.bloomFieldBudget(.high)
        let field = BackgroundRenderer.bloomFieldSize(width: Int(size.width), height: Int(size.height), budget: budget)
        check(size.width == 2880 && field.width * field.height <= budget + 2_000,
              "Bloom must draw at full Retina from a field within budget (\(size), field \(field))")
        if let large = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) {
            let frame = large.render(c)
            check(frame.meanLuma > 0.01 && frame.maxLuma <= legibleLuma, "the window-sized Bloom must render (\(frame.meanLuma))")
        }
        bloomFreshChecks(device: device)
    }

    /// Every frame is worked out afresh, nothing carried over from the last:
    /// through the song (kicks, the build, the drop), a renderer that has drawn
    /// every frame before draws each one exactly as a new one does.
    static func bloomFreshChecks(device: MTLDevice) {
        guard let running = try? OffscreenRenderer(device: device, width: 640, height: 400),
              let fresh = try? OffscreenRenderer(device: device, width: 640, height: 400) else { return }
        let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset))
        var worst: Float = 0
        var animator = diving(1, at: handoffStart(1) - 0.05, settings)
        playBloom(&animator, BloomSong.frames(), renderer: running) { animator, frame, i in
            guard i % 30 == 29 else { return }
            worst = max(worst, frame.difference(from: fresh.render(animator)))
        }
        print(String(format: "Bloom afresh: a running renderer's frames differ from a new one's by at most %.5f", worst))
        check(worst == 0, "every Bloom frame must be worked out afresh (\(worst))")
        bloomStabilityChecks(device: device)
    }

    /// A dense stretch of a dive, two seconds of it, stays steady: each frame
    /// differs from the last, moved on by the dive's own motion, by little more
    /// than the motion itself, where the same drawn at half the size and
    /// blown up pixel by pixel crawls. And nothing
    /// in it reads as a speck: no lone pixel far darker than all round it.
    static func bloomStabilityChecks(device: MTLDevice) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 640, height: 400),
              let coarse = try? OffscreenRenderer(device: device, width: 320, height: 200) else { return }
        let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset), speed: 2)
        let music = BloomSong.held(pitch: 7, tonality: 1, loudness: 0.7, mid: 0.4, seconds: 2)
        func shimmers(_ render: (BackgroundAnimator) -> RenderedFrame) -> Float {
            var animator = diving(3, at: 0.75, settings)
            var frames: [(LumaImage, BloomView)] = [], sum: Float = 0, count = 0
            for frame in music {
                animator.receive(frame)
                animator.step(by: 1 / 60)
                animator.step(by: 1 / 60)
                let shown = render(animator)
                frames.append((LumaImage(shown).blurred(2), animator.bloom.views.current))
                if frames.count == 3 {
                    sum += flicker(frames[0], frames[1], frames[2], screen: (640, 400))
                    count += 1
                    frames.removeFirst()
                }
            }
            return sum / Float(max(count, 1))
        }
        let steady = shimmers { renderer.render($0) }
        let aliased = shimmers { animator in
            let small = coarse.render(animator)
            var bytes = [UInt8](repeating: 0, count: 640 * 400 * 4)
            for y in 0..<400 { for x in 0..<640 { for c in 0..<4 { bytes[(y * 640 + x) * 4 + c] = small.bytes[((y / 2) * 320 + x / 2) * 4 + c] } } }
            return RenderedFrame(width: 640, height: 400, bytes: bytes)
        }
        // Specks, at the size of a full-screen window: the dense stretch and an outline by open space.
        var specks = 0
        if let screen = try? OffscreenRenderer(device: device, width: 2880, height: 1864) {
            for (destination, progress) in [(3, 0.75), (0, 0.5)] {
                var animator = diving(destination, at: progress, BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset)))
                for frame in music { animator.advance(by: 1 / 30, frame: frame) }
                specks = max(specks, speckCount(screen.render(animator)))
            }
        }
        print(String(format: "Bloom stability: a dense stretch shimmers %.4f a frame beyond its motion (blocky: %.4f); at most %d specks in a full-screen frame",
                     steady, aliased, specks))
        check(steady < 0.0025 && aliased > 0.0025, "Bloom must not shimmer (\(steady), blocky \(aliased))")
        check(specks <= 5, "Bloom must show no specks (\(specks))")
    }

    /// Lone dark pixels in light: each pixel darker than half the darkest of
    /// the eight round it, where those are all clearly lit.
    static func speckCount(_ frame: RenderedFrame) -> Int {
        var count = 0
        for y in 1..<(frame.height - 1) {
            for x in 1..<(frame.width - 1) {
                var darkest: Float = 1
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 { darkest = min(darkest, frame.luma(x + dx, y + dy)) } }
                if darkest > 0.08 && frame.luma(x, y) < 0.5 * darkest { count += 1 }
            }
        }
        return count
    }

    /// Where the bulbs are big: the whole set, and two dives passing large ones early on.
    static let hearts: [(Int, Double)] = [(0, 0), (2, 0.15), (4, 0.15)]

    /// What plays what, frame by frame on the rig alone, as the app steps it
    /// (analysis at 30 Hz, display at 60).
    static func bloomMappingChecks() {
        let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset))
        func rig(_ frames: [SpectrumFrame], configuration: BackgroundConfiguration = settings, from start: BloomRig = BloomRig(),
                 each: (BloomRig, Int) -> Void = { _, _ in }) -> BloomRig {
            var animator = BackgroundAnimator()
            animator.configure(configuration, animated: false)
            animator.bloom = start
            play(&animator, frames) { animator, _, display in each(animator.bloom, display) }
            return animator.bloom
        }

        // Every destination is a copy of the set: its orbit comes back to 0 after
        // its period, it lies a good way down, and the dive turns gently, if at all.
        for (index, d) in BloomRig.destinations.enumerated() {
            var z = Complex(0, 0)
            for _ in 0..<d.period { z = z * z + d.nucleus }
            let turn = atan2(d.scale.im, d.scale.re)
            print(String(format: "Bloom dive %d: period %d, %.1f e-folds down, turning %.0f° on the way, heading for (%.2f, %.2f) on the screen",
                         index, d.period, d.depth, turn * 180 / .pi, d.focus.x, d.focus.y))
            check(z.magnitude < 1e-9, "dive \(index)'s nucleus must be periodic (\(z.magnitude))")
            check(d.depth > 7 && d.depth < 16, "dive \(index) must go a good way down (\(d.depth) e-folds)")
            check(abs(d.focus.x) < 1.6 && abs(d.focus.y) < 1, "dive \(index) must head for a point on the screen (\(d.focus))")
            // Its end frames the copy as its start frames the whole set.
            let end = d.view(along: d, at: 1, scale: 1)
            let expected = d.scale * BloomRig.home
            check((end.offset - expected).magnitude < 1e-9 * d.scale.magnitude && (end.perScreenUnit - d.scale * BloomRig.span).magnitude < 1e-9 * d.scale.magnitude,
                  "dive \(index) must end framing its copy as the whole set")
        }

        // Pace: all but still in silence, faster when louder, quickest at a build's end; eased after the drop.
        let silent = rig(Array(repeating: .quiet, count: 120))
        let soft = rig(BloomSong.held(pitch: 0, tonality: 0, loudness: 0.2, seconds: 6))
        let loud = rig(BloomSong.held(pitch: 0, tonality: 0, loudness: 0.6, seconds: 6))
        print(String(format: "Bloom pace: %.3f e-folds a second in silence, %.3f soft, %.3f loud", silent.pace, soft.pace, loud.pace))
        check(silent.pace < 0.004 && soft.pace > silent.pace * 2 && loud.pace > soft.pace * 1.2 && loud.pace < 0.08,
              "the dive's pace must follow the loudness, gently (\(silent.pace), \(soft.pace), \(loud.pace))")

        var build = BloomSong.held(pitch: 0, tonality: 1, loudness: 0.5, seconds: 16)
        for i in build.indices { build[i].layers.build = i < 240 ? Float(i) / 240 : 0 }
        build[240].layers.drop = 1
        var paces: [Float] = [], waves: [Float] = []
        _ = rig(build) { rig, _ in paces.append(rig.pace); waves.append(rig.wave.strength) }
        print(String(format: "Bloom build: pace %.3f halfway, %.3f at its end, %.3f 5 s after the drop", paces[240], paces[479], paces[780]))
        check(paces[240] < 0.08 && paces[479] > 0.11, "a build must quicken the dive, mostly in its last stretch (\(paces[240]), \(paces[479]))")
        let cruise = rig(BloomSong.held(pitch: 0, tonality: 1, loudness: 0.5, seconds: 8)).pace
        check(paces[780] - cruise < 0.25 * (paces[479] - cruise) && waves[481] > 0.5, "the drop must ease the dive with a wave (\(paces[780]), wave \(waves[481]))")

        // Comfort: away from builds nothing crosses the screen faster than a few
        // percent of its height a second, even at the far corner from where the
        // dive heads, turning and leaning included, and that point only glides.
        var fastest: Float = 0, fastestAnywhere: Float = 0, glide: Float = 0
        var last = SIMD2<Float>.zero, lastLean = SIMD2<Float>.zero, tense = -1000
        _ = rig(BloomSong.frames() + BloomLongSong.frames(), from: BloomRig(destination: 0, progress: handoffStart(0) - 0.02)) { rig, display in
            let d = BloomRig.destinations[rig.destination]
            let turn = Float(atan2(d.scale.im, d.scale.re) / d.depth)
            let reach = simd_length(SIMD2(1.6, 1) + abs(rig.focus))
            let leaning = display > 0 ? simd_distance(rig.lean, lastLean) * 60 : 0
            let corner = reach * (1 + turn * turn).squareRoot() * (rig.pace + rig.surge) * settings.speed + leaning
            fastestAnywhere = max(fastestAnywhere, corner)
            if rig.tension > 0.3 { tense = display }
            if display - tense > 240 { fastest = max(fastest, corner) }
            if display > 0 { glide = max(glide, simd_distance(rig.focus, last) * 60) }
            last = rig.focus
            lastLean = rig.lean
        }
        print(String(format: "Bloom comfort: the far corner moves at most %.2f half-heights a second outside builds, %.2f in them; the centre at most %.3f",
                     fastest, fastestAnywhere, glide))
        check(fastest < 0.25 && fastestAnywhere < 0.45, "the dive must stay gentle (\(fastest) outside builds, \(fastestAnywhere) in them)")
        check(glide < 0.08, "the dive's centre must only glide (\(glide) a second)")

        // Harmony leans the view a little toward the chord's side: C and G part,
        // a key-less passage hardly leans, and silence holds the lean where it is.
        let leanC = rig(BloomSong.held(pitch: 0, tonality: 1, seconds: 40)).lean
        let leanG = rig(BloomSong.held(pitch: 7, tonality: 1, seconds: 40)).lean
        let unkeyed = rig(BloomSong.held(pitch: 7, tonality: 0, seconds: 40)).lean
        var hush = BloomSong.held(pitch: 7, tonality: 1, seconds: 10)
        let leaning = rig(hush).lean
        hush += Array(repeating: .quiet, count: 300)
        let held = rig(hush).lean
        print(String(format: "Bloom lean: C (%.3f, %.3f), G (%.3f, %.3f), no key %.3f; through 10 s of silence it moves %.4f",
                     leanC.x, leanC.y, leanG.x, leanG.y, simd_length(unkeyed), simd_distance(held, leaning)))
        check(simd_distance(leanC, leanG) > 0.1 && simd_length(leanC) <= BloomRig.leanReach * 1.01 && simd_length(unkeyed) < 0.02,
              "harmony must lean the view a little, its own way for each chord (\(leanC), \(leanG), \(unkeyed))")
        check(simd_distance(held, leaning) < 0.01, "silence must hold the lean (\(simd_distance(held, leaning)))")

        // Kick: a small push on, none at Bass punch 0.
        var kick = BloomSong.held(pitch: 0, tonality: 1, seconds: 3)
        kick[45].layers.kick = 1
        let pushed = rig(Array(kick.prefix(46))).surge
        var calm = settings
        calm.punch = 0
        let unpushed = rig(Array(kick.prefix(46)), configuration: calm).surge
        check(pushed > 0.015 && pushed < 0.06 && unpushed == 0, "a kick must push the dive on a little (\(pushed), \(unpushed) at punch 0)")

        // Harmony picks the next dive as the handoff begins; never the same one again, and with no clear key it moves on.
        let count = BloomRig.destinations.count
        for (pitch, tonality, expected) in [(3, 1, 3), (7, 1, 7), (11, 1, 11 % count), (0, 1, 1), (7, 0, 3)] as [(Int, Float, Int)] {
            let start = BloomRig(destination: 0, progress: handoffStart(0) - 0.001)
            let next = rig(BloomSong.held(pitch: Float(pitch), tonality: tonality, seconds: 3), from: start).next
            check(next == expected, "pitch class \(pitch) at tonality \(tonality) must head for dive \(expected) next (\(String(describing: next)))")
        }

        // Over a long while the dives follow one another, each taking over where the last ended.
        var loudFast = settings
        loudFast.speed = 2
        var order = [0], jumps: Float = 0
        last = BloomRig().focus
        _ = rig(BloomSong.held(pitch: 0, tonality: 0, loudness: 0.6, seconds: 600), configuration: loudFast) { rig, _ in
            if rig.destination != order.last! { order.append(rig.destination) }
            jumps = max(jumps, simd_distance(rig.focus, last) * 60)
            last = rig.focus
        }
        print("Bloom over ten minutes: dives " + order.map(String.init).joined(separator: " → "))
        check(order.count >= 4 && zip(order, order.dropFirst()).allSatisfy { $0 != $1 }, "the dives must follow one another (\(order))")
        check(jumps < 0.08, "the dive's centre must glide from one dive to the next (\(jumps) a second)")

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

    /// Renders for looking at, when FLOE_BLOOM_RENDERS names a directory: each
    /// dive on its way down, a handoff, the scripted song frame by frame at 30 fps
    /// with a contact sheet of every tenth frame, and the long song.
    static func bloomRenders(device: MTLDevice) {
        guard let directory = bloomOutput else { return }
        let song = directory.appendingPathComponent("song")
        try? FileManager.default.createDirectory(at: song, withIntermediateDirectories: true)
        let colors = Covers.palette(Covers.sunset)
        let settings = BackgroundConfiguration(kind: .bloom, colors: colors)
        guard let small = try? OffscreenRenderer(device: device, width: 640, height: 400) else { return }
        bloomDiveRenders(device: device)

        // One handoff, in eight steps, from before the next dive fades in to after it takes over.
        var handoff: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        var animator = diving(0, at: handoffStart(0) - 0.2 / BloomRig.destinations[0].depth, settings)
        let loud = BloomSong.held(pitch: 7, tonality: 1, loudness: 0.6, seconds: 1)[0]
        for _ in 0..<8 {
            handoff.append((small.render(animator), String(format: "dive %d at %.3f, blend %.2f", animator.bloom.destination, animator.bloom.progress, animator.bloom.blend), nil))
            let efolds = 1.6 / 8
            var travelled = 0.0
            while travelled < efolds {
                let before = animator.bloom.progress * BloomRig.destinations[animator.bloom.destination].depth
                let was = animator.bloom.destination
                animator.advance(by: 1 / 30, frame: loud)
                travelled += was == animator.bloom.destination
                    ? animator.bloom.progress * BloomRig.destinations[was].depth - before
                    : animator.bloom.progress * BloomRig.destinations[animator.bloom.destination].depth + BloomRig.destinations[was].depth - before
            }
        }
        strip(handoff, to: directory.appendingPathComponent("handoff.png"), columns: 4, scale: 0.5)

        // Each kind of cover at the same moments: before the beat, the vocal swell, just after the drop.
        var palettes: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for (name, cover) in [("sunset", Covers.palette(Covers.sunset)), ("ocean", Covers.palette(Covers.ocean)),
                              ("navy", Covers.palette(Covers.navy)), ("neutral", neutral)] {
            var animator = diving(3, at: 0.45, BackgroundConfiguration(kind: .bloom, colors: cover, neutral: name == "neutral"))
            playBloom(&animator, BloomSong.frames().prefix(300).map { $0 }, renderer: small) { _, frame, i in
                if [55, 172, 295].contains(i) { palettes.append((frame, "\(name), \(String(format: "%.1f s", Float(i) / 30))", nil)) }
            }
        }
        strip(palettes, to: directory.appendingPathComponent("palettes.png"), columns: 3, scale: 0.5)

        // At the drawable size of a 1440×900 pt window, as the app draws it, and a crop at 100%.
        let size = BackgroundRenderer.drawableSize(points: CGSize(width: 1440, height: 900), scale: 2, kind: .bloom)
        if let large = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) {
            var animator = diving(0, at: 0.5, settings)
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
        var player = diving(0, at: 0.3, settings)
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
        print("Bloom renders: \(directory.path)/dives.png, handoff.png, song-sheet.png and song/frame-000…\(frames.count - 1).png")
        bloomHeartRenders(device: device, directory: directory)
        bloomLongSongRenders(device: device, directory: directory)
    }

    /// Each dive at five depths, settled in with some music.
    static func bloomDiveRenders(device: MTLDevice) {
        guard let directory = bloomOutput, let small = try? OffscreenRenderer(device: device, width: 640, height: 400) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset))
        let music = BloomSong.held(pitch: 0, tonality: 0, loudness: 0.5, mid: 0.4, seconds: 1)

        var dives: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for (index, d) in BloomRig.destinations.enumerated() {
            for progress in [0.15, 0.35, 0.55, 0.75, handoffStart(index) - 0.01] {
                var animator = diving(index, at: progress, settings)
                var last: RenderedFrame?
                playBloom(&animator, music, renderer: small) { _, frame, _ in last = frame }
                dives.append((last!, String(format: "dive %d (period %d), %.1f e-folds down", index, d.period, progress * d.depth), nil))
            }
        }
        strip(dives, to: directory.appendingPathComponent("dives.png"), columns: 5, scale: 0.5)

        // The deepest any dive goes, alone (no next dive fading in over it), at
        // 100%: single precision must still tell every pixel apart down here.
        if let large = try? OffscreenRenderer(device: device, width: 960, height: 600),
           let deepest = BloomRig.destinations.indices.max(by: { BloomRig.destinations[$0].depth < BloomRig.destinations[$1].depth }) {
            let frame = large.render(diving(deepest, at: 0.999, settings))
            save(frame.composited(), to: directory.appendingPathComponent("deepest.png"))
        }
    }

    /// A dive held a few seconds with the mids at `mid`, its last frame, and which of its pixels lie in the bulbs.
    static func heldHeart(_ destination: Int, at progress: Double, mid: Float, renderer: OffscreenRenderer,
                          settings: BackgroundConfiguration) -> (frame: RenderedFrame, heart: [Bool]) {
        var animator = diving(destination, at: progress, settings)
        var last: RenderedFrame?
        playBloom(&animator, BloomSong.held(pitch: 0, tonality: 0, mid: mid, seconds: 3), renderer: renderer) { _, frame, _ in last = frame }
        let (width, height) = (last!.width, last!.height)
        return (last!, heartPixels(animator.bloom, iterations: Int(animator.bloomUniforms(width: 1, height: 1).view.x), width: width, height: height))
    }

    /// Which pixels of a frame lie in the bulbs (orbits that settle onto a
    /// cycle), iterated in double precision on the CPU with the shader's test.
    static func heartPixels(_ rig: BloomRig, iterations: Int, width: Int, height: Int) -> [Bool] {
        let view = rig.views.current
        let nucleus = BloomRig.destinations[rig.destination].nucleus
        let aspect = Double(width) / Double(height)
        let rows = UnsafeMutableBufferPointer<Bool>.allocate(capacity: width * height)
        defer { rows.deallocate() }
        rows.initialize(repeating: false)
        nonisolated(unsafe) let mask = rows
        DispatchQueue.concurrentPerform(iterations: height) { y in
            var row = [Bool](repeating: false, count: width)
            for x in 0..<width {
                let v = Complex((2 * (Double(x) + 0.5) / Double(width) - 1) * aspect, 1 - 2 * (Double(y) + 0.5) / Double(height))
                let c = nucleus + view.offset + view.perScreenUnit * v
                var z = Complex(0, 0), dz = Complex(0, 0), dZ = Complex(1, 0)
                var state = 0
                for i in 0..<iterations {
                    dz = 2 * z * dz + view.perScreenUnit
                    if i > 0 { dZ = 2 * z * dZ }
                    z = z * z + c
                    if z.re * z.re + z.im * z.im > 1024 { state = 1; break }
                    if i > 0, dZ.re * dZ.re + dZ.im * dZ.im < 1e-10 { state = 2; break }
                }
                // As in the shader: an orbit still going that has stopped stretching is settling slowly.
                row[x] = state == 2 || state == 0 && dz.re * dz.re + dz.im * dz.im < 1e6
            }
            for x in 0..<width { mask[y * width + x] = row[x] }
        }
        return Array(rows)
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

    /// Bulbs with and without a vocal, at 100%.
    static func bloomHeartRenders(device: MTLDevice, directory: URL) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 1280, height: 800) else { return }
        let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset))
        var cells: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for (destination, progress) in hearts {
            for mid: Float in [0, 0.8] {
                let (frame, heart) = heldHeart(destination, at: progress, mid: mid, renderer: renderer, settings: settings)
                let (lines, share) = heartLines(frame, heart: heart)
                cells.append((frame.crop(x: 320, y: 200, width: 640, height: 400),
                              String(format: "dive %d at %.2f, %@, lines %.4f over %.0f%%", destination, progress, mid > 0 ? "vocal" : "no vocal", lines, share * 100), nil))
            }
        }
        strip(cells, to: directory.appendingPathComponent("heart.png"), columns: 2, scale: 1)
    }

    /// The long song, a frame every half second.
    static func bloomLongSongRenders(device: MTLDevice, directory: URL) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 640, height: 400) else { return }
        var animator = diving(2, at: 0.3, BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset)))
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

    /// GPU time per Bloom frame at the sizes the app draws, at full detail,
    /// over every dive at several depths and through a handoff (two dives
    /// drawn), at each detail setting: first at the setting's full field, then
    /// as the app settles, its field a step smaller wherever that costs too much.
    static func bloomPerformance(device: MTLDevice) {
        var bright = BloomSong.held(pitch: 0, tonality: 0, loudness: 0.5, seconds: 2)
        for i in bright.indices { bright[i].layers.high = 1; bright[i].layers.brightness = 1 }
        let windows: [(String, CGSize)] = [("1200x750 pt window", CGSize(width: 1200, height: 750)),
                                           ("1440x932 pt full screen", CGSize(width: 1440, height: 932)),
                                           ("1728x1117 pt full screen", CGSize(width: 1728, height: 1117))]
        for quality in VisualSettings.BloomQuality.allCases {
            let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset), bloomQuality: quality)
            var states: [(String, BackgroundAnimator)] = []
            for (index, _) in BloomRig.destinations.enumerated() {
                for progress in [0.1, 0.25, 0.5, 0.75, 1 - 0.4 / BloomRig.destinations[index].depth] {
                    var animator = diving(index, at: progress, settings)
                    for frame in bright { animator.advance(by: 1 / 30, frame: frame) }
                    states.append((String(format: "dive %d at %.2f", index, progress), animator))
                }
            }
            for (name, points) in windows {
                let size = BackgroundRenderer.drawableSize(points: points, scale: 2, kind: .bloom)
                let field = BackgroundRenderer.bloomFieldSize(width: Int(size.width), height: Int(size.height),
                                                              budget: BackgroundRenderer.bloomFieldBudget(quality))
                var full: [Double] = [], settled: [(String, Double, Int)] = []
                for (label, animator) in states {
                    // A new renderer each time, so each state settles from the full field.
                    guard let renderer = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) else { continue }
                    var cost = renderer.gpuMilliseconds(animator, frames: 20)
                    full.append(cost)
                    for _ in 0..<6 {
                        let share = renderer.targets.bloomShare
                        for _ in 0..<40 { renderer.targets.recordBloomFrame(milliseconds: cost) }
                        if renderer.targets.bloomShare == share { break }
                        cost = renderer.gpuMilliseconds(animator, frames: 20)
                    }
                    settled.append((label, cost, renderer.targets.bloomShare))
                }
                let mean = settled.map(\.1).reduce(0, +) / Double(settled.count)
                let worst = settled.max { $0.1 < $1.1 }!
                let smaller = settled.filter { $0.2 > 0 }.count
                print(String(format: "GPU per frame, %@, Bloom %@ (%dx%d from a %dx%d field): %.2f ms on average, %.2f ms at worst (%@), %.1f%% of the GPU at 30 Hz; %d of %d stretches a step smaller; at the full field always: %.2f on average, %.2f at worst",
                             name, quality.rawValue, Int(size.width), Int(size.height), field.width, field.height, mean, worst.1, worst.0,
                             mean * 3, smaller, settled.count, full.reduce(0, +) / Double(full.count), full.max()!))
                if name.hasPrefix("1440") {
                    print("  " + settled.map { String(format: "%@ %.1f%@", $0.0, $0.1, $0.2 > 0 ? " (step \($0.2))" : "") }.joined(separator: ", "))
                }
            }
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

// MARK: - Bloom proof

extension RenderedFrame {
    /// A `w`×`h` window at (`x`, `y`) of this frame as a screen of `screen`
    /// pixels shows it: Core Animation's linear filter stretches a smaller
    /// drawable over the screen; one the screen's size is shown as it is.
    func shown(on screen: (width: Int, height: Int), x: Int = 0, y: Int = 0, width w: Int, height h: Int) -> RenderedFrame {
        if self.width == screen.width && self.height == screen.height { return crop(x: x, y: y, width: w, height: h) }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let sx = Float(self.width) / Float(screen.width), sy = Float(self.height) / Float(screen.height)
        for row in 0..<h {
            let fy = min(Float(self.height - 1), max(0, (Float(y + row) + 0.5) * sy - 0.5))
            let y0 = Int(fy), y1 = min(self.height - 1, y0 + 1), ty = fy - Float(y0)
            for column in 0..<w {
                let fx = min(Float(self.width - 1), max(0, (Float(x + column) + 0.5) * sx - 0.5))
                let x0 = Int(fx), x1 = min(self.width - 1, x0 + 1), tx = fx - Float(x0)
                for c in 0..<4 {
                    func at(_ x: Int, _ y: Int) -> Float { Float(bytes[(y * self.width + x) * 4 + c]) }
                    let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * tx
                    let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * tx
                    out[(row * w + column) * 4 + c] = UInt8(min(255, max(0, (top + (bottom - top) * ty).rounded())))
                }
            }
        }
        return RenderedFrame(width: w, height: h, bytes: out)
    }
}

extension BackgroundTests {
    /// The moments the before/after proof shows, each after two seconds of
    /// music so most of the field has been carried over, as in the app.
    static let proofMoments: [(name: String, destination: Int, progress: Double)] = [
        ("edge", 0, 0.5), ("dense", 3, 0.75), ("deep", 1, 0.97), ("handoff", 0, 0.94),
    ]
    /// Where each proof moment's 100% crop sits on the screen.
    static let bloomProofCrops: [String: (x: Int, y: Int)] = [
        "edge": (1250, 1080), "dense": (385, 565), "deep": (1855, 392), "handoff": (560, 390),
    ]

    /// Full-screen frames (a 1728×1117 pt window at 2×, as the screen shows
    /// them) of `proofMoments` with 960×600 crops of them at 100%, and four
    /// seconds of the dense one, every frame, cropped alike, under `directory`.
    static func bloomProof(device: MTLDevice, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screen = (width: 3456, height: 2234)
        let size = BackgroundRenderer.drawableSize(points: CGSize(width: 1728, height: 1117), scale: 2, kind: .bloom)
        guard let renderer = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) else { return }
        print("Bloom proof: drawable \(Int(size.width))x\(Int(size.height)) shown on \(screen.width)x\(screen.height)")
        let settings = BackgroundConfiguration(kind: .bloom, colors: Covers.palette(Covers.sunset))
        let music = BloomSong.held(pitch: 7, tonality: 1, loudness: 0.5, mid: 0.4, seconds: 2)
        let crop = (width: 960, height: 600)
        for moment in proofMoments {
            var animator = diving(moment.destination, at: moment.progress, settings)
            var last: RenderedFrame?
            playBloom(&animator, music, renderer: renderer) { _, frame, _ in last = frame }
            guard let last else { continue }
            save(last.shown(on: screen, width: screen.width, height: screen.height).composited(),
                 to: directory.appendingPathComponent("\(moment.name).png"))
            if let at = bloomProofCrops[moment.name] {
                save(last.shown(on: screen, x: at.x, y: at.y, width: crop.width, height: crop.height).composited(),
                     to: directory.appendingPathComponent("\(moment.name)-crop.png"))
            }
        }
        let sequence = directory.appendingPathComponent("dense-sequence")
        try? FileManager.default.createDirectory(at: sequence, withIntermediateDirectories: true)
        let at = bloomProofCrops["dense"] ?? (x: 1248, y: 817)
        var animator = diving(3, at: 0.75, settings)
        var previous: (luma: LumaImage, view: BloomView)?, shimmers: [Float] = []
        playBloom(&animator, music + BloomSong.held(pitch: 7, tonality: 1, loudness: 0.5, mid: 0.4, seconds: 4), renderer: renderer) { animator, frame, i in
            guard i >= 60 else { return }
            let shown = frame.shown(on: screen, x: at.x, y: at.y, width: crop.width, height: crop.height)
            save(shown.composited(), to: sequence.appendingPathComponent(String(format: "frame-%03d.png", i - 60)))
            let luma = LumaImage(shown).blurred(2), view = animator.bloom.views.current
            if let previous {
                shimmers.append(shimmer(previous: previous.luma, current: luma, from: previous.view, to: view, screen: screen, crop: at,
                                        map: i == 150 ? directory.appendingPathComponent("dense-shimmer.png") : nil))
            }
            previous = (luma, view)
        }
        print(String(format: "Bloom proof: dense stretch shimmers %.5f a frame beyond its motion", shimmers.reduce(0, +) / Float(shimmers.count)))
        bloomStabilityChecks(device: device)
    }

    /// How much a frame flickers: the frames before and after it, each moved
    /// to where the dive's views put its points, against twice it, the mean
    /// absolute difference in luma. Steady change, the dive's own motion and
    /// the music's slow swells, cancels out; a pixel that flips cannot.
    static func flicker(_ before: (LumaImage, BloomView), _ now: (LumaImage, BloomView), _ after: (LumaImage, BloomView),
                        screen: (width: Int, height: Int)) -> Float {
        let width = Double(screen.width), height = Double(screen.height), aspect = width / height
        func at(_ image: (LumaImage, BloomView), _ v: Complex) -> Float? {
            let was = (now.1.offset - image.1.offset + now.1.perScreenUnit * v) / image.1.perScreenUnit
            return image.0.sample(Float((was.re / aspect + 1) * width / 2 - 0.5), Float((1 - was.im) * height / 2 - 0.5))
        }
        var sum: Float = 0, count = 0
        for y in 8..<(now.0.height - 8) {
            for x in 8..<(now.0.width - 8) {
                let v = Complex((2 * (Double(x) + 0.5) / width - 1) * aspect, 1 - 2 * (Double(y) + 0.5) / height)
                guard let a = at(before, v), let c = at(after, v) else { continue }
                sum += abs(a + c - 2 * now.0.values[y * now.0.width + x])
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : 0
    }

    /// How much `current` changed from `previous` beyond the dive's own motion:
    /// `previous` moved on to where the change of view from `from` to `to` puts
    /// each of its points, then the mean absolute difference in luma. Both are
    /// `crop`s of a screen of `screen` pixels; blurred a little first, a sharp
    /// filament that only moved doesn't count, one that flickers does.
    static func shimmer(previous: LumaImage, current: LumaImage, from: BloomView, to: BloomView,
                        screen: (width: Int, height: Int), crop: (x: Int, y: Int), map: URL? = nil) -> Float {
        let width = Double(screen.width), height = Double(screen.height), aspect = width / height
        var sum: Float = 0, count = 0
        var residual = [UInt8](repeating: 255, count: current.width * current.height * 4)
        for y in stride(from: 8, to: current.height - 8, by: 1) {
            for x in 8..<(current.width - 8) {
                let v = Complex((2 * (Double(crop.x + x) + 0.5) / width - 1) * aspect, 1 - 2 * (Double(crop.y + y) + 0.5) / height)
                let was = (to.offset - from.offset + to.perScreenUnit * v) / from.perScreenUnit
                let px = (was.re / aspect + 1) * width / 2 - 0.5 - Double(crop.x), py = (1 - was.im) * height / 2 - 0.5 - Double(crop.y)
                guard let before = previous.sample(Float(px), Float(py)) else { continue }
                sum += abs(current.values[y * current.width + x] - before)
                count += 1
                let level = UInt8(min(255, abs(current.values[y * current.width + x] - before) * 2550))
                for c in 0..<3 { residual[(y * current.width + x) * 4 + c] = level }
            }
        }
        if let map { save(RenderedFrame(width: current.width, height: current.height, bytes: residual).composited(), to: map) }
        return count > 0 ? sum / Float(count) : 0
    }
}

/// A frame's luma as numbers, for comparing frames.
struct LumaImage {
    let width: Int
    let height: Int
    var values: [Float]

    init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    init(_ frame: RenderedFrame) {
        var values = [Float](repeating: 0, count: frame.width * frame.height)
        for y in 0..<frame.height { for x in 0..<frame.width { values[y * frame.width + x] = frame.luma(x, y) } }
        self.init(width: frame.width, height: frame.height, values: values)
    }

    /// Box-blurred `radius` pixels each way, twice over: about a Gaussian.
    func blurred(_ radius: Int) -> LumaImage {
        var image = self
        for _ in 0..<2 {
            for horizontal in [true, false] {
                var out = image.values
                for y in 0..<height {
                    for x in 0..<width {
                        var sum: Float = 0
                        for d in -radius...radius {
                            let sx = horizontal ? min(width - 1, max(0, x + d)) : x
                            let sy = horizontal ? y : min(height - 1, max(0, y + d))
                            sum += image.values[sy * width + sx]
                        }
                        out[y * width + x] = sum / Float(2 * radius + 1)
                    }
                }
                image.values = out
            }
        }
        return image
    }

    /// Between pixels' centres, bilinearly; nil off the image.
    func sample(_ x: Float, _ y: Float) -> Float? {
        guard x >= 0, y >= 0, x <= Float(width - 1), y <= Float(height - 1) else { return nil }
        let x0 = min(width - 2, Int(x)), y0 = min(height - 2, Int(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        func at(_ x: Int, _ y: Int) -> Float { values[y * width + x] }
        let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * fx
        let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * fx
        return top + (bottom - top) * fy
    }
}
