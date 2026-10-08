import ImageIO
import MetalKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// The production Metal renderer with synthetic analysis and no auth/audio core.
@MainActor @Observable final class VisualizationModel {
    var backgroundFailure: String?
    var backgroundFramesDrawn: UInt64 = 0
    var frame = SpectrumFrame.quiet
    var isRunning = false
}

enum L10n { static func string(_ text: String) -> String { text } }

/// Synthetic music at 44.1 kHz, so the detector sees real analyzer frames:
/// pitch-swept kicks, a sine bassline, a soft chord and noise hats.
struct SyntheticTrack {
    var kicksPerSecond: Float = 2
    var kick: Float = 0
    var bass: Float = 0
    var pad: Float = 0
    var hats: Float = 0
    /// Seconds before the first kick.
    var kickOffset: Float = 0.25

    func sample(at t: Float, noise: inout SeededRandom) -> Float {
        var value = pad * (sinf(2 * .pi * 220 * t) + sinf(2 * .pi * 277.2 * t) + sinf(2 * .pi * 329.6 * t)) / 3
        value += bass * sinf(2 * .pi * 55 * t)
        if kick > 0, t >= kickOffset {
            let since = (t - kickOffset).truncatingRemainder(dividingBy: 1 / kicksPerSecond)
            // f(τ) = 50 + 100·e^(−τ/0.03), integrated for the phase.
            let phase = 2 * .pi * (50 * since + 3 * (1 - expf(-since / 0.03)))
            value += kick * sinf(phase) * expf(-since / 0.15)
        }
        if hats > 0 {
            let since = t.truncatingRemainder(dividingBy: 0.125)
            value += hats * (noise.next() * 2 - 1) * expf(-since / 0.015)
        }
        return value
    }

    /// One analysis frame per 30 Hz tick, as Floe's worker produces them.
    static func frames(_ sections: [(SyntheticTrack, Float)], analyzer: SpectrumAnalyzer = SpectrumAnalyzer()!) -> [SpectrumFrame] {
        let block = Int(SpectrumAnalyzer.sampleRate / 30)
        var noise = SeededRandom(seed: 11)
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
    private let texture: MTLTexture
    private let buffer: MTLBuffer

    init(device: MTLDevice, width: Int = 512, height: Int = 336) throws {
        self.width = width
        self.height = height
        queue = device.makeCommandQueue()!
        pipelines = try BackgroundRenderer.makePipelines(device: device, pixelFormat: .bgra8Unorm)
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
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        BackgroundRenderer.encode(encoder, pipelines: pipelines, animator: animator, width: Float(width), height: Float(height))
        encoder.endEncoding()
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
