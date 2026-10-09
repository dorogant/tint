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
        haloBackLayerFollowsBass()
        visualizerDrawsPublishedFramesOnlyWhileRunning()
        beadEchoDoesNotTintTheFront()
        progressFillsOnlyTheElapsedPart()
        progressRecentersAfterHeightOnlyResize()
        progressThickensAndShowsThumbOnlyUnderPointer()
        progressGlidesOnlyWhilePlaying()
        visualizerCost()
        print("PASS: 11 layer checks (cover orientation, paused swap, ring and bar orientation, halo bass layer, frame delivery, bead overlap, progress fill, resize, hover and glide)")
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

    }

    /// The halo's back layer follows the bass: a bass hit reaches far past the
    /// cover, while an equally loud treble hit stays close to it.
    static func haloBackLayerFollowsBass() {
        func farPixels(bass: Float, treble: Float) -> Int {
            let model = VisualizationModel()
            let levels = (0..<48).map { $0 < 12 ? bass : $0 >= 32 ? treble : 0.1 }
            model.frame = SpectrumFrame(bands: levels, levels: levels, rms: 0.3)
            let view = VisualizerLayerView(model: model)
            let image = render(view, size: CGSize(width: 300, height: 300)) {
                view.configure(style: .halo, sensitivity: 1, color: NSColor(red: 0.2, green: 0.5, blue: 1, alpha: 1),
                               pale: .white, running: false)
            }
            // The cover's radius is 100 here; sample a circle three quarters of the way out.
            return (0..<360).filter { degree in
                let angle = Double(degree) * .pi / 180
                return image.color(at: 150 + Int(cos(angle) * 134), 150 + Int(sin(angle) * 134)).isLit
            }.count
        }
        let bassHit = farPixels(bass: 0.95, treble: 0.1), trebleHit = farPixels(bass: 0.1, treble: 0.95)
        check(bassHit > 40 && trebleHit == 0, "the halo's outer layer must follow the bass (\(bassHit), \(trebleHit))")
    }

    /// Frames reach a visualizer only while it's running and on screen, and
    /// each one published then is drawn. (Pixels can't show this: any layout
    /// pass redraws the current frame, running or not.)
    static func visualizerDrawsPublishedFramesOnlyWhileRunning() {
        let model = VisualizationModel()
        let view = VisualizerLayerView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        view.configure(style: .bars, sensitivity: 1, color: .systemBlue, pale: .white, running: true)
        check(model.listeners.isEmpty, "a visualizer off screen must not take frames")
        window.contentView = view
        check(model.listeners.count == 1, "a running visualizer on screen must take frames")
        let loud = SpectrumFrame(bands: Array(repeating: 0.9, count: 48), levels: Array(repeating: 0.9, count: 48), rms: 0.3)
        let drawn = AllocationCounter.allocations { model.publish(loud) }
        check(drawn > 0, "a published frame must be drawn")
        view.configure(style: .bars, sensitivity: 1, color: .systemBlue, pale: .white, running: false)
        check(model.listeners.isEmpty, "a paused visualizer must not take frames")
        view.configure(style: .bars, sensitivity: 1, color: .systemBlue, pale: .white, running: true)
        window.contentView = nil
        check(model.listeners.isEmpty, "a visualizer leaving the window must stop taking frames")
    }

    static func progressFillsOnlyTheElapsedPart() {
        let view = ProgressTrackView()
        let image = render(view, size: CGSize(width: 400, height: 24)) {
            view.update(progress: 0.5, fill: .systemGreen, glide: false)
        }
        let elapsed = (8..<16).contains { image.color(at: 100, $0).isGreenish }
        let rest = (8..<16).contains { image.color(at: 320, $0).isGreenish }
        let track = (8..<16).contains { image.color(at: 320, $0).isTrack }
        check(elapsed && !rest && track, "the fill must cover the elapsed part only, over a visible track")
    }

    static func beadEchoDoesNotTintTheFront() {
        let size = CGSize(width: 600, height: 84)
        let model = VisualizationModel()
        let levels = (0..<48).map { Float(0.5 + 0.4 * sin(Double($0) * 0.2)) }
        model.frame = SpectrumFrame(bands: levels, levels: levels, rms: 0.3)
        model.flow = 1.3
        let color = NSColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)
        let view = VisualizerLayerView(model: model)
        let actual = render(view, size: size) {
            view.configure(style: .beads, sensitivity: 1, color: color, pale: .white, running: false)
        }
        let frontOnly = VisualizerLayerView(model: model)
        let expected = render(frontOnly, size: size, beforeRender: {
            // Turn off the dim echo, leaving the same front gradient/glow/rim.
            // In an overlap the actual pixels must look exactly like this.
            func hideEcho(in layer: CALayer?) {
                guard let layer else { return }
                if layer is CAGradientLayer && layer.opacity < 0.5 { layer.isHidden = true }
                layer.sublayers?.forEach { hideEcho(in: $0) }
            }
            hideEcho(in: frontOnly.layer)
        }) {
            frontOnly.configure(style: .beads, sensitivity: 1, color: color, pale: .white, running: false)
        }
        let shapes = VisualizerGeometry.beads(size: size, levels: levels.map(CGFloat.init), clock: model.flow)
        let front = shapes.front, back = shapes.echo
        var overlaps = 0, visibleEcho = 0, tintedOverlaps = 0
        for y in stride(from: 5, to: 79, by: 3) {
            for x in stride(from: 5, to: 595, by: 5) {
                let point = CGPoint(x: x, y: y)
                // Ignore the antialias/glow strip along either outline.
                let neighbours = [point, CGPoint(x: x - 4, y: y), CGPoint(x: x + 4, y: y),
                                  CGPoint(x: x, y: y - 4), CGPoint(x: x, y: y + 4)]
                guard neighbours.allSatisfy({ back.contains($0) }) else { continue }
                let a = actual.color(at: x, y), e = expected.color(at: x, y)
                let delta = max(abs(a.r - e.r), abs(a.g - e.g), abs(a.b - e.b))
                if neighbours.allSatisfy({ front.contains($0) }) {
                    overlaps += 1
                    if delta > 0.02 { tintedOverlaps += 1 }
                } else if neighbours.allSatisfy({ !front.contains($0) }), delta > 0.02 {
                    visibleEcho += 1
                }
            }
        }
        check(overlaps > 10 && visibleEcho > 10 && tintedOverlaps == 0,
              "the bead echo must remain visible outside the front without tinting overlaps")
    }

    static func progressRecentersAfterHeightOnlyResize() {
        let resized = ProgressTrackView()
        _ = render(resized, size: CGSize(width: 400, height: 24)) {
            resized.update(progress: 0.5, fill: .systemGreen, glide: false)
        }
        let size = CGSize(width: 400, height: 40)
        let actual = render(resized, size: size) {
            resized.update(progress: 0.5, fill: .systemGreen, glide: false)
        }
        let fresh = ProgressTrackView()
        let expected = render(fresh, size: size) {
            fresh.update(progress: 0.5, fill: .systemGreen, glide: false)
        }
        // Compare real pixels with a fresh view at the final size: the fill,
        // the track and the playhead must all follow the new centre line.
        let columns = [50, 150, 300]
        func rows(_ image: Image) -> [[Int]] {
            columns.map { x in (0..<image.height).filter { image.color(at: x, $0).isTrack } }
        }
        let wanted = rows(expected)
        check(wanted.allSatisfy { !$0.isEmpty } && rows(actual) == wanted,
              "a height-only resize must recenter the progress track")
    }

    /// At rest: a slim track and no thumb. Under the pointer, once the springs
    /// settle, the track is thicker and a white thumb sits on the playhead.
    /// With Reduce Motion the track keeps its size and the thumb still shows.
    static func progressThickensAndShowsThumbOnlyUnderPointer() {
        func look(_ emphasis: ProgressTrackView.Emphasis, still: Bool = false) -> (track: Int, thumb: Int) {
            let view = ProgressTrackView(metrics: .regular)
            let image = render(view, size: CGSize(width: 400, height: 24)) {
                view.update(progress: 0.5, fill: .systemGreen, glide: false, still: still)
                CATransaction.flush()
                view.update(progress: 0.5, fill: .systemGreen, glide: false, emphasis: emphasis, still: still)
                CATransaction.flush()
                // Let the springs settle; CARenderer draws at the current media time.
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            }
            let track = (0..<24).filter { image.color(at: 320, $0).isTrack }.count
            let thumb = (0..<24).filter { image.color(at: 200, $0).paleness > 0.8 }.count
            return (track, thumb)
        }
        let rest = look(.rest), hover = look(.hover), grab = look(.grab), still = look(.hover, still: true)
        check(rest.thumb == 0 && (4...6).contains(rest.track), "at rest the track is slim with no thumb (\(rest))")
        check((7...9).contains(hover.track) && (12...15).contains(hover.thumb),
              "under the pointer the track thickens and the thumb shows (\(hover))")
        check(grab.thumb > hover.thumb, "a held thumb swells (\(grab.thumb) vs \(hover.thumb))")
        check((4...6).contains(still.track) && (12...15).contains(still.thumb),
              "with Reduce Motion the track keeps its size and the thumb still shows (\(still))")
    }

    /// Playing, the playhead glides toward the next tick over a second;
    /// paused (or scrubbing), it lands at once. Half a second into a glide the
    /// fill's end sits between the two playheads.
    static func progressGlidesOnlyWhilePlaying() {
        func fillEnd(glide: Bool) -> Int {
            let view = ProgressTrackView()
            let image = render(view, size: CGSize(width: 400, height: 24)) {
                view.update(progress: 0.5, fill: .systemGreen, glide: false)
                CATransaction.flush()
                // 7.6 pt: under the 8 pt that counts as a seek.
                view.update(progress: 0.519, fill: .systemGreen, glide: glide)
                CATransaction.flush()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            return (0..<400).last { image.color(at: $0, 12).isGreenish } ?? 0
        }
        let gliding = fillEnd(glide: true), landed = fillEnd(glide: false)
        check(landed >= 206 && (201...205).contains(gliding),
              "the playhead must glide while playing and land at once otherwise (\(gliding), \(landed))")
    }

    // MARK: - Cost

    /// The visualizer's main-thread work per analysis frame (30 a second while
    /// playing): building each style's outlines and handing them to Core
    /// Animation, at the sizes Now Playing shows them. Reports time and heap
    /// allocations per frame.
    static func visualizerCost() {
        let model = VisualizationModel()
        let frames = (0..<16).map { n in
            let levels = (0..<48).map { i in Float(0.5 + 0.45 * sin(Double(i) * 0.3 + Double(n) * 0.7)) }
            return SpectrumFrame(bands: levels, levels: levels, rms: 0.3)
        }
        let styles: [(VisualizerLayerView.Style, CGSize)] = [(.radialBars, CGSize(width: 480, height: 480)),
                                                              (.halo, CGSize(width: 480, height: 480)),
                                                              (.bars, CGSize(width: 640, height: 84)),
                                                              (.beads, CGSize(width: 640, height: 84))]
        for (style, size) in styles {
            let view = VisualizerLayerView(model: model)
            let count = 600
            var micros = 0.0, allocations = 0
            // Measured while hosted and running, so frames arrive as they do in the app.
            _ = render(view, size: size) {
                view.configure(style: style, sensitivity: 1.2, color: .systemBlue, pale: .white, running: true)
                var n = 0
                @MainActor func next() {
                    model.publish(frames[n % frames.count])
                    n += 1
                }
                for _ in 0..<60 { next() } // warm up
                allocations = AllocationCounter.allocations { for _ in 0..<count { next() } }
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<count { next() }
                micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / Double(count)
                view.configure(style: style, sensitivity: 1.2, color: .systemBlue, pale: .white, running: false)
            }
            print(String(format: "Visualizer %@ (%dx%d): %.1f µs and %.1f allocations per analysis frame",
                         "\(style)", Int(size.width), Int(size.height), micros, Double(allocations) / Double(count)))
        }
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
        /// The faint track on black, or anything brighter.
        var isTrack: Bool { max(r, g, b) > 0.08 }
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

    static func render(_ view: NSView, size: CGSize, beforeRender: (() -> Void)? = nil,
                       configure: () -> Void) -> Image {
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
        beforeRender?()
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
