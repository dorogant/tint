import CoreText
import ImageIO
import MetalKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// The production Metal renderer with synthetic analysis and no auth/audio core.
@MainActor @Observable final class VisualizationModel {
    var backgroundFailure: String?
    var backgroundFramesDrawn: UInt64 = 0
    var frame = SpectrumFrame.quiet { didSet { unread = frame } }
    var isRunning = false
    @ObservationIgnored private var unread: SpectrumFrame?
    func takeFrame() -> SpectrumFrame? {
        defer { unread = nil }
        return unread
    }
}

enum L10n { static func string(_ text: String) -> String { text } }

/// Deterministic, so test renders repeat exactly.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
}

/// Noise for the synthetic drums, shaped like real ones: a snare's rattle has
/// little bass, and hats (+12 dB an octave) almost nothing below 3 kHz.
struct DrumNoise {
    private var random = SeededRandom(seed: 11)
    private var a: Float = 0, b: Float = 0
    private var c: Float = 0
    /// A snare's rattle: noise tilted up 6 dB an octave, so little of it reaches the bass.
    mutating func rattle() -> Float {
        let x = random.next() * 2 - 1
        defer { c = x }
        return (x - c) * 0.7
    }
    mutating func hiss() -> Float {
        let x = random.next() * 2 - 1
        defer { b = a; a = x }
        return (x - 2 * a + b) * 0.5
    }
}

/// Synthetic music at 44.1 kHz, so the detectors see real analyzer frames:
/// pitch-swept kicks on every beat, a sine bassline, a soft chord, hats on the
/// sixteenths, a snare on two and four and a sung vowel with vibrato.
struct SyntheticTrack {
    var kicksPerSecond: Float = 2
    var kick: Float = 0
    var bass: Float = 0
    var pad: Float = 0
    var hats: Float = 0
    var snare: Float = 0
    var vocal: Float = 0
    /// Seconds before the first kick (and the grid the other drums follow).
    var kickOffset: Float = 0.25
    /// Master gain, and whether the master then clips softly like a loud mastered track.
    var gain: Float = 1
    var clip = false

    func scaled(_ gain: Float, clip: Bool = false) -> SyntheticTrack {
        var track = self
        track.gain = gain
        track.clip = clip
        return track
    }

    func sample(at t: Float, noise: inout DrumNoise) -> Float {
        let beat = 1 / kicksPerSecond
        var value = pad * (sinf(2 * .pi * 220 * t) + sinf(2 * .pi * 277.2 * t) + sinf(2 * .pi * 329.6 * t)) / 3
        value += bass * sinf(2 * .pi * 55 * t)
        if kick > 0, t >= kickOffset {
            let since = (t - kickOffset).truncatingRemainder(dividingBy: beat)
            // f(τ) = 50 + 100·e^(−τ/0.03), integrated for the phase.
            let phase = 2 * .pi * (50 * since + 3 * (1 - expf(-since / 0.03)))
            value += kick * sinf(phase) * expf(-since / 0.1)
        }
        if hats > 0 {
            let since = t.truncatingRemainder(dividingBy: 0.125)
            value += hats * noise.hiss() * expf(-since / 0.02)
        }
        if snare > 0, t >= kickOffset + beat {
            let since = (t - kickOffset - beat).truncatingRemainder(dividingBy: 2 * beat)
            // A 2 ms attack, as a stick hits: an instant one splatters into the bass.
            let attack = min(1, since / 0.002)
            value += snare * attack * (noise.rattle() + 0.3 * sinf(2 * .pi * 200 * since)) * expf(-since / 0.06)
        }
        if vocal > 0 {
            // 440 Hz with a ±8 Hz, 5 Hz vibrato, sung in 1.3 Hz syllables.
            let phase = 2 * .pi * 440 * t - 8 / 5 * cosf(2 * .pi * 5 * t)
            let syllable = 0.5 + 0.5 * sinf(2 * .pi * 1.3 * t)
            value += vocal * syllable * (sinf(phase) + 0.5 * sinf(2 * phase) + 0.3 * sinf(3 * phase)) / 1.8
        }
        return clip ? tanhf(value * gain) : value * gain
    }

