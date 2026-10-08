import AppKit
import MetalKit
import SwiftUI

/// Actual Metal submissions from the production renderer. Synthetic colors and
/// spectrum only: this process never starts Floe or reads saved login details.
@main
@MainActor
struct BackgroundTests {
    static let red = RGB(r: 1, g: 0.1, b: 0.1)
    static let green = RGB(r: 0.1, g: 1, b: 0.1)
    static let blue = RGB(r: 0.1, g: 0.1, b: 1)

    static func main() {
        _ = NSApplication.shared
        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("Metal device is required for the background regression check")
        }
        let fixture = Fixture(device: device)
        defer { fixture.renderer.stop(); fixture.window.close() }

        fixture.renderer.update(running: false, color: red, reactivity: 1)
        waitUntil("the first paused frame must complete") { fixture.status.backgroundFramesDrawn == 1 }
        let initialPixel = fixture.pixel()
        check(initialPixel.red > initialPixel.green, "the initial paused frame must use the requested color")
        settle()
        let initialDraws = fixture.view.drawAttempts
        for _ in 0..<5 { fixture.renderer.update(running: false, color: red, reactivity: 1) }
        settle()
        check(fixture.status.backgroundFramesDrawn == 1 && fixture.view.drawAttempts == initialDraws,
              "unchanged paused configuration must neither redraw nor start a timer")

        fixture.renderer.update(running: false, color: green, reactivity: 1)
        waitUntil("a paused color change must complete") { fixture.status.backgroundFramesDrawn == 2 }
        let greenPixel = fixture.pixel()
        check(greenPixel.green > greenPixel.red && greenPixel.green > greenPixel.blue,
              "a paused color change must reach the real GPU texture")
        fixture.renderer.update(running: false, color: green, reactivity: 1.5)
        waitUntil("a paused reactivity change must complete") { fixture.status.backgroundFramesDrawn == 3 }
        settle()
        check(fixture.status.backgroundFramesDrawn == 3, "paused setting changes must draw once")

        // No run-loop turn occurs between these updates. The first submission
        // sets busy synchronously, so the later colors arrive while it is in flight.
        let beforeBurst = fixture.status.backgroundFramesDrawn
        fixture.renderer.update(running: false, color: red, reactivity: 1)
        fixture.renderer.update(running: false, color: green, reactivity: 1.2)
        fixture.renderer.update(running: false, color: blue, reactivity: 1.7)
        waitUntil("in-flight paused updates must get a replacement frame") {
            fixture.status.backgroundFramesDrawn == beforeBurst + 2
        }
        settle()
        let bluePixel = fixture.pixel()
        check(bluePixel.blue > bluePixel.red && bluePixel.blue > bluePixel.green,
              "the newest in-flight color must survive, rather than leaving the first color displayed")
        check(fixture.status.backgroundFramesDrawn == beforeBurst + 2,
              "multiple in-flight paused changes must coalesce into one replacement")

        let beforeMotion = fixture.status.backgroundFramesDrawn
        fixture.status.frame = SpectrumFrame(bands: [Float](repeating: 0.5, count: 48),
                                             levels: [Float](repeating: 0.5, count: 48), rms: 0.2)
        fixture.renderer.update(running: true, color: blue, reactivity: 1.7)
        waitUntil("a running background must submit repeated frames") {
            fixture.status.backgroundFramesDrawn >= beforeMotion + 4
        }
        fixture.renderer.update(running: false, color: blue, reactivity: 1.7)
        settle() // an already submitted command may finish after the pause
        let pausedFrames = fixture.status.backgroundFramesDrawn
        let pausedDraws = fixture.view.drawAttempts
        settle()
        check(fixture.status.backgroundFramesDrawn == pausedFrames && fixture.view.drawAttempts == pausedDraws,
              "running-to-paused must stop repeated GPU submissions")
        check(fixture.status.backgroundFailure == nil, "all GPU commands must complete successfully")
        pausedSwiftUIResize()
        print("PASS: 7 Metal background checks (first paused draw, idle, color, reactivity, queued changes, pause and resize)")
    }

    static func pausedSwiftUIResize() {
        let status = VisualizationModel()
        let host = NSHostingView(rootView: ReactiveBackground().environment(status).environment(VisualSettings()))
        let bounds = CGRect(x: 0, y: 0, width: 512, height: 320)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.close() }
        window.contentView = host
        window.displayIfNeeded()
        waitUntil("the SwiftUI-hosted paused background must render") { status.backgroundFramesDrawn > 0 }
        settle()
        let beforeResize = status.backgroundFramesDrawn
        window.setContentSize(CGSize(width: 512, height: 512))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        waitUntil("resizing a paused SwiftUI-hosted background must refresh its Metal frame") {
            status.backgroundFramesDrawn > beforeResize
        }
        guard let view = metalView(in: host) else { fail("the SwiftUI host must contain its production Metal view") }
        check(view.drawableSize == CGSize(width: 512, height: 512), "the paused resize must use the new aspect ratio")
        settle()
        let settledFrames = status.backgroundFramesDrawn
        settle()
        check(status.backgroundFramesDrawn == settledFrames && status.backgroundFailure == nil,
              "a paused resize must finish successfully without continuous redraw")
    }

    static func metalView(in root: NSView) -> MTKView? {
        if let metal = root as? MTKView { return metal }
        return root.subviews.lazy.compactMap { metalView(in: $0) }.first
    }

    static func settle() { pump(for: 0.2) }

    static func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    static func waitUntil(_ message: String, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { pump(for: 0.01) }
        check(condition(), message)
    }

    static func check(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
    }

    final class TrackingMetalView: MTKView {
        var drawAttempts = 0
        var lastTexture: MTLTexture?
        override func draw() {
            drawAttempts += 1
            lastTexture = currentDrawable?.texture
            super.draw()
        }
    }

    @MainActor final class Fixture {
        let window: NSWindow
        let view: TrackingMetalView
        let status = VisualizationModel()
        let renderer: BackgroundRenderer
        private let copyQueue: MTLCommandQueue

        init(device: MTLDevice) {
            let bounds = CGRect(x: 0, y: 0, width: 512, height: 320)
            view = TrackingMetalView(frame: bounds, device: device)
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            view.autoResizeDrawable = false
            view.drawableSize = bounds.size
            view.colorPixelFormat = .bgra8Unorm
            // Readback is test-only; Floe's view keeps framebufferOnly enabled.
            view.framebufferOnly = false
            window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.displayIfNeeded()
            do { renderer = try BackgroundRenderer(view: view, status: status) }
            catch { fail("cannot create the production background pipeline: \(error)") }
            view.delegate = renderer
            guard let queue = device.makeCommandQueue() else { fail("cannot create texture readback queue") }
            copyQueue = queue
        }

        func pixel() -> (red: UInt8, green: UInt8, blue: UInt8) {
            guard let texture = view.lastTexture,
                  let device = view.device,
                  let buffer = device.makeBuffer(length: 256, options: .storageModeShared),
                  let command = copyQueue.makeCommandBuffer(),
                  let blit = command.makeBlitCommandEncoder() else { fail("cannot read the completed GPU texture") }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: texture.width / 2, y: texture.height / 2, z: 0),
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                      to: buffer, destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            check(command.status == .completed, "texture readback must complete")
            let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
            return (red: bytes[2], green: bytes[1], blue: bytes[0])
        }
    }
}
