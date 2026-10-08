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
    /// The brightest a pixel may get (Rec. 709 luma of the premultiplied output).
    /// Under the window's 28% scrim that's ≤ 0.43, so white text keeps ≥ 4.5:1.
    static let legibleLuma: Float = 0.6
    static var checks = 0

    static func main() {
        _ = NSApplication.shared
        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("Metal device is required for the background regression check")
        }
        rendererChecks(device: device)
        pausedSwiftUIResize()
        paletteChecks()
        settingsChecks()
        detectorChecks()
        fluidChecks(device: device)
        print("PASS: \(checks) background checks (renderer, palette, settings, beats, Fluid)")
        if !Previews.written.isEmpty { print("Previews:\n" + Previews.written.joined(separator: "\n")) }
    }

    static func configuration(_ color: RGB, reactivity: Float = 1,
                              kind: VisualSettings.BackgroundKind = .fluid) -> BackgroundConfiguration {
        BackgroundConfiguration(kind: kind, colors: [color], reactivity: reactivity)
    }

    // MARK: - Renderer

    static func rendererChecks(device: MTLDevice) {
        let fixture = Fixture(device: device)
        defer { fixture.renderer.stop(); fixture.window.close() }

        fixture.renderer.update(running: false, configuration: configuration(red))
        waitUntil("the first paused frame must complete") { fixture.status.backgroundFramesDrawn == 1 }
        let initialPixel = fixture.pixel()
        check(initialPixel.red > initialPixel.green, "the initial paused frame must use the requested color")
        settle()
        let initialDraws = fixture.view.drawAttempts
        for _ in 0..<5 { fixture.renderer.update(running: false, configuration: configuration(red)) }
        settle()
        check(fixture.status.backgroundFramesDrawn == 1 && fixture.view.drawAttempts == initialDraws,
              "unchanged paused configuration must neither redraw nor start a timer")

        fixture.renderer.update(running: false, configuration: configuration(green))
        waitUntil("a paused color change must complete") { fixture.status.backgroundFramesDrawn == 2 }
        let greenPixel = fixture.pixel()
        check(greenPixel.green > greenPixel.red && greenPixel.green > greenPixel.blue,
              "a paused color change must reach the real GPU texture at once, without a crossfade")
        fixture.renderer.update(running: false, configuration: configuration(green, reactivity: 1.5))
        waitUntil("a paused reactivity change must complete") { fixture.status.backgroundFramesDrawn == 3 }
        settle()
        check(fixture.status.backgroundFramesDrawn == 3, "paused setting changes must draw once")

        // No run-loop turn occurs between these updates. The first submission
        // sets busy synchronously, so the later colors arrive while it is in flight.
        let beforeBurst = fixture.status.backgroundFramesDrawn
        fixture.renderer.update(running: false, configuration: configuration(red))
        fixture.renderer.update(running: false, configuration: configuration(green, reactivity: 1.2))
        fixture.renderer.update(running: false, configuration: configuration(blue, reactivity: 1.7))
        waitUntil("in-flight paused updates must get a replacement frame") {
            fixture.status.backgroundFramesDrawn == beforeBurst + 2
        }
        settle()
        let bluePixel = fixture.pixel()
        check(bluePixel.blue > bluePixel.red && bluePixel.blue > bluePixel.green,
              "the newest in-flight color must survive, rather than leaving the first color displayed")
        check(fixture.status.backgroundFramesDrawn == beforeBurst + 2,
              "multiple in-flight paused changes must coalesce into one replacement")

        let beforeKind = fixture.status.backgroundFramesDrawn
        fixture.renderer.update(running: false, configuration: configuration(blue, reactivity: 1.7, kind: .beams))
        waitUntil("a paused kind change must draw with the other pipeline") {
            fixture.status.backgroundFramesDrawn == beforeKind + 1
        }

        let beforeMotion = fixture.status.backgroundFramesDrawn
        fixture.status.frame = SpectrumFrame(bands: [Float](repeating: 0.5, count: 48),
                                             levels: [Float](repeating: 0.5, count: 48), rms: 0.2)
        fixture.renderer.update(running: true, configuration: configuration(blue, reactivity: 1.7))
        waitUntil("a running background must submit repeated frames") {
            fixture.status.backgroundFramesDrawn >= beforeMotion + 4
        }
        fixture.renderer.update(running: false, configuration: configuration(blue, reactivity: 1.7))
        settle() // an already submitted command may finish after the pause
        let pausedFrames = fixture.status.backgroundFramesDrawn
        let pausedDraws = fixture.view.drawAttempts
        settle()
        check(fixture.status.backgroundFramesDrawn == pausedFrames && fixture.view.drawAttempts == pausedDraws,
              "running-to-paused must stop repeated GPU submissions")
        check(fixture.status.backgroundFailure == nil, "all GPU commands must complete successfully")
    }

    static func pausedSwiftUIResize() {
        let status = VisualizationModel()
        let suite = "floe-background-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = VisualSettings(defaults: UserDefaults(suiteName: suite)!)
        let host = NSHostingView(rootView: ReactiveBackground(colors: Covers.palette(Covers.sunset))
            .environment(status).environment(settings))
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

        let beforeSetting = status.backgroundFramesDrawn
        settings.glow = 1.6
        waitUntil("a paused settings change must redraw through SwiftUI") { status.backgroundFramesDrawn > beforeSetting }
        settings.backgroundKind = .beams
        settle()
        let afterKind = status.backgroundFramesDrawn
        settle()
        check(afterKind > beforeSetting + 1 && status.backgroundFramesDrawn == afterKind && status.backgroundFailure == nil,
              "switching kinds while paused must draw once and stay idle")
    }

    // MARK: - Palette

    static func paletteChecks() {
        for (name, cover) in [("sunset", Covers.sunset), ("ocean", Covers.ocean)] {
            let colors = Covers.palette(cover)
            check(colors.count == CoverColorExtractor.paletteSize, "\(name): the palette must fill every slot")
            let closest = colors.indices.flatMap { i in colors.indices.filter { $0 > i }.map { colors[i].distance(to: colors[$0]) } }.min()!
            check(closest > 0.1, "\(name): palette colours must be distinct (closest pair \(closest))")
            let hues = Set(colors.map { Int(CoverColorExtractor.hsv($0).0 * 12) })
            check(hues.count >= 3, "\(name): a multicoloured cover must give at least three hues, got \(hues.count)")
        }
        let accent = CoverColorExtractor.extract(of: Covers.sunset)!
        let sunset = Covers.palette(Covers.sunset)
        check(CoverColorExtractor.hsv(sunset[0]).0.distance(to: CoverColorExtractor.hsv(accent).0) < 0.03,
              "the cover's accent must lead its palette")

        for (name, cover) in [("navy", Covers.navy), ("grey", Covers.grey)] {
            let colors = Covers.palette(cover)
            check(colors.count == CoverColorExtractor.paletteSize, "\(name): a plain cover must still fill every slot")
            check(colors.allSatisfy { CoverColorExtractor.hsv($0).1 > 0.25 }, "\(name): plain covers get shades, not greys")
            let closest = colors.indices.flatMap { i in colors.indices.filter { $0 > i }.map { colors[i].distance(to: colors[$0]) } }.min()!
            check(closest > 0.05, "\(name): derived shades must still differ (closest pair \(closest))")
        }
        let navy = Covers.palette(Covers.navy)
        check(navy.allSatisfy { $0.b > $0.r }, "a navy cover's shades must stay blue")
        check(CoverColorExtractor.palette(of: Covers.grey, accent: .fallback) == CoverColorExtractor.shades(of: .fallback),
              "a greyscale cover must fall back to shades of the accent")
    }

    // MARK: - Settings

    static func settingsChecks() {
        let suite = "floe-background-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = VisualSettings(defaults: defaults)
        check(fresh.backgroundKind == .fluid && fresh.motionSpeed == 1 && fresh.glow == 1 && fresh.shake == 1
              && fresh.vividness == 1 && fresh.beamCount == 6 && !fresh.strobe,
              "new background settings must start at their defaults, with the strobe off")
        for (key, value) in [("backgroundSpeed", 9.0), ("backgroundGlow", -3.0), ("backgroundShake", 40.0),
                             ("backgroundVividness", 0.0), ("backgroundReactivity", 7.0)] { defaults.set(value, forKey: key) }
        defaults.set(99, forKey: "backgroundBeamCount")
        defaults.set("lasers", forKey: "backgroundKind")
        var clamped = VisualSettings(defaults: defaults)
        check(clamped.motionSpeed == VisualSettings.speedRange.upperBound && clamped.glow == VisualSettings.glowRange.lowerBound
              && clamped.shake == VisualSettings.shakeRange.upperBound && clamped.vividness == VisualSettings.vividnessRange.lowerBound
              && clamped.reactivity == 2 && clamped.beamCount == VisualSettings.beamCountRange.upperBound
              && clamped.backgroundKind == .fluid,
              "out-of-range stored settings must clamp, and an unknown kind must fall back")
        defaults.set(1, forKey: "backgroundBeamCount")
        clamped = VisualSettings(defaults: defaults)
        check(clamped.beamCount == VisualSettings.beamCountRange.lowerBound, "too few beams must clamp up")
        clamped.backgroundKind = .beams; clamped.motionSpeed = 1.5; clamped.strobe = true
        let reloaded = VisualSettings(defaults: defaults)
        check(reloaded.backgroundKind == .beams && reloaded.motionSpeed == 1.5 && reloaded.strobe,
              "background settings must persist")
    }

    // MARK: - Beats

    static func beats(_ frames: [SpectrumFrame]) -> [Int] {
        var detector = BeatDetector()
        return frames.indices.filter { detector.update(frames[$0], dt: 1 / 30).beat > 0 }
    }

    static func detectorChecks() {
        check(beats(Array(repeating: .quiet, count: 120)).isEmpty, "silence must never beat")
        let pad = SyntheticTrack(pad: 0.1)
        check(beats(SyntheticTrack.frames([(pad, 4)])).isEmpty, "a soft pad without drums must not beat")
        let drone = SyntheticTrack(bass: 0.6, pad: 0.2)
        let droneBeats = beats(SyntheticTrack.frames([(drone, 4)]))
        check(droneBeats.count <= 1, "a sustained bassline must not wobble on every frame (\(droneBeats.count) beats)")

        let groove = SyntheticTrack(kicksPerSecond: 2, kick: 0.8, bass: 0.15, pad: 0.1, hats: 0.08)
        let grooveBeats = beats(SyntheticTrack.frames([(groove, 6)]))
        check((10...13).contains(grooveBeats.count), "2 kicks a second for 6 s must give about 12 beats, got \(grooveBeats.count)")
        let kickFrames = (0..<12).map { Int((groove.kickOffset + Float($0) * 0.5) * 30) }
        let onTime = grooveBeats.filter { beat in kickFrames.contains { abs($0 - beat) <= 2 } }
        check(onTime.count >= grooveBeats.count - 1, "beats must land on the kicks (\(onTime.count) of \(grooveBeats.count))")

        let frantic = SyntheticTrack(kicksPerSecond: 8, kick: 0.8, bass: 0.2, pad: 0.15, hats: 0.1)
        let franticBeats = beats(SyntheticTrack.frames([(frantic, 4)]))
        let gaps = zip(franticBeats.dropFirst(), franticBeats).map { $0 - $1 }
        check(franticBeats.count >= 6 && franticBeats.count <= 12 && gaps.allSatisfy { $0 >= 10 },
              "8 kicks a second must still beat, but no more than 3 times a second (\(franticBeats))")

        var detector = BeatDetector()
        var quietEnergy: Float = 0, loudEnergy: Float = 0, peakLift: Float = 0
        for (i, frame) in SyntheticTrack.frames([(pad, 4), (groove, 3)]).enumerated() {
            let pulse = detector.update(frame, dt: 1 / 30)
            if i == 119 { quietEnergy = pulse.energy }
            if i >= 120 { peakLift = max(peakLift, pulse.lift) }
            loudEnergy = pulse.energy
        }
        check(loudEnergy > quietEnergy + 0.25, "energy must follow loudness (\(quietEnergy) → \(loudEnergy))")
        check(peakLift > 0.8, "a drop after a quiet passage must lift (\(peakLift))")
    }

    // MARK: - Fluid

    static func fluidChecks(device: MTLDevice) {
        guard let renderer = try? OffscreenRenderer(device: device) else { fail("cannot build the offscreen renderer") }
        let palettes: [(String, [RGB])] = [("sunset", Covers.palette(Covers.sunset)), ("ocean", Covers.palette(Covers.ocean)),
                                          ("navy", Covers.palette(Covers.navy))]
        let quietTrack = SyntheticTrack(pad: 0.05)
        let groove = SyntheticTrack(kicksPerSecond: 2, kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.08)
        let quietFrames = SyntheticTrack.frames([(quietTrack, 3)])
        // One kick after a quiet stretch: the twin keeps the quiet frames.
        let hitFrames = SyntheticTrack.frames([(quietTrack, 3), (SyntheticTrack(kicksPerSecond: 0.25, kick: 1, pad: 0.05, kickOffset: 3.0), 1)])
        let loudFrames = SyntheticTrack.frames([(groove, 6)])
        var rows: [[RenderedFrame]] = []

        for (index, (name, colors)) in palettes.enumerated() {
            let settings = BackgroundConfiguration(kind: .fluid, colors: colors)
            var quiet = BackgroundAnimator()
            quiet.configure(settings, animated: false)
            for frame in quietFrames { quiet.advance(by: 1 / 30, frame: frame) }
            let quietFrame = renderer.render(quiet)

            var hit = BackgroundAnimator()
            hit.configure(settings, animated: false)
            var twin = hit
            var hitFrame: RenderedFrame?, twinFrame: RenderedFrame?, afterHit: RenderedFrame?
            var hitIndex = -1
            for (i, frame) in hitFrames.enumerated() {
                hit.advance(by: 1 / 30, frame: frame)
                twin.advance(by: 1 / 30, frame: i < quietFrames.count ? frame : quietFrames[quietFrames.count - 1])
                if hitIndex < 0, hit.pulse.beat > 0 {
                    hitIndex = i
                    hitFrame = renderer.render(hit)
                    twinFrame = renderer.render(twin)
                }
                if hitIndex >= 0, i == hitIndex + 3 { afterHit = renderer.render(hit) }
                if hitIndex >= 0, i == hitIndex + 12 {
                    let settled = renderer.render(hit), still = renderer.render(twin)
                    check(settled.difference(from: still) < hitFrame!.difference(from: twinFrame!) * 0.6,
                          "\(name): the shake must die out within 0.4 s")
                }
            }
            guard let hitFrame, let twinFrame, let afterHit else { fail("\(name): the kick after a quiet stretch must beat") }
            let moved = hitFrame.difference(from: twinFrame)
            check(moved > 0.012, "\(name): a bass hit must visibly displace the ink (\(moved))")
            check(hitFrame.meanLuma > twinFrame.meanLuma * 1.08, "\(name): a bass hit must glow (\(twinFrame.meanLuma) → \(hitFrame.meanLuma))")

            var loud = BackgroundAnimator()
            loud.configure(settings, animated: false)
            var loudFrame: RenderedFrame?
            for (i, frame) in loudFrames.enumerated() {
                loud.advance(by: 1 / 30, frame: frame)
                if i == loudFrames.count - 8 { loudFrame = renderer.render(loud) }
            }
            check(loudFrame!.meanLuma > quietFrame.meanLuma, "\(name): a loud passage must glow more than a quiet one")

            // Crossfade from the previous palette while the music plays.
            let previous = palettes[(index + palettes.count - 1) % palettes.count].1
            var fade = BackgroundAnimator()
            fade.configure(BackgroundConfiguration(kind: .fluid, colors: previous), animated: false)
            for frame in quietFrames.prefix(30) { fade.advance(by: 1 / 30, frame: frame) }
            let start = renderer.render(fade).meanColor
            fade.configure(settings, animated: true)
            var steps: [RenderedFrame] = []
            for frame in quietFrames.dropFirst(30).prefix(Int(BackgroundAnimator.crossfade * 30) + 2) {
                fade.advance(by: 1 / 30, frame: frame)
                steps.append(renderer.render(fade))
            }
            let end = steps.last!.meanColor
            let distances = steps.map { simd_distance($0.meanColor, end) }
            let jumps = zip(steps.dropFirst(), steps).map { simd_distance($0.meanColor, $1.meanColor) }
            check(simd_distance(start, end) > 0.01, "\(name): palettes must differ for the crossfade check")
            check(jumps.max()! < simd_distance(start, end) * 0.2,
                  "\(name): a cover change must crossfade, not snap (largest step \(jumps.max()!))")
            check(distances[distances.count / 2] > 0.1 * simd_distance(start, end) && distances[distances.count / 2] < simd_distance(start, end),
                  "\(name): halfway through the crossfade, both palettes must show")

            for frame in [quietFrame, hitFrame, afterHit, loudFrame!] + steps {
                check(frame.maxLuma <= legibleLuma, "\(name): Fluid must stay under the legibility limit (\(frame.maxLuma))")
            }
            Previews.write(quietFrame, "fluid-\(name)-1-quiet")
            Previews.write(hitFrame, "fluid-\(name)-2-bass-hit")
            Previews.write(afterHit, "fluid-\(name)-3-after-hit")
            Previews.write(loudFrame!, "fluid-\(name)-4-loud")
            Previews.write(steps[steps.count / 2], "fluid-\(name)-5-crossfade")
            rows.append([quietFrame, hitFrame, afterHit, loudFrame!, steps[steps.count / 2]])
        }

        // The brightest settings with the loudest music still keep text readable.
        var extreme = BackgroundAnimator()
        extreme.configure(BackgroundConfiguration(kind: .fluid, colors: [RGB(r: 1, g: 0.95, b: 0.6), RGB(r: 0.9, g: 1, b: 0.9)],
                                                  reactivity: 2, speed: 2, glow: 2, shake: 2, vividness: 1.5), animated: false)
        var brightest: Float = 0, meanest: Float = 0
        for (i, frame) in loudFrames.enumerated() {
            extreme.advance(by: 1 / 30, frame: frame)
            if i % 3 == 0 || extreme.pulse.beat > 0 {
                let rendered = renderer.render(extreme)
                if rendered.meanLuma > meanest { Previews.write(rendered, "fluid-pale-maximum") }
                brightest = max(brightest, rendered.maxLuma)
                meanest = max(meanest, rendered.meanLuma)
            }
        }
        Previews.sheet(rows, "fluid-sheet")
        check(brightest <= legibleLuma && meanest < 0.32,
              "Fluid at full glow on a pale cover must stay dark enough for white text (peak \(brightest), mean \(meanest))")
    }

    // MARK: - Helpers

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
        checks += 1
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
