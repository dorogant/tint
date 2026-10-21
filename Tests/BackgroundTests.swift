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
        // FLOE_BUILD_ONLY=1: just the build and drop checks, for tuning them.
        if ProcessInfo.processInfo.environment["FLOE_BUILD_ONLY"] != nil {
            buildChecks()
            print("PASS: \(checks) build checks")
            return
        }
        // FLOE_BLOOM_PROOF=<dir>: full-screen frames and 100% crops of Bloom, for comparing builds.
        if let proof = ProcessInfo.processInfo.environment["FLOE_BLOOM_PROOF"] {
            bloomProof(device: device, directory: URL(fileURLWithPath: proof))
            return
        }
        // FLOE_BLOOM_COST=1: just Bloom's cost, and its dives sheet if FLOE_BLOOM_RENDERS is set.
        if ProcessInfo.processInfo.environment["FLOE_BLOOM_COST"] != nil {
            bloomDiveRenders(device: device)
            bloomPerformance(device: device)
            return
        }
        // FLOE_BLOOM_CHECK=fade,stability: just those of Bloom's checks, for tuning them.
        if let names = ProcessInfo.processInfo.environment["FLOE_BLOOM_CHECK"]?.split(separator: ",") {
            guard let renderer = try? OffscreenRenderer(device: device, width: 480, height: 300) else { fail("no offscreen renderer") }
            for name in names {
                switch name {
                case "fade": bloomPaletteFadeChecks(renderer: renderer)
                case "stability": bloomStabilityChecks(device: device)
                default: fail("no Bloom check named \(name)")
                }
            }
            print("PASS: \(checks) Bloom checks")
            return
        }
        // FLOE_BLOOM_ONLY=1: just Bloom's checks, renders and cost, for tuning it.
        if ProcessInfo.processInfo.environment["FLOE_BLOOM_ONLY"] != nil {
            bloomRenders(device: device)
            bloomPerformance(device: device)
            bloomMappingChecks()
            bloomChecks(device: device)
            print("PASS: \(checks) Bloom checks")
            return
        }
        rendererChecks(device: device)
        pausedSwiftUIResize()
        paletteChecks()
        settingsChecks()
        layerChecks()
        detectorChecks()
        musicFeatureChecks()
        fluidChecks(device: device)
        beamChecks(device: device)
        mappingChecks(device: device)
        crispnessChecks(device: device)
        smokeChecks(device: device)
        presetPreviews(device: device)
        bloomMappingChecks()
        bloomChecks(device: device)
        bloomRenders(device: device)
        performanceReport(device: device)
        bloomPerformance(device: device)
        print("PASS: \(checks) background checks (renderer, palette, settings, layers, beats, Fluid, Beams, Bloom, mapping, flash rate, crispness)")
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
        let settings = VisualSettings(defaults: TestDefaults.make())
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
        check(view.drawableSize == BackgroundRenderer.drawableSize(points: CGSize(width: 512, height: 512), scale: window.backingScaleFactor,
                                                                   kind: settings.backgroundKind)
              && view.drawableSize.width >= 512 && view.drawableSize.width == view.drawableSize.height,
              "the paused resize must use the new aspect ratio, at least a pixel per point (\(view.drawableSize))")
        settle()
        let settledFrames = status.backgroundFramesDrawn
        settle()
        check(status.backgroundFramesDrawn == settledFrames && status.backgroundFailure == nil,
              "a paused resize must finish successfully without continuous redraw")

        let beforeSetting = status.backgroundFramesDrawn
        settings.glow = 1.6
        waitUntil("a paused settings change must redraw through SwiftUI") { status.backgroundFramesDrawn > beforeSetting }
        settings.backgroundKind = .fluid
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
            // A coloured cover gets shades of its colour; a grey one its own greys, never a borrowed hue.
            check(colors.allSatisfy { (CoverColorExtractor.hsv($0).1 > 0.25) == (name == "navy") },
                  "\(name): plain covers get shades of their own colour")
            let closest = colors.indices.flatMap { i in colors.indices.filter { $0 > i }.map { colors[i].distance(to: colors[$0]) } }.min()!
            check(closest > 0.05, "\(name): derived shades must still differ (closest pair \(closest))")
        }
        let navy = Covers.palette(Covers.navy)
        check(navy.allSatisfy { $0.b > $0.r }, "a navy cover's shades must stay blue")
        check(CoverColorExtractor.colors(of: Covers.grey)?.isNeutral == true, "a greyscale cover reads as neutral")
    }

    // MARK: - Settings

    static func settingsChecks() {
        let defaults = TestDefaults.make()
        let fresh = VisualSettings(defaults: defaults)
        check(fresh.backgroundPreset == .balanced && fresh.backgroundLook == BackgroundPreset.balanced.look && !fresh.strobe,
              "a fresh install must start on Balanced, with the strobe off")
        for (key, value) in [("backgroundSpeed", 9.0), ("backgroundGlow", -3.0), ("backgroundPunch", 40.0),
                             ("backgroundVividness", 0.0), ("backgroundReactivity", 7.0)] { defaults.set(value, forKey: key) }
        defaults.set(99, forKey: "backgroundBeamCount")
        defaults.set("lasers", forKey: "backgroundKind")
        var clamped = VisualSettings(defaults: defaults)
        check(clamped.motionSpeed == VisualSettings.speedRange.upperBound && clamped.glow == VisualSettings.glowRange.lowerBound
              && clamped.punch == VisualSettings.punchRange.upperBound && clamped.vividness == VisualSettings.vividnessRange.lowerBound
              && clamped.reactivity == 2 && clamped.beamCount == VisualSettings.beamCountRange.upperBound
              && clamped.backgroundKind == BackgroundPreset.balancedLook.kind,
              "out-of-range stored settings must clamp, and an unknown kind must fall back")
        defaults.set(1, forKey: "backgroundBeamCount")
        clamped = VisualSettings(defaults: defaults)
        check(clamped.beamCount == VisualSettings.beamCountRange.lowerBound, "too few beams must clamp up")
        clamped.backgroundKind = .beams; clamped.motionSpeed = 1.5; clamped.strobe = true; clamped.punch = 0.4
        let reloaded = VisualSettings(defaults: defaults)
        check(reloaded.backgroundKind == .beams && reloaded.motionSpeed == 1.5 && reloaded.strobe && reloaded.punch == 0.4,
              "background settings must persist")

        // The old Shake scaled Fluid's random jolt, which is gone: it's dropped, not carried into Punch.
        let old = TestDefaults.make()
        old.set(0.26, forKey: "backgroundShake")
        old.set(0.54, forKey: "backgroundSpeed")
        let migrated = VisualSettings(defaults: old)
        check(migrated.punch == 1 && old.object(forKey: "backgroundShake") == nil && migrated.motionSpeed == 0.54,
              "the retired Shake value must be removed and the other knobs kept")
        check(migrated.backgroundPreset == .custom, "someone who tuned the knobs before presets keeps them, as Custom")
        presetChecks()
    }

    /// One click per preset; touching a knob makes it Custom; Custom keeps the
    /// last hand-tuned values to compare against; all of it persists.
    static func presetChecks() {
        let defaults = TestDefaults.make()
        let settings = VisualSettings(defaults: defaults)
        settings.reactivity = 1.59; settings.glow = 1.86; settings.punch = 2; settings.vividness = 1.5; settings.motionSpeed = 0.91
        check(settings.backgroundPreset == .custom, "touching a knob must switch to Custom")
        let mine = settings.backgroundLook
        settings.choose(.club)
        check(settings.backgroundPreset == .club && settings.backgroundLook == BackgroundPreset.club.look, "a preset must set every knob")
        settings.choose(.rock)
        check(settings.backgroundLook == BackgroundPreset.rock.look, "presets must switch with one choice")
        check(VisualSettings(defaults: defaults).backgroundPreset == .rock, "the chosen preset must persist")
        settings.choose(.custom)
        check(settings.backgroundPreset == .custom && settings.backgroundLook == mine, "Custom must bring back the hand-tuned values")
        settings.choose(.subtle)
        settings.beamCount = 7
        check(settings.backgroundPreset == .custom && settings.beamCount == 7, "editing a preset's knob must make it Custom")
        settings.strobe = true
        settings.choose(.intense)
        check(settings.backgroundPreset == .intense && settings.strobe, "presets must leave the opt-in strobe alone")
        let reloaded = VisualSettings(defaults: defaults)
        check(reloaded.backgroundPreset == .intense && reloaded.customLook.beamCount == 7,
              "the preset and the last custom values must survive a relaunch")

        let looks = BackgroundPreset.allCases.compactMap(\.look)
        check(looks.count == BackgroundPreset.allCases.count - 1 && Set(looks.map { "\($0)" }).count == looks.count,
              "every preset except Custom must have its own look")
        check(looks.allSatisfy { VisualSettings.speedRange.contains($0.speed) && VisualSettings.glowRange.contains($0.glow)
                                 && VisualSettings.punchRange.contains($0.punch) && VisualSettings.vividnessRange.contains($0.vividness)
                                 && VisualSettings.beamCountRange.contains($0.beamCount) && (0...2).contains($0.reactivity) },
              "preset values must be inside the sliders' ranges")
    }

    // MARK: - Layers

    static func layers(_ sections: [(SyntheticTrack, Float)]) -> [MusicLayers] {
        SyntheticTrack.frames(sections).map(\.layers)
    }

    static func hits(_ layers: [MusicLayers], _ key: KeyPath<MusicLayers, Float>, after second: Float = 0) -> [Int] {
        layers.indices.filter { Float($0) >= second * 30 && layers[$0][keyPath: key] > 0 }
    }

    static func mean(_ layers: [MusicLayers], _ key: KeyPath<MusicLayers, Float>, after second: Float = 1) -> Float {
        let slice = layers.dropFirst(Int(second * 30))
        return slice.map { $0[keyPath: key] }.reduce(0, +) / Float(max(1, slice.count))
    }

    /// Each instrument has to land in its own layer, hits have to be found at
    /// any loudness, and the tempo has to lock onto a steady groove.
    static func layerChecks() {
        check(layers([(SyntheticTrack(), 3)]).allSatisfy { $0 == MusicLayers() }, "silence must leave every layer at rest")

        let kicks = layers([(SyntheticTrack(kick: 0.9), 6)])
        let hats = layers([(SyntheticTrack(pad: 0.05, hats: 0.12), 6)])
        let vocal = layers([(SyntheticTrack(vocal: 0.3), 6)])
        let snares = layers([(SyntheticTrack(snare: 0.4), 6)])
        let kickHits = hits(kicks, \.kick).count, hatHits = hits(hats, \.hat).count
        let snareHits = hits(snares, \.snare).count
        print(String(format: "Layers: kicks %d kick / %d hat hits; hats %d hat / %d kick; snares %d snare / %d kick; vocal %d hits",
                     kickHits, hits(kicks, \.hat).count, hatHits, hits(hats, \.kick).count, snareHits, hits(snares, \.kick).count,
                     hits(vocal, \.kick).count + hits(vocal, \.hat).count + hits(vocal, \.snare).count))
        print(String(format: "Layers: envelopes (bass, low-mid, mid, high) kicks %.2f %.2f %.2f %.2f; hats %.2f %.2f %.2f %.2f; vocal %.2f %.2f %.2f %.2f",
                     mean(kicks, \.bass), mean(kicks, \.lowMid), mean(kicks, \.mid), mean(kicks, \.high),
                     mean(hats, \.bass), mean(hats, \.lowMid), mean(hats, \.mid), mean(hats, \.high),
                     mean(vocal, \.bass), mean(vocal, \.lowMid), mean(vocal, \.mid), mean(vocal, \.high)))
        check((11...13).contains(kickHits), "12 kicks in 6 s must give about 12 kick hits (\(kickHits))")
        check(hits(kicks, \.hat).isEmpty && hits(kicks, \.snare).count <= 1, "kicks must not read as hats or snares")
        check(hatHits >= 40, "hats on the eighths must be found nearly every time (\(hatHits) of 48)")
        check(hits(hats, \.kick).isEmpty, "hats must not read as kicks")
        check((5...7).contains(snareHits), "a snare every second must be found (\(snareHits) in 6 s)")
        check(hits(vocal, \.kick).isEmpty && hits(vocal, \.hat).isEmpty, "a sung vowel must not read as drums")
        check(mean(kicks, \.bass) > mean(kicks, \.high) + 0.2, "kicks must live in the bass layer")
        check(mean(hats, \.high) > mean(hats, \.bass) + 0.2, "hats must live in the high layer")
        check(mean(vocal, \.mid) > mean(vocal, \.bass) + 0.15 && mean(vocal, \.mid) > mean(vocal, \.high) + 0.15,
              "a vocal must live in the mid layer")

        // The bass envelope pumps with the kicks instead of sitting flat.
        let pump = kicks.dropFirst(60).prefix(30).map(\.bass)
        check(pump.max()! - pump.min()! > 0.4, "the bass envelope must pump with the kicks (\(pump.min()!)…\(pump.max()!))")

        // Quiet songs still register their hits; loud, clipped masters don't fire on everything.
        let groove = SyntheticTrack(kick: 0.8, bass: 0.15, pad: 0.1, hats: 0.08, snare: 0.3)
        let quiet = layers([(groove.scaled(0.05), 6)])
        let loud = layers([(groove.scaled(2.5, clip: true), 6)])
        let quietKicks = hits(quiet, \.kick).count, loudKicks = hits(loud, \.kick).count
        check((10...14).contains(quietKicks), "kicks 26 dB down must still be found (\(quietKicks))")
        check((10...15).contains(loudKicks) && hits(loud, \.hat).count < 60, "a clipped master must not fire on every frame (\(loudKicks) kicks)")

        // A steady groove locks the tempo, and its beats line up with the kicks.
        let song = layers([(SyntheticTrack(kick: 0.8, bass: 0.15, pad: 0.1, hats: 0.08, snare: 0.3, vocal: 0.1), 12)])
        let last = song.last!
        let onBeat = hits(song, \.kick, after: 6).map { abs(song[$0].beats - song[$0].beats.rounded()) }
        print(String(format: "Layers: tempo %.1f BPM, confidence %.2f, kicks off the beat clock by at most %.2f beats",
                     last.tempo, last.confidence, onBeat.max() ?? -1))
        check(abs(last.tempo - 120) < 2 && last.confidence > 0.5, "a 120 BPM groove must lock (\(last.tempo) BPM, \(last.confidence))")
        check(onBeat.filter { $0 < 0.15 }.count >= onBeat.count - 1, "kicks must land on the beat clock (\(onBeat))")
        let fading = layers([(SyntheticTrack(kick: 0.8, bass: 0.15, pad: 0.1, hats: 0.08, snare: 0.3), 8), (SyntheticTrack(pad: 0.08), 6)])
        check(fading.last!.confidence < 0.3, "the beat clock must lose confidence when the drums stop (\(fading.last!.confidence))")
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

    // MARK: - Driving the animator like the app

    /// Analysis at 30 Hz, the display at 60: each analysis frame is received once
    /// and the motion steps twice. `each` sees every display frame.
    static func play(_ animator: inout BackgroundAnimator, _ frames: [SpectrumFrame],
                     each: (inout BackgroundAnimator, _ analysis: Int, _ display: Int) -> Void = { _, _, _ in }) {
        for (i, frame) in frames.enumerated() {
            animator.receive(frame)
            for half in 0..<2 {
                animator.step(by: 1 / 60)
                each(&animator, i, i * 2 + half)
            }
        }
    }

    static let neutral = [RGB(r: 0.86, g: 0.87, b: 0.9), RGB(r: 0.62, g: 0.63, b: 0.66), RGB(r: 0.95, g: 0.93, b: 0.88),
                          RGB(r: 0.5, g: 0.52, b: 0.56), RGB(r: 0.78, g: 0.78, b: 0.8)]

    // MARK: - Fluid

    static func fluidChecks(device: MTLDevice) {
        guard let renderer = try? OffscreenRenderer(device: device) else { fail("cannot build the offscreen renderer") }
        let palettes: [(String, [RGB])] = [("sunset", Covers.palette(Covers.sunset)), ("ocean", Covers.palette(Covers.ocean)),
                                          ("navy", Covers.palette(Covers.navy)), ("neutral", neutral)]
        let quietTrack = SyntheticTrack(pad: 0.05)
        let groove = SyntheticTrack(kicksPerSecond: 2, kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.08, snare: 0.25, vocal: 0.1)
        let quietFrames = SyntheticTrack.frames([(quietTrack, 3)])
        // One kick after a quiet stretch: the twin keeps the quiet frames.
        let hitFrames = SyntheticTrack.frames([(quietTrack, 3), (SyntheticTrack(kicksPerSecond: 0.25, kick: 1, pad: 0.05, kickOffset: 3.0), 1.5)])
        let loudFrames = SyntheticTrack.frames([(groove, 6)])
        var rows: [[RenderedFrame]] = []

        for (index, (name, colors)) in palettes.enumerated() {
            let settings = BackgroundConfiguration(kind: .fluid, colors: colors)
            var quiet = BackgroundAnimator()
            quiet.configure(settings, animated: false)
            play(&quiet, quietFrames)
            let quietFrame = renderer.render(quiet)

            var hit = BackgroundAnimator()
            hit.configure(settings, animated: false)
            var twin = hit
            var hitIndex = -1
            var swell: (frame: RenderedFrame, twin: RenderedFrame)?
            var settled: (frame: RenderedFrame, twin: RenderedFrame)?
            var peakBreath: Float = 0
            for (i, frame) in hitFrames.enumerated() {
                hit.advance(by: 1 / 30, frame: frame)
                twin.advance(by: 1 / 30, frame: i < quietFrames.count ? frame : quietFrames[quietFrames.count - 1])
                if hitIndex < 0, hit.pulse.kick > 0, i >= quietFrames.count { hitIndex = i }
                peakBreath = max(peakBreath, hit.fluid.breath.position)
                // The breath peaks a few frames after the kick, then lets go.
                if hitIndex >= 0, i == hitIndex + 6 { swell = (renderer.render(hit), renderer.render(twin)) }
                if hitIndex >= 0, i == hitIndex + 36 { settled = (renderer.render(hit), renderer.render(twin)) }
            }
            guard let swell, let settled else { fail("\(name): the kick after a quiet stretch must register") }
            let moved = swell.frame.difference(from: swell.twin)
            check(peakBreath > 0.3, "\(name): a kick must make the field breathe (\(peakBreath))")
            check(moved > 0.004, "\(name): the breath must visibly move the ink (\(moved))")
            check(settled.frame.difference(from: settled.twin) < moved * 0.5, "\(name): the breath must settle within a second")
            check(swell.frame.meanLuma > swell.twin.meanLuma * 1.04,
                  "\(name): a kick must swell the glow (\(swell.twin.meanLuma) → \(swell.frame.meanLuma))")
            // A breath, not a shove: with the glow off, the frame after a kick is
            // mostly the frame without it zoomed in about the centre (the kick's
            // click also fills the ink a little through the mids).
            var still = BackgroundAnimator(), breathing = BackgroundAnimator()
            let dark = BackgroundConfiguration(kind: .fluid, colors: colors, glow: 0, punch: 2)
            still.configure(dark, animated: false)
            breathing.configure(dark, animated: false)
            for (i, frame) in hitFrames.prefix(hitIndex + 7).enumerated() {
                breathing.advance(by: 1 / 30, frame: frame)
                still.advance(by: 1 / 30, frame: i < quietFrames.count ? frame : quietFrames[quietFrames.count - 1])
            }
            let breathed = renderer.render(breathing), unbreathed = renderer.render(still)
            let factor = 1 / (1 - 0.035 * breathing.fluid.breath.position)
            let asZoom = breathed.difference(from: unbreathed.zoomed(factor))
            check(asZoom < breathed.difference(from: unbreathed) * 0.7 && factor > 1.02,
                  "\(name): the breath must be a zoom about the centre (\(breathed.difference(from: unbreathed)) → \(asZoom) once zoomed)")

            var loud = BackgroundAnimator()
            loud.configure(settings, animated: false)
            var loudFrame: RenderedFrame?
            play(&loud, loudFrames) { animator, i, display in
                if display == loudFrames.count * 2 - 16 { loudFrame = renderer.render(animator) }
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

            for frame in [quietFrame, swell.frame, loudFrame!] + steps {
                check(frame.maxLuma <= legibleLuma, "\(name): Fluid must stay under the legibility limit (\(frame.maxLuma))")
            }
            Previews.write(quietFrame, "fluid-\(name)-1-quiet")
            Previews.write(swell.frame, "fluid-\(name)-2-bass-breath")
            Previews.write(loudFrame!, "fluid-\(name)-3-loud")
            rows.append([quietFrame, swell.twin, swell.frame, settled.frame, loudFrame!, steps[steps.count / 2]])
        }
        Previews.sheet(rows, "fluid-sheet", scale: 0.4)

        // Calm: with the glow off, the picture moves as smoothly on a kick as
        // between kicks. The old random jolt spiked several times the median here.
        var calm = BackgroundAnimator()
        calm.configure(BackgroundConfiguration(kind: .fluid, colors: Covers.palette(Covers.sunset), glow: 0), animated: false)
        var last: RenderedFrame?
        var changes: [Float] = []
        play(&calm, Array(loudFrames.prefix(120))) { animator, i, _ in
            guard i >= 45 else { return }
            let frame = renderer.render(animator)
            if let last { changes.append(frame.difference(from: last)) }
            last = frame
        }
        let median = changes.sorted()[changes.count / 2]
        print(String(format: "Fluid motion per 60 Hz frame through a groove: median %.4f, largest %.4f (%.1f×)",
                     median, changes.max()!, changes.max()! / median))
        check(changes.max()! < median * 2.5, "Fluid must not jolt on the beat (largest step \(changes.max()!) vs median \(median))")

        // The brightest settings with the loudest music still keep text readable.
        var extreme = BackgroundAnimator()
        extreme.configure(BackgroundConfiguration(kind: .fluid, colors: [RGB(r: 1, g: 0.95, b: 0.6), RGB(r: 0.9, g: 1, b: 0.9)],
                                                  reactivity: 2, speed: 2, glow: 2, punch: 2, vividness: 1.5), animated: false)
        var brightest: Float = 0, meanest: Float = 0
        for (i, frame) in loudFrames.enumerated() {
            extreme.advance(by: 1 / 30, frame: frame)
            if i % 3 == 0 || extreme.pulse.beat > 0 {
                let rendered = renderer.render(extreme)
                brightest = max(brightest, rendered.maxLuma)
                meanest = max(meanest, rendered.meanLuma)
            }
        }
        check(brightest <= legibleLuma && meanest < 0.32,
              "Fluid at full glow on a pale cover must stay dark enough for white text (peak \(brightest), mean \(meanest))")
    }

    // MARK: - Beams

    static func beamChecks(device: MTLDevice) {
        guard let renderer = try? OffscreenRenderer(device: device) else { fail("cannot build the offscreen renderer") }
        let quietTrack = SyntheticTrack(pad: 0.05)
        let breakdown = SyntheticTrack(pad: 0.12, hats: 0.02)
        let drop = SyntheticTrack(kicksPerSecond: 2, kick: 0.95, bass: 0.3, pad: 0.25, hats: 0.12, snare: 0.3, kickOffset: 4.25)
        let quietFrames = SyntheticTrack.frames([(quietTrack, 3)])
        let dropFrames = SyntheticTrack.frames([(breakdown, 4), (drop, 5)])
        var rows: [[RenderedFrame]] = []

        for (name, colors) in [("sunset", Covers.palette(Covers.sunset)), ("ocean", Covers.palette(Covers.ocean)), ("neutral", neutral)] {
            let settings = BackgroundConfiguration(kind: .beams, colors: colors, neutral: name == "neutral")
            var quiet = BackgroundAnimator()
            quiet.configure(settings, animated: false)
            play(&quiet, quietFrames)
            let quietFrame = renderer.render(quiet)
            print(String(format: "Beams %@: quiet passage mean luma %.3f", name, quietFrame.meanLuma))
            check(quietFrame.meanLuma < 0.05, "\(name): Beams must stay dim in a quiet passage (\(quietFrame.meanLuma))")

            var animator = BackgroundAnimator()
            animator.configure(settings, animated: false)
            var beforeKick: RenderedFrame?, kick: RenderedFrame?, sustained: RenderedFrame?, change: RenderedFrame?
            var breakdownFrame: RenderedFrame?
            var changedAt = -1
            var pattern = animator.beams.pattern
            play(&animator, dropFrames) { animator, i, display in
                if display == 239 { breakdownFrame = renderer.render(animator) }
                if i >= 120, changedAt < 0, animator.beams.pattern != pattern { changedAt = i }
                pattern = animator.beams.pattern
                if changedAt >= 0, i == changedAt + 15, display % 2 == 1 { change = renderer.render(animator) }
                if i == 120 + 75, display % 2 == 1 { sustained = renderer.render(animator) }
            }
            // The third kick of the drop, against the frame just before it.
            var replay = BackgroundAnimator()
            replay.configure(settings, animated: false)
            for (i, frame) in dropFrames.enumerated() {
                if i >= 150, kick == nil {
                    var peek = replay
                    peek.receive(frame)
                    if peek.pulse.beat > 0 {
                        beforeKick = renderer.render(replay)
                        peek.step(by: 1 / 60)
                        peek.step(by: 1 / 60)
                        kick = renderer.render(peek)
                    }
                }
                replay.receive(frame)
                replay.step(by: 1 / 60)
                replay.step(by: 1 / 60)
            }
            guard let beforeKick, let kick, let sustained, let change, let breakdownFrame else {
                fail("\(name): the drop must beat and change the look (changed at \(changedAt))")
            }
            check(changedAt <= 120 + 45, "\(name): the drop must change the look within its first beats (frame \(changedAt))")
            check(kick.meanLuma > quietFrame.meanLuma * 3, "\(name): a kick on the drop must blow the beams up (\(quietFrame.meanLuma) → \(kick.meanLuma))")
            check(kick.meanLuma > beforeKick.meanLuma * 1.12, "\(name): each kick must punch the beams (\(beforeKick.meanLuma) → \(kick.meanLuma))")
            check(sustained.meanLuma > breakdownFrame.meanLuma * 1.5, "\(name): the drop must outshine the breakdown before it")
            for frame in [quietFrame, breakdownFrame, beforeKick, kick, sustained, change] {
                check(frame.meanLuma < 0.2 && frame.share(above: legibleLuma) < 0.1,
                      "\(name): the frame must stay dark apart from the beams (mean \(frame.meanLuma), bright \(frame.share(above: legibleLuma)))")
            }

            var strobe = BackgroundAnimator()
            strobe.configure(BackgroundConfiguration(kind: .beams, colors: settings.colors, strobe: true), animated: false)
            var flashFrame: RenderedFrame?
            play(&strobe, dropFrames) { animator, _, _ in
                if flashFrame == nil, animator.beams.flashes > 0 { flashFrame = renderer.render(animator) }
            }
            guard let flashFrame else { fail("\(name): the opt-in strobe must flash on the drop") }
            Previews.write(quietFrame, "beams-\(name)-1-quiet")
            Previews.write(breakdownFrame, "beams-\(name)-2-breakdown")
            Previews.write(kick, "beams-\(name)-3-kick")
            Previews.write(sustained, "beams-\(name)-4-drop")
            Previews.write(change, "beams-\(name)-5-new-look")
            Previews.write(flashFrame, "beams-\(name)-6-strobe")
            rows.append([quietFrame, breakdownFrame, beforeKick, kick, sustained, change, flashFrame])
        }
        Previews.sheet(rows, "beams-sheet", scale: 0.4)

        // A steady groove changes the look every eight bars, not just on drops.
        var steady = BackgroundAnimator()
        steady.configure(BackgroundConfiguration(kind: .beams), animated: false)
        var patterns: Set<Int> = []
        play(&steady, SyntheticTrack.frames([(SyntheticTrack(kicksPerSecond: 2, kick: 0.8, bass: 0.2, pad: 0.15, hats: 0.08), 40)])) { animator, _, _ in
            patterns.insert(animator.beams.pattern.rawValue)
        }
        check(patterns.count >= 3, "a steady groove must move through looks every eight bars (\(patterns.count) in 40 s)")
        let four = BackgroundConfiguration(kind: .beams, beamCount: 4)
        var counted = BackgroundAnimator()
        counted.configure(four, animated: false)
        let heads = counted.beamUniforms(width: 512, height: 336)
        check(heads.size.z == 4 && heads.heads.4 == .zero, "the beam count must limit the heads drawn")

        flashRateChecks(renderer: renderer)
    }

    // MARK: - Beams: what plays what

    /// Per-head values from the uniforms the shader gets.
    static func headValues(_ animator: BackgroundAnimator) -> [SIMD4<Float>] {
        let u = animator.beamUniforms(width: 1600, height: 1000)
        return [u.heads.0, u.heads.1, u.heads.2, u.heads.3, u.heads.4, u.heads.5, u.heads.6, u.heads.7]
    }

    /// The mapping, pinned: kicks move the outer beams, snares the inner ones,
    /// hats and highs brighten the inner beams and the bass the outer ones,
    /// vocals fill the haze, sweeps turn on the beat, nothing jumps, and silence settles.
    static func mappingChecks(device: MTLDevice) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 800, height: 500) else { fail("cannot build the offscreen renderer") }
        let colors = Covers.palette(Covers.sunset)
        let eight = BackgroundConfiguration(kind: .beams, colors: colors, beamCount: 8)
        let outer = [0, 7], inner = [3, 4]

        struct Run { var swing = [Float](repeating: 0, count: 8); var intensity = [Float](repeating: 0, count: 8); var frames = 0; var haze: Float = 0 }
        func run(_ track: SyntheticTrack, seconds: Float = 6, configuration: BackgroundConfiguration = eight) -> Run {
            var animator = BackgroundAnimator()
            animator.configure(configuration, animated: false)
            var result = Run()
            play(&animator, SyntheticTrack.frames([(track, seconds)])) { animator, i, _ in
                guard i >= 60 else { return }
                let heads = headValues(animator)
                for h in 0..<8 {
                    result.swing[h] = max(result.swing[h], abs(animator.beams.swing[h].position))
                    result.intensity[h] += heads[h].y
                }
                result.haze += animator.beamUniforms(width: 1600, height: 1000).floor.z
                result.frames += 1
            }
            result.intensity = result.intensity.map { $0 / Float(result.frames) }
            result.haze /= Float(result.frames)
            return result
        }
        func average(_ values: [Float], _ heads: [Int]) -> Float { heads.map { values[$0] }.reduce(0, +) / Float(heads.count) }

        let kicks = run(SyntheticTrack(kick: 0.9, bass: 0.15, pad: 0.1))
        let snares = run(SyntheticTrack(pad: 0.1, snare: 0.45))
        let hats = run(SyntheticTrack(pad: 0.1, hats: 0.12))
        let vocal = run(SyntheticTrack(pad: 0.05, vocal: 0.3))
        print(String(format: "Mapping: kicks swing outer %.3f / inner %.3f rad, light outer %.2f / inner %.2f",
                     average(kicks.swing, outer), average(kicks.swing, inner), average(kicks.intensity, outer), average(kicks.intensity, inner)))
        print(String(format: "Mapping: snares swing outer %.3f / inner %.3f rad; hats light outer %.2f / inner %.2f",
                     average(snares.swing, outer), average(snares.swing, inner), average(hats.intensity, outer), average(hats.intensity, inner)))
        print(String(format: "Mapping: haze fill with a vocal %.2f, with hats %.2f, with kicks %.2f", vocal.haze, hats.haze, kicks.haze))
        check(average(kicks.swing, outer) > 3 * average(kicks.swing, inner) && average(kicks.swing, outer) > 0.03,
              "kicks must swing the outer beams, not the inner ones")
        check(average(snares.swing, inner) > 2 * average(snares.swing, outer) && average(snares.swing, inner) > 0.015,
              "snares must flick the inner beams, not the outer ones")
        check(average(kicks.intensity, outer) > 1.4 * average(kicks.intensity, inner), "the bass must light the outer beams")
        check(average(hats.intensity, inner) > 1.4 * average(hats.intensity, outer), "the hats must light the inner beams")
        check(vocal.haze > 0.15 && vocal.haze > 2 * hats.haze && vocal.haze > 2 * kicks.haze, "a vocal must fill the haze")
        let calm = run(SyntheticTrack(kick: 0.9, bass: 0.15, pad: 0.1), configuration: BackgroundConfiguration(kind: .beams, colors: colors, punch: 0, beamCount: 8))
        check(calm.swing.max()! < 0.002, "Bass punch at 0 must keep the beams from swinging (\(calm.swing.max()!))")

        // A whole song: nothing jumps, the sweeps follow the beat, and silence settles.
        let song: [(SyntheticTrack, Float)] = [
            (SyntheticTrack(pad: 0.08, vocal: 0.15), 4),                                        // intro
            (SyntheticTrack(pad: 0.12, hats: 0.1, vocal: 0.15), 4),                             // build
            (SyntheticTrack(kick: 0.9, bass: 0.25, pad: 0.2, hats: 0.1, snare: 0.3, vocal: 0.15), 10), // drop
            (SyntheticTrack(pad: 0.1, vocal: 0.2), 4),                                          // breakdown
            (SyntheticTrack(kick: 0.9, bass: 0.25, pad: 0.2, hats: 0.1, snare: 0.3, vocal: 0.15), 6),  // drop
            (SyntheticTrack(), 5),                                                              // silence
        ]
        let frames = SyntheticTrack.frames(song)
        var animator = BackgroundAnimator()
        animator.configure(eight, animated: false)
        var previous: [SIMD4<Float>]?
        var largestStep: Float = 0, lastSecondStep: Float = 0
        var onBeat: [Float] = []
        var cells: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        let sections = ["intro", "build", "drop", "breakdown", "drop", "silence"]
        var sectionStarts: [Int] = []
        var t: Float = 0
        for (_, seconds) in song { sectionStarts.append(Int(t * 30)); t += seconds }
        play(&animator, frames) { animator, i, display in
            let heads = headValues(animator)
            if let previous {
                let step = zip(heads, previous).map { abs($0.x - $1.x) }.max()!
                largestStep = max(largestStep, step)
                if i >= frames.count - 30 { lastSecondStep = max(lastSecondStep, step) }
            }
            previous = heads
            if display % 2 == 0, animator.pulse.kick > 0.3, i > 30 * 10, i < 30 * 18 {
                onBeat.append(abs(animator.beams.clock - animator.beams.clock.rounded()))
            }
            // Two frames from the middle of each section, half a second apart.
            if let s = sectionStarts.firstIndex(where: { i == $0 + 75 || i == $0 + 90 }), display % 2 == 0 {
                cells.append((renderer.render(animator), "\(sections[s]) +\(i - sectionStarts[s] == 75 ? "2.5" : "3.0") s", nil))
            }
        }
        let settled = headValues(animator)
        print(String(format: "Mapping: largest head turn per 60 Hz frame %.3f rad; in the last second of silence %.4f; kicks %.2f beats off the sweep clock at most",
                     largestStep, lastSecondStep, onBeat.max() ?? -1))
        check(largestStep < 0.09, "no beam may jump between frames (\(largestStep) rad)")
        check(lastSecondStep < 0.002 && animator.beams.swing.allSatisfy { abs($0.position) < 0.003 },
              "silence must let every beam settle (\(lastSecondStep))")
        check(settled.allSatisfy { $0.y < 0.15 }, "silence must dim the rig")
        check(onBeat.count >= 10 && onBeat.filter { $0 < 0.15 }.count >= onBeat.count * 8 / 10,
              "the sweeps must turn on the beat once the tempo locks (\(onBeat))")
        Previews.strip(cells, "beams-song-sections", columns: 4, scale: 0.4)

        mappingStrips(renderer: renderer, colors: colors)
    }

    /// Frame strips that make the mapping visible: a kick (outer beams punch and
    /// wobble), hats (the inner beams glint), a vocal (the haze fills).
    static func mappingStrips(renderer: OffscreenRenderer, colors: [RGB]) {
        guard Previews.directory != nil else { return }
        let configuration = BackgroundConfiguration(kind: .beams, colors: colors, beamCount: 8)
        let red = CGColor(srgbRed: 1, green: 0.3, blue: 0.25, alpha: 1), cyan = CGColor(srgbRed: 0.3, green: 0.85, blue: 1, alpha: 1)
        let yellow = CGColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1)
        let groove = SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.1, snare: 0.3, vocal: 0.12)
        for (name, track, palette) in [("groove", groove, colors), ("groove-neutral", groove, neutral)] {
            var animator = BackgroundAnimator()
            animator.configure(BackgroundConfiguration(kind: .beams, colors: palette, neutral: palette == neutral, beamCount: 8), animated: false)
            var cells: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
            play(&animator, SyntheticTrack.frames([(track, 9)])) { animator, i, display in
                // One beat and a half at 60 Hz, every other display frame (a 30 Hz strip).
                guard i >= 30 * 8 - 1, i < 30 * 8 + 23, display % 2 == 1 else { return }
                let p = animator.pulse
                let label = String(format: "%.2fs", Float(display) / 60) + (p.kick > 0 ? " KICK" : "") + (p.snare > 0 ? " SNARE" : "") + (p.hat > 0 ? " hat" : "")
                cells.append((renderer.render(animator), label, p.kick > 0 ? red : (p.snare > 0 ? yellow : (p.hat > 0 ? cyan : nil))))
            }
            Previews.strip(cells, "beams-mapping-\(name)", columns: 6, scale: 0.36)
        }
        for (name, track) in [("kicks-only", SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.1)),
                              ("hats-only", SyntheticTrack(pad: 0.1, hats: 0.12)),
                              ("vocal-only", SyntheticTrack(pad: 0.05, vocal: 0.3))] {
            var animator = BackgroundAnimator()
            animator.configure(configuration, animated: false)
            var cells: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
            play(&animator, SyntheticTrack.frames([(track, 6)])) { animator, i, display in
                guard i >= 30 * 5 - 1, i < 30 * 5 + 17, display % 2 == 1 else { return }
                let p = animator.pulse
                let label = String(format: "%.2fs", Float(display) / 60) + (p.kick > 0 ? " KICK" : "") + (p.snare > 0 ? " SNARE" : "") + (p.hat > 0 ? " hat" : "")
                cells.append((renderer.render(animator), label, p.kick > 0 ? red : (p.snare > 0 ? yellow : (p.hat > 0 ? cyan : nil))))
            }
            Previews.strip(cells, "beams-mapping-\(name)", columns: 6, scale: 0.36)
        }
    }

    // MARK: - Crispness

    /// The beams have to stay smooth at whatever resolution they're drawn. At
    /// 512 px the unfiltered core beaded by 14% row to row; pre-filtered, 7%;
    /// at the new drawable size about 2%.
    static func crispnessChecks(device: MTLDevice) {
        let colors = Covers.palette(Covers.ocean)
        var animator = BackgroundAnimator()
        animator.configure(BackgroundConfiguration(kind: .beams, colors: colors, beamCount: 4), animated: false)
        play(&animator, SyntheticTrack.frames([(SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.1), 3)]))
        let points = CGSize(width: 1500, height: 950)
        let budget = BackgroundRenderer.drawableSize(points: points, scale: 2)
        let old = CGSize(width: 512, height: 324)
        for (name, size) in [("512px", old), ("budget", budget)] {
            guard let renderer = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) else { fail("renderer") }
            let frame = renderer.render(animator)
            // Head 0's beam, from just under its lens down a third of the frame.
            let u = animator.beamUniforms(width: Float(size.width), height: Float(size.height))
            let angle = u.heads.0.x
            let aspect = Float(size.width / size.height)
            let sourceX = 0.5 / 4 * aspect, sourceY: Float = 0.985
            // Down the narrow first stretch of the beam, its brightest pixel per row.
            // A core thinner than a pixel that isn't pre-filtered beads: it's caught
            // by a pixel centre on one row and missed on the next.
            var peaks: [Float] = []
            for row in Int(size.height * 0.04)..<Int(size.height * 0.22) {
                let y = 1 - (Float(row) + 0.5) / Float(size.height)   // uv, up from the bottom
                let along = (sourceY - y) / cos(angle)
                let x = (sourceX + sin(angle) * along) / aspect * Float(size.width)
                let half = max(3, Int(Float(size.height) * (0.006 + along * u.heads.0.z) * 0.8))
                var peak: Float = 0
                for column in max(0, Int(x) - half)..<min(Int(size.width), Int(x) + half + 1) { peak = max(peak, frame.luma(column, row)) }
                peaks.append(peak)
            }
            let bends = zip(zip(peaks.dropFirst(2), peaks.dropFirst()), peaks).map { abs($0.0 - 2 * $0.1 + $1) }
            let beading = bends.reduce(0, +) / Float(max(1, bends.count)) / (peaks.reduce(0, +) / Float(peaks.count))
            print(String(format: "Crispness at %@ (%dx%d): the beam's core flickers %.1f%% row to row", name, Int(size.width), Int(size.height), beading * 100))
            check(peaks.count > 12 && beading < 0.1, "\(name): a thin beam must not bead into pixels (\(beading))")
            // 100% crops near the lens of head 0, and what the window shows on a 2x display.
            let cropW = Int(size.width) / 5, cropH = Int(size.height) / 4
            let crop = frame.crop(x: max(0, Int(sourceX / aspect * Float(size.width)) - cropW / 2), y: 0, width: cropW, height: cropH)
            Previews.zoom(crop, "crisp-\(name)-100pct", scale: 1, smooth: false)
            Previews.zoom(crop, "crisp-\(name)-as-on-retina", scale: 2 * points.width / size.width, smooth: true)
        }
    }

    // MARK: - Smoke

    /// The fog has to read as smoke, not smudges on the glass: down the length
    /// of a beam its light may only swell and thin over large distances, with
    /// nothing blotchy at small scales, and frames a second apart must differ
    /// (it drifts; dirt doesn't). At the user's own settings: glow 186%,
    /// reactivity 159%, vividness 150%, punch 200%.
    static func smokeChecks(device: MTLDevice) {
        let size = BackgroundRenderer.drawableSize(points: CGSize(width: 1500, height: 950), scale: 2)
        guard let renderer = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) else { fail("renderer") }
        let aspect = Float(size.width / size.height)
        let groove = SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.12, snare: 0.3, vocal: 0.12)
        let frames = SyntheticTrack.frames([(groove, 8)])
        for (name, colors, neutralCover) in [("sunset", Covers.palette(Covers.sunset), false), ("neutral", neutral, true)] {
            func settings(_ beams: Int) -> BackgroundConfiguration {
                BackgroundConfiguration(kind: .beams, colors: colors, neutral: neutralCover, reactivity: 1.59, speed: 0.91,
                                        glow: 1.86, punch: 2, vividness: 1.5, beamCount: beams)
            }
            // The user's own look, with hats, for the eye.
            var look = BackgroundAnimator()
            look.configure(settings(6), animated: false)
            var shots: [RenderedFrame] = []
            play(&look, frames) { animator, i, display in
                if display % 2 == 0, i == 30 * 6 || i == 30 * 7 { shots.append(renderer.render(animator)) }
            }
            Previews.write(shots[0], "smoke-\(name)-full")
            let cropW = Int(size.width) / 4, cropH = Int(size.height) * 3 / 5
            let crop = shots[0].crop(x: Int(size.width) * 3 / 8, y: Int(size.height) / 8, width: cropW, height: cropH)
            Previews.zoom(crop, "smoke-\(name)-retina-100pct", scale: 2 * 1500 / size.width, smooth: true)
            let drift = shots[1].difference(from: shots[0])

            // A lone head in the middle hangs straight down; the light beside its core, row by row.
            var lone = BackgroundAnimator()
            lone.configure(settings(1), animated: false)
            var frame: RenderedFrame?
            var u = lone.beamUniforms(width: Float(size.width), height: Float(size.height))
            play(&lone, frames) { animator, i, display in
                guard display % 2 == 0, i == 30 * 6 else { return }
                u = animator.beamUniforms(width: Float(size.width), height: Float(size.height))
                frame = renderer.render(animator)
            }
            guard let frame else { fail("smoke frame") }
            let sine = u.tints.0.w, cosine = (1 - sine * sine).squareRoot()
            var along: [Float] = []
            for row in Int(size.height / 6)..<Int(size.height * 5 / 6) {
                let y = 1 - (Float(row) + 0.5) / Float(size.height)
                // In the beam's glow, out past its core (and the motes in it), where the fog shows.
                let distance = (0.985 - y) / cosine
                let x = (0.5 * aspect + sine * distance + 1.5 * (0.006 + distance * u.heads.0.z)) / aspect * Float(size.width)
                var sum: Float = 0
                for dx in -2...2 { sum += frame.luma(Int(x) + dx, row) }
                along.append(sum / 5)
            }
            // Small-scale mottle: what's left after a running mean over a tenth of the height.
            let window = Int(size.height / 10)
            var residual: Float = 0, mean: Float = 0, n = 0
            for i in window..<(along.count - window) {
                let local = along[(i - window)...(i + window)].reduce(0, +) / Float(2 * window + 1)
                residual += (along[i] - local) * (along[i] - local)
                mean += along[i]
                n += 1
            }
            let mottle = (residual / Float(max(1, n))).squareRoot() / max(0.001, mean / Float(max(1, n)))
            print(String(format: "Smoke (%@, the user's settings): light down a beam mottles %.2f%% at small scales; frames a second apart differ %.4f",
                         name, mottle * 100, drift))
            // The specks and fine wisps the user saw as a dirty screen measured 6.2% here.
            check(along.count > 100 && mottle < 0.045, "\(name): the fog must not look blotchy along a beam (\(mottle))")
            check(drift > 0.004, "\(name): the fog must drift, not sit on the screen (\(drift))")
        }
    }

    // MARK: - Presets

    /// Every preset over the same groove and a quiet passage, for comparing them
    /// side by side; each must keep text readable.
    static func presetPreviews(device: MTLDevice) {
        guard let renderer = try? OffscreenRenderer(device: device, width: 640, height: 400) else { fail("renderer") }
        let groove = SyntheticTrack.frames([(SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.1, snare: 0.3, vocal: 0.12), 7)])
        let quiet = SyntheticTrack.frames([(SyntheticTrack(pad: 0.1, vocal: 0.15), 5)])
        var cells: [(frame: RenderedFrame, label: String, mark: CGColor?)] = []
        for preset in BackgroundPreset.general + BackgroundPreset.genres {
            guard let look = preset.look else { continue }
            let configuration = BackgroundConfiguration(kind: look.kind, colors: Covers.palette(Covers.sunset), reactivity: Float(look.reactivity),
                                                        speed: Float(look.speed), glow: Float(look.glow), punch: Float(look.punch),
                                                        vividness: Float(look.vividness), beamCount: look.beamCount)
            for (section, frames) in [("groove", groove), ("quiet", quiet)] {
                var animator = BackgroundAnimator()
                animator.configure(configuration, animated: false)
                var shot: RenderedFrame?
                play(&animator, frames) { animator, i, display in
                    // Just after a kick in the groove; anywhere late in the quiet passage.
                    if shot == nil, display % 2 == 1, i > frames.count - 40, section == "quiet" || animator.pulse.kick > 0.5 {
                        shot = renderer.render(animator)
                    }
                }
                guard let shot else { fail("\(preset): no frame") }
                check(shot.meanLuma < 0.2 && shot.share(above: legibleLuma) < 0.1, "\(preset): must stay dark enough for text (\(shot.meanLuma))")
                cells.append((shot, "\(preset.title), \(section)", nil))
            }
        }
        Previews.strip(cells, "presets-sheet", columns: 4, scale: 0.5)
    }

    // MARK: - Cost

    /// The production renderer's own CPU cost while running, over a window-sized
    /// view: its clock, the motion, encoding and presenting each frame (it's off
    /// screen, so a 60 Hz timer stands in for the display link). Analysis frames
    /// arrive at 30 Hz as they do from the worker.
    static func rendererCost(device: MTLDevice, frames: [SpectrumFrame]) {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        for kind in VisualSettings.BackgroundKind.allCases {
            let fixture = Fixture(device: device, bounds: CGRect(x: 0, y: 0, width: 1500, height: 950))
            fixture.view.framebufferOnly = true
            let configuration = BackgroundConfiguration(kind: kind, colors: Covers.palette(Covers.sunset), beamCount: 8)
            fixture.renderer.update(running: true, configuration: configuration)
            pump(for: 0.5)
            let feed = DispatchSource.makeTimerSource(queue: .main)
            var next = 0
            feed.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333))
            feed.setEventHandler { MainActor.assumeIsolated { fixture.status.frame = frames[next % frames.count]; next += 1 } }
            feed.resume()
            let drawn = fixture.status.backgroundFramesDrawn, cpu = cpuSeconds(), start = Date()
            pump(for: 4)
            let wall = Date().timeIntervalSince(start)
            let rate = Double(fixture.status.backgroundFramesDrawn - drawn) / wall
            print(String(format: "Renderer CPU while running %@ (%dx%d drawable): %.1f%% of a core at %.0f frames/s (%.0f µs a frame, including this test's 30 Hz frame feed)",
                         kind.rawValue, Int(fixture.view.drawableSize.width), Int(fixture.view.drawableSize.height),
                         (cpuSeconds() - cpu) / wall * 100, rate, (cpuSeconds() - cpu) / max(1, rate * wall) * 1_000_000))
            feed.cancel()
            fixture.renderer.update(running: false, configuration: configuration)
            fixture.renderer.stop()
            fixture.window.close()
            check(fixture.status.backgroundFailure == nil, "the running renderer must not fail")
        }
    }

    /// GPU time per frame at the sizes the app can draw, and the CPU cost of a
    /// display frame (analysis receive, motion step and uniforms).
    static func performanceReport(device: MTLDevice) {
        let frames = SyntheticTrack.frames([(SyntheticTrack(kick: 0.95, bass: 0.3, pad: 0.25, hats: 0.12, snare: 0.3, vocal: 0.1), 8)])
        var beams = BackgroundAnimator()
        beams.configure(BackgroundConfiguration(kind: .beams, colors: Covers.palette(Covers.sunset), beamCount: 8), animated: false)
        var fluid = BackgroundAnimator()
        fluid.configure(BackgroundConfiguration(kind: .fluid, colors: Covers.palette(Covers.sunset)), animated: false)
        var floorOn = beams
        play(&beams, frames) { animator, _, _ in if animator.beams.floorLevel > floorOn.beams.floorLevel { floorOn = animator } }
        play(&fluid, frames)
        print("GPU: \(device.name)")
        rendererCost(device: device, frames: frames)
        let windows: [(String, CGSize)] = [("1200x750 pt window", CGSize(width: 1200, height: 750)),
                                           ("1500x950 pt window", CGSize(width: 1500, height: 950)),
                                           ("1728x1117 pt full screen", CGSize(width: 1728, height: 1117))]
        var sizes: [(String, CGSize, BackgroundAnimator)] = [("old 512 px, Beams", CGSize(width: 512, height: 324), floorOn),
                                                             ("old 512 px, Fluid", CGSize(width: 512, height: 324), fluid)]
        for (name, points) in windows {
            sizes.append(("\(name), Beams", BackgroundRenderer.drawableSize(points: points, scale: 2, kind: .beams), floorOn))
            sizes.append(("\(name), Fluid", BackgroundRenderer.drawableSize(points: points, scale: 2, kind: .fluid), fluid))
        }
        sizes.append(("full Retina 3456x2234, Beams", CGSize(width: 3456, height: 2234), floorOn))
        for (name, size, animator) in sizes {
            guard let renderer = try? OffscreenRenderer(device: device, width: Int(size.width), height: Int(size.height)) else { continue }
            let time = renderer.gpuMilliseconds(animator)
            let rate: Double = name.contains("old") ? 30 : (animator.configuration.kind == .beams ? 60 : 30)
            print(String(format: "GPU per frame, %@ (%dx%d): %.2f ms, %.1f%% of the GPU at %.0f Hz", name, Int(size.width), Int(size.height),
                         time, time * rate / 10, rate))
        }
        var animator = BackgroundAnimator()
        animator.configure(BackgroundConfiguration(kind: .beams, colors: Covers.palette(Covers.sunset), beamCount: 8), animated: false)
        let start = Date()
        var sink: Float = 0
        for _ in 0..<5 {
            for frame in frames {
                animator.receive(frame)
                for _ in 0..<2 {
                    animator.step(by: 1 / 60)
                    sink += animator.beamUniforms(width: 1600, height: 1000).heads.0.x
                }
            }
        }
        let perFrame = Date().timeIntervalSince(start) / Double(frames.count * 2 * 5) * 1_000_000
        print(String(format: "CPU per display frame (motion step + uniforms, Beams with 8 heads): %.1f µs%@", perFrame, sink.isNaN ? "!" : ""))
        frameAllocations(device: device, frames: frames)
    }

    /// Heap allocations on the main thread per frame of the paths that run
    /// while playing: the analyzer (30 Hz, on its own queue in the app), each
    /// kind's motion and uniforms, and encoding a frame for the GPU (60 Hz).
    static func frameAllocations(device: MTLDevice, frames: [SpectrumFrame]) {
        let block = Int(SpectrumAnalyzer.sampleRate / 30)
        let samples = (0..<block).map { sinf(Float($0) * 0.05) * 0.5 }
        let analyzer = SpectrumAnalyzer()!
        for _ in 0..<30 { _ = analyzer.process(left: samples, right: samples, count: block) }
        var kept = SpectrumFrame.quiet
        let analysis = AllocationCounter.allocations {
            for _ in 0..<300 { kept = analyzer.process(left: samples, right: samples, count: block) }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<300 { kept = analyzer.process(left: samples, right: samples, count: block) }
        let analysisMicros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / 300
        print(String(format: "Analyzer: %.1f µs and %.1f allocations per analysis frame%@", analysisMicros,
                     Double(analysis) / 300, kept.rms.isNaN ? "!" : ""))

        guard let renderer = try? OffscreenRenderer(device: device, width: 1600, height: 1000) else { return }
        for kind in VisualSettings.BackgroundKind.allCases {
            var animator = BackgroundAnimator()
            animator.configure(BackgroundConfiguration(kind: kind, colors: Covers.palette(Covers.sunset), beamCount: 8), animated: false)
            // Mid-crossfade, so the palette is blended as it is after a song change.
            for frame in frames.prefix(60) { animator.advance(by: 1 / 60, frame: frame) }
            animator.configure(BackgroundConfiguration(kind: kind, colors: Covers.palette(Covers.ocean), beamCount: 8), animated: true)
            var sink: Float = 0
            let motion = AllocationCounter.allocations {
                for frame in frames.prefix(120) {
                    animator.receive(frame)
                    for _ in 0..<2 {
                        animator.step(by: 1 / 60)
                        switch kind {
                        case .beams: sink += animator.beamUniforms(width: 1600, height: 1000).heads.0.x
                        case .fluid: sink += animator.fluidUniforms(width: 1600, height: 1000).motion.x
                        case .bloom: sink += animator.bloomUniforms(width: 1600, height: 1000).layers.0.view.x
                        }
                    }
                }
            }
            let encoding = AllocationCounter.allocations { renderer.encodeOnly(animator, frames: 60) }
            print(String(format: "Allocations per display frame, %@: %.1f for motion + uniforms, %.1f encoding the frame%@",
                         kind.rawValue, Double(motion) / 240, Double(encoding) / 60, sink.isNaN ? "!" : ""))
        }
    }

    /// WCAG 2.3.1: no more than three flashes in any second, over the whole frame
    /// or any 1/16 of it, while the music hammers eight kicks a second: with the
    /// strobe at the brightest settings, without it, and at the defaults.
    static func flashRateChecks(renderer: OffscreenRenderer) {
        let frantic = SyntheticTrack(kicksPerSecond: 8, kick: 0.95, bass: 0.3, pad: 0.25, hats: 0.12, kickOffset: 2)
        let frames = SyntheticTrack.frames([(SyntheticTrack(pad: 0.08), 2), (frantic, 4)])
        let colors = Covers.palette(Covers.sunset)
        let brightest = BackgroundConfiguration(kind: .beams, colors: colors, reactivity: 2, speed: 2, glow: 2, beamCount: 8)
        var strobing = brightest
        strobing.strobe = true
        for (name, configuration) in [("strobe at maximum", strobing), ("maximum", brightest),
                                      ("defaults", BackgroundConfiguration(kind: .beams, colors: colors))] {
            let strobe = configuration.strobe
            var animator = BackgroundAnimator()
            animator.configure(configuration, animated: false)
            var cells: [[Float]] = Array(repeating: [], count: 17)
            var strobes: [Int] = []
            for (i, frame) in frames.enumerated() {
                let before = animator.beams.flashes
                animator.advance(by: 1 / 30, frame: frame)
                if animator.beams.flashes > before { strobes.append(i) }
                guard i >= 50 else { continue }
                let rendered = renderer.render(animator)
                let grid = rendered.relativeLuminance(columns: 4, rows: 4)
                for (c, value) in grid.enumerated() { cells[c].append(value) }
                cells[16].append(grid.reduce(0, +) / 16)
            }
            let worst = cells.map { mostFlashesPerSecond(transitions($0)) }.max()!
            check(worst <= 3, "\(name): no region may flash more than 3 times a second (\(worst))")
            let strobesPerSecond = (0..<frames.count).map { start in strobes.filter { (start..<start + 30).contains($0) }.count }.max()!
            let whole = mostFlashesPerSecond(transitions(cells[16]))
            if strobe {
                check(strobes.count >= 6 && strobesPerSecond <= 3,
                      "the strobe must fire on the beat, but no more than 3 times a second (\(strobes.count) in 4 s, \(strobesPerSecond) per second)")
                check(transitions(cells[16]).count >= 2 * strobes.count - 1, "each strobe must flash the whole frame")
            } else {
                check(strobes.isEmpty, "\(name): the strobe is opt-in")
            }
            if configuration == BackgroundConfiguration(kind: .beams, colors: colors) {
                check(whole == 0, "at the defaults, the whole frame must never flash (\(whole) a second)")
            }
            print("Beams at 8 kicks/s, \(name): \(strobes.count) strobe flashes in 4 s; at most \(whole) WCAG flashes a second over the whole frame, \(worst) in any region")
        }
    }

    /// Frames where the luminance rose or fell by at least 0.1 since the last
    /// turn (with the darker side below 0.8): two of them make one WCAG flash.
    static func transitions(_ series: [Float], threshold: Float = 0.1) -> [Int] {
        guard var low = series.first else { return [] }
        var high = low, trend = 0, times: [Int] = []
        for (i, value) in series.enumerated() {
            low = min(low, value)
            high = max(high, value)
            if trend <= 0, value - low >= threshold, low < 0.8 {
                times.append(i); trend = 1; low = value; high = value
            } else if trend >= 0, high - value >= threshold, value < 0.8 {
                times.append(i); trend = -1; low = value; high = value
            }
        }
        return times
    }

    static func mostFlashesPerSecond(_ transitions: [Int]) -> Int {
        guard let last = transitions.last else { return 0 }
        return (0...last).map { start in transitions.filter { (start..<start + 30).contains($0) }.count / 2 }.max()!
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

        init(device: MTLDevice, bounds: CGRect = CGRect(x: 0, y: 0, width: 512, height: 320)) {
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