    /// One analysis frame per 30 Hz tick, as Floe's worker produces them.
    static func frames(_ sections: [(SyntheticTrack, Float)], analyzer: SpectrumAnalyzer = SpectrumAnalyzer()!) -> [SpectrumFrame] {
        let block = Int(SpectrumAnalyzer.sampleRate / 30)
        var noise = DrumNoise()
        var frames: [SpectrumFrame] = []
        var start = 0
        for (track, seconds) in sections {
            let count = Int(seconds * 30)
            for _ in 0..<count {
                let samples = (0..<block).map { track.sample(at: Float(start + $0) / SpectrumAnalyzer.sampleRate, noise: &noise) }
                frames.append(analyzer.process(left: samples, right: samples, count: block))
                start += block
            }
        }
        return frames
    }
}

/// A rendered frame: premultiplied BGRA bytes straight from the shader.
struct RenderedFrame {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// Rec. 709 luma of the encoded values, as the shaders limit it.
    func luma(_ x: Int, _ y: Int) -> Float {
        let i = (y * width + x) * 4
        return (0.0722 * Float(bytes[i]) + 0.7152 * Float(bytes[i + 1]) + 0.2126 * Float(bytes[i + 2])) / 255
    }
    var meanLuma: Float { summary(of: { luma($0, $1) }).mean }
    var maxLuma: Float { summary(of: { luma($0, $1) }).max }
    /// The share of pixels brighter than `limit`.
    func share(above limit: Float) -> Float {
        var count = 0
        for y in 0..<height { for x in 0..<width where luma(x, y) > limit { count += 1 } }
        return Float(count) / Float(width * height)
    }
    private static let linear: [Float] = (0..<256).map {
        let x = Float($0) / 255
        return x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance (over black), averaged over each cell of a grid, row by row.
    func relativeLuminance(columns: Int, rows: Int) -> [Float] {
        var sums = [Float](repeating: 0, count: columns * rows)
        for y in 0..<height {
            let row = y * rows / height
            for x in 0..<width {
                let i = (y * width + x) * 4
                sums[row * columns + x * columns / width] += 0.0722 * Self.linear[Int(bytes[i])]
                    + 0.7152 * Self.linear[Int(bytes[i + 1])] + 0.2126 * Self.linear[Int(bytes[i + 2])]
            }
        }
        return sums.map { $0 / Float(width * height / (columns * rows)) }
    }
    /// Mean absolute difference per channel, 0…1.
    func difference(from other: RenderedFrame) -> Float {
        var sum = 0
        for i in bytes.indices where i % 4 != 3 { sum += abs(Int(bytes[i]) - Int(other.bytes[i])) }
        return Float(sum) / Float(width * height * 3) / 255
    }
    /// Mean colour of the frame, 0…1 RGB.
    var meanColor: SIMD3<Float> {
        var sum = SIMD3<Float>.zero
        for i in stride(from: 0, to: bytes.count, by: 4) {
            sum += SIMD3(Float(bytes[i + 2]), Float(bytes[i + 1]), Float(bytes[i]))
        }
        return sum / Float(width * height) / 255
    }

    /// A rectangle of the frame, at 100%.
    func crop(x: Int, y: Int, width w: Int, height h: Int) -> RenderedFrame {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let source = ((y + row) * width + x) * 4
            out.replaceSubrange(row * w * 4..<(row + 1) * w * 4, with: bytes[source..<source + w * 4])
        }
        return RenderedFrame(width: w, height: h, bytes: out)
    }

