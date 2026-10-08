import AppKit
import Metal
import QuartzCore

/// Renders the Core Animation views offscreen with CARenderer (window snapshots
/// ignore masks) inside a top-down parent, as SwiftUI hosts them, and checks
/// pixels: orientation, gradients, masks and paused updates.
@main
@MainActor
struct LayerTests {
    static func main() {
        _ = NSApplication.shared
        coverIsUprightAndSwapsWhilePaused()
        visualizerIsUpright()
        waveFillsOnlyTheElapsedPart()
        print("PASS: 6 layer checks (cover orientation, paused swap, ring and bar orientation, halo gradient, wave clip)")
    }

    // MARK: - Checks

    static func coverIsUprightAndSwapsWhilePaused() {
        let view = CrawlingCoverView()
        let image = render(view, size: CGSize(width: 200, height: 200)) {
            view.update(image: halves(top: .red, bottom: .blue), rim: .white, rimWidth: 3, running: false, fade: false)
        }
        check(image.color(at: 100, 50).isRed && image.color(at: 100, 150).isBlue, "cover must be upright")

        let swapped = render(view, size: CGSize(width: 200, height: 200)) {
            view.update(image: halves(top: .red, bottom: .blue), rim: .white, rimWidth: 3, running: true, fade: true)
            CATransaction.flush()
            view.update(image: halves(top: .green, bottom: .green), rim: .white, rimWidth: 3, running: false, fade: true)
        }
        check(swapped.color(at: 100, 100).isGreen, "a cover changed while paused must show at once")
    }

    static func visualizerIsUpright() {
        let model = VisualizationModel()
        // Strong bass, weak treble.
        let levels = (0..<48).map { max(0.05, 0.95 - Float($0) * 0.019) }
        model.frame = SpectrumFrame(bands: levels, levels: levels, rms: 0.3)
        let blue = NSColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)

        let ring = VisualizerLayerView(model: model)
        let radial = render(ring, size: CGSize(width: 300, height: 300)) {
            ring.configure(style: .radialBars, sensitivity: 1, color: blue, pale: .white, running: false)
        }
        // Bass reaches nearer the top edge than treble reaches the bottom edge.
        // Scan a band of columns, since the centre line falls between two bars.
        func lit(_ y: Int) -> Bool { (140...160).contains { radial.color(at: $0, y).isLit } }
        let top = (0..<150).first { lit($0) } ?? 150
        let bottom = (0..<150).first { lit(299 - $0) } ?? 150
        check(top + 10 < bottom, "bass must sit at the top of the ring")

        let strip = VisualizerLayerView(model: model)
        let bars = render(strip, size: CGSize(width: 600, height: 80)) {
            strip.configure(style: .bars, sensitivity: 1, color: blue, pale: .white, running: false)
        }
        // Loud bass bars reach the floor in the middle; quiet treble at the ends leaves the top empty.
        let floor = (290...310).contains { bars.color(at: $0, 76).isLit }
        let ceiling = (0...20).contains { bars.color(at: $0, 4).isLit }
        check(floor && !ceiling, "bars must stand on the bottom")

        let halo = VisualizerLayerView(model: model)
        let filled = render(halo, size: CGSize(width: 300, height: 300)) {
            halo.configure(style: .halo, sensitivity: 1, color: blue, pale: .white, running: false)
        }
        let upper = filled.color(at: 150, 60), lower = filled.color(at: 150, 240)
        check(upper.isLit && lower.isLit && upper.paleness > lower.paleness + 0.1, "halo must be pale on top")
    }

    static func waveFillsOnlyTheElapsedPart() {
        let view = WavyProgressView()
        let image = render(view, size: CGSize(width: 400, height: 24)) {
            view.update(progress: 0.5, color: .systemGreen, moving: false, glide: false)
        }
        let elapsed = (8..<16).contains { image.color(at: 100, $0).isGreenish }
        let rest = (8..<16).contains { image.color(at: 320, $0).isGreenish }
        check(elapsed && !rest, "the wave must fill the elapsed part only")
    }

    /// Optimized builds drop `precondition` messages, so say what failed.
    static func check(_ condition: Bool, _ message: String) {
        guard !condition else { return }
        print("FAIL: \(message)")
        exit(1)
    }

    // MARK: - Rendering

    struct Pixel {
        let r: Double, g: Double, b: Double
        var isLit: Bool { max(r, g, b) > 0.35 }
        var isRed: Bool { r > 0.6 && g < 0.4 && b < 0.4 }
        var isBlue: Bool { b > 0.6 && r < 0.4 && g < 0.4 }
        var isGreen: Bool { g > 0.6 && r < 0.4 && b < 0.4 }
        var isGreenish: Bool { g > 0.45 && g > r + 0.15 && g > b }
        var paleness: Double { min(r, g, b) }
    }

    struct Image {
        let width: Int, height: Int, bytes: [UInt8]
        /// Top-down screen coordinates.
        func color(at x: Int, _ y: Int) -> Pixel {
            let row = height - 1 - y // the texture's first row is the layer's bottom
            let i = (row * width + x) * 4
            return Pixel(r: Double(bytes[i + 2]) / 255, g: Double(bytes[i + 1]) / 255, b: Double(bytes[i]) / 255)
        }
    }

    /// A flipped parent in a window, like SwiftUI's host; AppKit sets the layer flips.
    final class TopDown: NSView {
        override var isFlipped: Bool { true }
    }

    static func render(_ view: NSView, size: CGSize, configure: () -> Void) -> Image {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let parent = TopDown(frame: CGRect(origin: .zero, size: size))
        parent.wantsLayer = true
        window.contentView = parent
        view.removeFromSuperview()
        view.frame = parent.bounds
        parent.addSubview(view)
        parent.layoutSubtreeIfNeeded()
        window.displayIfNeeded() // lets AppKit set up the backing layers
        configure()
        view.layout()
        // Rebuild the flips AppKit set: an unflipped root, the parent, then the view.
        let root = CALayer()
        root.frame = parent.bounds
        root.isGeometryFlipped = parent.layer!.isGeometryFlipped
        root.backgroundColor = NSColor.black.cgColor
        let layer = view.layer!
        layer.removeFromSuperlayer()
        layer.frame = root.bounds
        root.addSublayer(layer)

        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width),
                                                                  height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue])
        renderer.layer = root
        renderer.bounds = root.bounds
        CATransaction.flush() // CARenderer draws only committed layer state
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        // Copy the private render target into a CPU-readable buffer on the same queue.
        let rowBytes = texture.width * 4
        let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared)!
        let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                  destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let bytes = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self),
                                              count: buffer.length))
        // Put the layer back so a later render of the same view can reuse it.
        layer.removeFromSuperlayer()
        return Image(width: texture.width, height: texture.height, bytes: bytes)
    }

    static func halves(top: NSColor, bottom: NSColor) -> CGImage {
        let context = CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(bottom.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 25)) // Core Graphics is bottom-up
        context.setFillColor(top.cgColor)
        context.fill(CGRect(x: 0, y: 25, width: 50, height: 25))
        return context.makeImage()!
    }
}
