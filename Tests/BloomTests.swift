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
    static func held(pitch: Float, tonality: Float, loudness: Float = 0.4, seconds: Float) -> [SpectrumFrame] {
        var layers = MusicLayers()
        layers.pitchClass = pitch
        layers.tonality = tonality
        layers.mid = 0.3
        layers.bass = 0.2
        let bands = [Float](repeating: loudness, count: 48)
        return Array(repeating: SpectrumFrame(bands: bands, levels: bands, rms: loudness * 0.3, layers: layers), count: Int(seconds * 30))
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
        var shattered: RenderedFrame?
        playBloom(&kicked, hit, renderer: renderer) { animator, frame, i in
            apart.append(frame.difference(from: twinFrames[i]))
            if i >= 60 { lumaRatio.append(frame.meanLuma / max(0.001, twinFrames[i].meanLuma)) }
            if i == 64 { shattered = frame }
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
        _ = shattered
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
        print("Bloom renders: \(directory.path)/shapes.png, song-sheet.png and song/frame-000…\(frames.count - 1).png")
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