    /// The frame scaled about its centre by `factor` (above 1 zooms in), bilinear.
    func zoomed(_ factor: Float) -> RenderedFrame {
        var out = [UInt8](repeating: 0, count: bytes.count)
        let cx = Float(width) / 2, cy = Float(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                let sx = min(Float(width - 1), max(0, cx + (Float(x) + 0.5 - cx) / factor - 0.5))
                let sy = min(Float(height - 1), max(0, cy + (Float(y) + 0.5 - cy) / factor - 0.5))
                let x0 = Int(sx), y0 = Int(sy), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
                let fx = sx - Float(x0), fy = sy - Float(y0)
                for c in 0..<4 {
                    func at(_ x: Int, _ y: Int) -> Float { Float(bytes[(y * width + x) * 4 + c]) }
                    let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * fx
                    let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * fx
                    out[(y * width + x) * 4 + c] = UInt8(min(255, max(0, (top + (bottom - top) * fy).rounded())))
                }
            }
        }
        return RenderedFrame(width: width, height: height, bytes: out)
    }

    /// Mean luma over a rectangle.
    func meanLuma(x: Int, y: Int, width w: Int, height h: Int) -> Float {
        var sum: Float = 0
        for row in y..<min(height, y + h) { for column in x..<min(width, x + w) { sum += luma(column, row) } }
        return sum / Float(w * h)
    }

    private func summary(of value: (Int, Int) -> Float) -> (mean: Float, max: Float) {
        var sum: Float = 0, peak: Float = 0
        for y in 0..<height { for x in 0..<width { let v = value(x, y); sum += v; peak = max(peak, v) } }
        return (sum / Float(width * height), peak)
    }

    /// Roughly what the window shows: over the dark base, under the 28% scrim.
    func composited() -> CGImage {
        var out = [UInt8](repeating: 255, count: bytes.count)
        let base: [Float] = [0.06, 0.05, 0.045] // BGR of Theme.base
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Float(bytes[i + 3]) / 255
            for c in 0..<3 {
                let value = (Float(bytes[i + c]) / 255 + base[c] * (1 - alpha)) * 0.72
                out[i + c] = UInt8(min(255, max(0, value * 255)))
            }
            out[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(out) as CFData)!
        // Rows were read top-down from the texture, which is already upright.
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// Renders the production pipelines into a texture the test can read back.
@MainActor final class OffscreenRenderer {
    let width: Int
    let height: Int
    private let queue: MTLCommandQueue
    private let pipelines: BackgroundRenderer.Pipelines
    private let targets: BackgroundRenderer.Targets
    private let texture: MTLTexture
    private let buffer: MTLBuffer

    init(device: MTLDevice, width: Int = 512, height: Int = 336) throws {
        self.width = width
        self.height = height
        queue = device.makeCommandQueue()!
        pipelines = try BackgroundRenderer.makePipelines(device: device, pixelFormat: .bgra8Unorm)
        targets = BackgroundRenderer.Targets(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        texture = device.makeTexture(descriptor: descriptor)!
        buffer = device.makeBuffer(length: width * height * 4, options: .storageModeShared)!
    }

    func render(_ animator: BackgroundAnimator) -> RenderedFrame {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        let command = queue.makeCommandBuffer()!
        BackgroundRenderer.encode(command, pass: pass, pipelines: pipelines, targets: targets, animator: animator,
                                  width: Float(width), height: Float(height))
        let blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        precondition(command.status == .completed, "offscreen render must complete")
        let pointer = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return RenderedFrame(width: width, height: height, bytes: Array(UnsafeBufferPointer(start: pointer, count: width * height * 4)))
    }

    /// GPU time per frame in milliseconds while drawing continuously: frames
    /// submitted back to back (as a running display does, so the GPU is at its
    /// working clock), from the first one's start to the last one's end.
    func gpuMilliseconds(_ animator: BackgroundAnimator, frames: Int = 120) -> Double {
        func run(_ count: Int) -> Double {
            var buffers: [MTLCommandBuffer] = []
            for _ in 0..<count {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                let command = queue.makeCommandBuffer()!
                BackgroundRenderer.encode(command, pass: pass, pipelines: pipelines, targets: targets, animator: animator,
                                          width: Float(width), height: Float(height))
                command.commit()
                buffers.append(command)
            }
            buffers.last!.waitUntilCompleted()
            return (buffers.last!.gpuEndTime - buffers.first!.gpuStartTime) * 1000 / Double(count)
        }
        _ = run(30)
        return run(frames)
    }
}

/// Writes preview PNGs, and a contact sheet per kind, when a directory is given.
enum Previews {
    static let directory = ProcessInfo.processInfo.environment["FLOE_BACKGROUND_PREVIEWS"].map { URL(fileURLWithPath: $0) }
    nonisolated(unsafe) static var written: [String] = []

    static func write(_ frame: RenderedFrame, _ name: String) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        save(frame.composited(), to: url)
        written.append(url.path + String(format: "  (luma mean %.3f, peak %.3f)", frame.meanLuma, frame.maxLuma))
    }

    /// Rows of labelled thumbnails, one image per kind to look at.
    static func sheet(_ rows: [[RenderedFrame]], _ name: String, scale: CGFloat = 0.5) {
        guard let directory, let first = rows.first?.first else { return }
        let cellW = Int(CGFloat(first.width) * scale), cellH = Int(CGFloat(first.height) * scale)
        let columns = rows.map(\.count).max() ?? 1
        let gap = 4
        let width = columns * (cellW + gap) + gap, height = rows.count * (cellH + gap) + gap
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (r, row) in rows.enumerated() {
            for (c, frame) in row.enumerated() {
                let rect = CGRect(x: gap + c * (cellW + gap), y: height - (r + 1) * (cellH + gap), width: cellW, height: cellH)
                context.draw(frame.composited(), in: rect)
            }
        }
        guard let image = context.makeImage() else { return }
        let url = directory.appendingPathComponent("\(name).png")
        save(image, to: url)
        written.append(url.path)
    }

    /// A frame blown up so its pixels can be judged: `smooth` filters like Core
    /// Animation stretching a drawable over the window, otherwise every pixel is a block.
    static func zoom(_ frame: RenderedFrame, _ name: String, scale: CGFloat, smooth: Bool) {
        guard let directory else { return }
        let width = Int(CGFloat(frame.width) * scale), height = Int(CGFloat(frame.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = smooth ? .medium : .none
        context.draw(frame.composited(), in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return }
        let url = directory.appendingPathComponent("\(name).png")
        save(image, to: url)
        written.append(url.path)
    }

    /// Labelled thumbnails in rows of `columns`; a coloured bar under a cell marks
    /// what happened in the music on that frame.
    static func strip(_ cells: [(frame: RenderedFrame, label: String, mark: CGColor?)], _ name: String,
                      columns: Int, scale: CGFloat) {
        guard let directory, let first = cells.first?.frame else { return }
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
        guard let image = context.makeImage() else { return }
        let url = directory.appendingPathComponent("\(name).png")
        save(image, to: url)
        written.append(url.path)
    }

    private static func save(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// Small synthetic covers for the palette extractor.
enum Covers {
    static func image(_ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    /// Horizontal bands of the given colours, top first, sized by weight.
    static func bands(_ colors: [(RGB, Int)]) -> CGImage {
        image { context in
            let total = colors.map(\.1).reduce(0, +)
            var y = 96
            for (color, weight) in colors {
                let height = 96 * weight / total
                context.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
                context.fill(CGRect(x: 0, y: y - height, width: 96, height: height))
                y -= height
            }
        }
    }

    static let sunset = bands([(RGB(r: 0.98, g: 0.55, b: 0.18), 3), (RGB(r: 0.9, g: 0.2, b: 0.45), 3),
                               (RGB(r: 0.45, g: 0.15, b: 0.6), 3), (RGB(r: 0.08, g: 0.05, b: 0.12), 4)])
    static let ocean = bands([(RGB(r: 0.1, g: 0.75, b: 0.8), 3), (RGB(r: 0.1, g: 0.3, b: 0.85), 3),
                              (RGB(r: 0.3, g: 0.85, b: 0.45), 2), (RGB(r: 0.03, g: 0.08, b: 0.15), 4)])
    static let navy = bands([(RGB(r: 0.05, g: 0.1, b: 0.35), 6), (RGB(r: 0.02, g: 0.03, b: 0.08), 2)])
    static let grey = bands([(RGB(r: 0.5, g: 0.5, b: 0.5), 1), (RGB(r: 0.9, g: 0.9, b: 0.9), 1), (RGB(r: 0.1, g: 0.1, b: 0.1), 1)])

    static func palette(_ image: CGImage) -> [RGB] {
        CoverColorExtractor.palette(of: image, accent: CoverColorExtractor.extract(of: image) ?? .fallback)
    }
}
