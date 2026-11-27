import AppKit
import SwiftUI

/// The visualizer, drawn by Core Animation: GPU shape layers carry a gradient
/// fill, a soft glow and a rim, and each analysis frame reaches them directly
/// from the model as it arrives. Driving a SwiftUI Canvas instead put the whole
/// window through a SwiftUI update every frame (~15% CPU). The bars and
/// ribbons share one look: rounded, pale at the top and saturated at the
/// bottom, with a faint glow beneath. The halo is three translucent layers
/// instead, one each for bass, mids and treble; the rays are hairlines that
/// brighten as they grow, so silence leaves a faint rim.
struct VisualizerView: NSViewRepresentable {
    var circular = false
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings
    @Environment(\.coverPalette) private var palette

    /// The circular ring reaches this multiple of the cover's radius.
    nonisolated static let ringScale: CGFloat = 1.5

    func makeNSView(context: Context) -> VisualizerLayerView { VisualizerLayerView(model: visualization) }

    func updateNSView(_ view: VisualizerLayerView, context: Context) {
        // Only settings and colours come through SwiftUI; frames never do.
        let tints = Self.tints(palette.highlight)
        let style: VisualizerLayerView.Style = switch settings.shape {
        case .rays: circular ? .radialRays : .rays
        case .bars: circular ? .radialBars : .bars
        case .wave: circular ? .halo : .beads
        }
        view.configure(style: style, sensitivity: Float(settings.sensitivity), color: tints.color, pale: tints.pale,
                       running: visualization.isRunning)
    }

    /// The saturated base and the pale top from the palette's highlight, mixed
    /// perceptually so the hue holds (sRGB mixing turned blues violet on the
    /// way to white). A black-and-white cover's silver has no saturation to
    /// give the gradient depth, so its base steps down to a darker silver.
    nonisolated static func tints(_ highlight: Color) -> (color: NSColor, pale: NSColor) {
        let neutral = (NSColor(highlight).usingColorSpace(.sRGB)?.saturationComponent ?? 1) < 0.08
        let base = neutral ? highlight.mix(with: .black, by: 0.22, in: .perceptual) : highlight
        return (NSColor(base), NSColor(highlight.mix(with: .white, by: neutral ? 0.75 : 0.55, in: .perceptual)))
    }
}

final class VisualizerLayerView: NSView {
    enum Style { case radialRays, radialBars, halo, rays, bars, beads }

    private weak var model: VisualizationModel?
    private let container = CALayer()
    private let glow = CAShapeLayer()
    private let echoClip = CALayer()
    private let echoExclusion = CAShapeLayer()
    private let echo = CAGradientLayer()
    private let echoMask = CAShapeLayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let rim = CAShapeLayer()
    /// The halo's layers, back to front: bass, mids, treble.
    private let tiers = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    /// The rays' mask: one stroked layer per brightness step, faintest first.
    /// A shape layer has one opacity, so rays of a kind share a layer.
    private let rayMask = CALayer()
    private let rayShades = (0..<VisualizerGeometry.rayShades).map { _ in CAShapeLayer() }
    /// This frame's rays, one path per step; the array is reused.
    private var rayPaths = (0..<VisualizerGeometry.rayShades).map { _ in CGMutablePath() }
    private var style = Style.radialBars
    private var sensitivity: Float = 1
    private var running = false
    private var listening = false
    private var drawnFrame: UInt64?
    /// Last visual configuration applied; unchanged SwiftUI updates skip layer
    /// mutations and full `CGPath` rebuilds.
    private var lastConfig: (style: Style, sensitivity: Float, color: NSColor, pale: NSColor)?
    /// This frame's levels, reused so drawing a frame allocates no array.
    private var levels: [CGFloat] = []

    /// Every layer that fills the view.
    private var sublayers: [CALayer] {
        [glow, echoClip, echoExclusion, echo, echoMask, fill, fillMask, rim, rayMask] + tiers + rayShades
    }

    init(model: VisualizationModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        layer?.addSublayer(container)
        echo.opacity = 0.35
        echo.mask = echoMask
        echoClip.addSublayer(echo)
        echoClip.mask = echoExclusion
        echoExclusion.fillRule = .evenOdd
        echoExclusion.fillColor = NSColor.black.cgColor
        fill.mask = fillMask
        for layer in [glow] + tiers + [echoClip, fill, rim] { container.addSublayer(layer) }
        for shape in [glow, rim, echoMask, fillMask] + tiers {
            shape.lineCap = .round
            shape.lineJoin = .round
        }
        glow.fillColor = nil
        rim.fillColor = nil
        for (step, shade) in rayShades.enumerated() {
            shade.lineCap = .round
            shade.fillColor = nil
            shade.strokeColor = NSColor.black.withAlphaComponent(VisualizerGeometry.rayOpacity(step: step)).cgColor
            rayMask.addSublayer(shade)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Top-down, like the geometry below; AppKit carries this to the layers.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(style: Style, sensitivity: Float, color: NSColor, pale: NSColor, running: Bool) {
        if let last = lastConfig, last.style == style, last.sensitivity == sensitivity,
           last.color == color, last.pale == pale {
            setRunning(running)
            return
        }
        lastConfig = (style, sensitivity, color, pale)
        self.style = style
        self.sensitivity = sensitivity
        let beads = style == .beads
        let rays = style == .rays || style == .radialRays
        // The pale end stays nearly opaque: a translucent pale over the dark
        // backdrop read as khaki on yellows and dusty pink on reds.
        let top = pale.withAlphaComponent(0.9).cgColor, bottom = color.withAlphaComponent(0.95).cgColor
        // Strips that grow both ways from the middle are pale there and saturated at their tips.
        let gradient = beads || style == .rays ? [bottom, pale.withAlphaComponent(0.88).cgColor, bottom] : [top, bottom]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [fill, echo] {
            layer.colors = gradient
            layer.type = .axial
            layer.locations = nil
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
        }
        if style == .radialRays {
            // Saturated where the rays leave the cover, pale at their tips, all the way round.
            fill.type = .radial
            fill.colors = [bottom, top]
            fill.locations = [NSNumber(value: 1 / Double(VisualizerView.ringScale)), 1]
            fill.startPoint = CGPoint(x: 0.5, y: 0.5)
            fill.endPoint = CGPoint(x: 1, y: 1)
        }
        fill.mask = rays ? rayMask : fillMask
        // Hairlines stay crisp: a glow under each would turn the ring to haze.
        glow.isHidden = rays
        echoClip.isHidden = !beads
        let halo = style == .halo
        fill.isHidden = halo
        // Bass is the deepest and widest, treble the palest and closest to the cover.
        let tints = [color.withAlphaComponent(0.42), (color.blended(withFraction: 0.5, of: pale) ?? color).withAlphaComponent(0.55),
                     pale.withAlphaComponent(0.8)]
        for (tier, tint) in zip(tiers, tints) {
            tier.isHidden = !halo
            tier.fillColor = tint.cgColor
            tier.strokeColor = color.withAlphaComponent(0.6).cgColor
            tier.lineWidth = 1.2
        }
        // The glow beneath: its strength is the style's; bar widths follow the view's size.
        let glowAlpha: CGFloat = switch style {
        case .radialBars: 0.14
        case .bars: 0.1
        case .halo, .beads: 0.12
        case .radialRays, .rays: 0 // hidden above
        }
        glow.strokeColor = color.withAlphaComponent(glowAlpha).cgColor
        if halo { glow.lineWidth = 10 } else if beads { glow.lineWidth = 6 }
        rim.isHidden = !beads
        // A crisp edge in the base colour; darkening it toward black turned
        // yellows olive and oranges brown.
        rim.strokeColor = color.withAlphaComponent(beads ? 0.85 : 0.45).cgColor
        rim.lineWidth = beads ? 1.2 : 1.5
        // Bars are stroked shapes; the halo and beads are filled outlines.
        let stroked = style == .bars || style == .radialBars
        fillMask.fillColor = stroked ? nil : NSColor.black.cgColor
        fillMask.strokeColor = stroked ? NSColor.black.cgColor : nil
        echoMask.fillColor = NSColor.black.cgColor
        CATransaction.commit()
        drawnFrame = nil
        redraw()
        setRunning(running)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        for layer in sublayers { layer.frame = bounds }
        CATransaction.commit()
        drawnFrame = nil
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        container.contentsScale = scale
        for layer in sublayers { layer.contentsScale = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setRunning(running)
    }

    /// Takes each new analysis frame while running and on screen.
    private func setRunning(_ running: Bool) {
        self.running = running
        let listen = running && window != nil
        guard listen != listening else { return }
        listening = listen
        model?.setFrameListener(for: self, listen ? { [weak self] in self?.redraw() } : nil)
    }

    /// Draws the model's current frame, unless it's already drawn.
    func redraw() {
        guard let model, bounds.width > 0, bounds.height > 0, drawnFrame != model.framesAnalyzed else { return }
        drawnFrame = model.framesAnalyzed
        let size = bounds.size
        let source = model.frame.levels
        if levels.count != source.count { levels = Array(repeating: 0, count: source.count) }
        for i in source.indices { levels[i] = CGFloat(min(1, max(0, source[i] * sensitivity))) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .radialRays:
            shade(width: VisualizerGeometry.radialRays(size: size, levels: levels, into: &rayPaths))
        case .rays:
            shade(width: VisualizerGeometry.rays(size: size, levels: levels, into: &rayPaths))
        case .radialBars:
            let (path, width) = VisualizerGeometry.radialBars(size: size, levels: levels)
            stroke(path, width: width, glowWidth: width * 2.2)
        case .bars:
            let (path, width) = VisualizerGeometry.bars(size: size, levels: levels)
            stroke(path, width: width, glowWidth: width * 1.8)
        case .halo:
            for (tier, shape) in zip(VisualizerGeometry.Tier.all, tiers) {
                shape.path = VisualizerGeometry.halo(tier, size: size, levels: levels, clock: model.flow)
            }
            glow.path = tiers[0].path
        case .beads:
            let (front, back) = VisualizerGeometry.beads(size: size, levels: levels, clock: model.flow)
            glow.path = front
            fillMask.path = front
            rim.path = front
            echoMask.path = back
            // Exclude the front ribbon in the compositor instead of computing
            // a polygon subtraction on the main thread for every audio frame.
            let exclusion = CGMutablePath()
            exclusion.addRect(CGRect(origin: .zero, size: size))
            exclusion.addPath(front)
            echoExclusion.path = exclusion
        }
        CATransaction.commit()
    }

    private func stroke(_ path: CGPath, width: CGFloat, glowWidth: CGFloat) {
        glow.path = path
        glow.lineWidth = glowWidth
        fillMask.path = path
        fillMask.lineWidth = width
    }

    private func shade(width: CGFloat) {
        for step in rayShades.indices {
            rayShades[step].path = rayPaths[step]
            rayShades[step].lineWidth = width
        }
    }
}

/// Outlines for each style, top-down in the view's size. Levels are 0…1, one per
/// analyser band, already adapted to the song. Scratch work stays in temporary
/// buffers, so a frame's only allocations are its paths.
enum VisualizerGeometry {
    /// Rays are sorted by level into this many brightness steps. Six keeps a
    /// step under an eighth of full brightness, too small to see a ray change layer.
    static let rayShades = 6
    /// Rays around the cover and along the strip: more than the 96 mirrored
    /// bands, so each takes its level from between two of them.
    static let radialRayCount = 168, stripRayCount = 120

    /// How bright the rays of a step are: about a third at rest, full when loud.
    static func rayOpacity(step: Int) -> CGFloat { 0.28 + 0.72 * (CGFloat(step) + 0.5) / CGFloat(rayShades) }

    /// Hairlines around the cover, bass at the top and treble at the bottom,
    /// mirrored. Each ray goes into the path of its brightness step; the result
    /// is the line width. The rays keep their proportions at every size.
    static func radialRays(size: CGSize, levels: [CGFloat], into shades: inout [CGMutablePath]) -> CGFloat {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2
        let cover = outer / VisualizerView.ringScale
        let gap = max(3, cover * 0.07)
        let count = radialRayCount
        let width = max(1, 2 * .pi * (cover + gap) / CGFloat(count) * 0.38)
        let start = cover + gap + width / 2
        let room = outer - start - width / 2
        for step in shades.indices { shades[step] = CGMutablePath() }
        for i in 0..<count {
            let turn = (Double(i) + 0.5) / Double(count)
            let level = sample(levels, at: turn < 0.5 ? 2 * turn : 2 * (1 - turn))
            let angle = turn * 2 * .pi - .pi / 2
            let path = shades[min(shades.count - 1, Int(level * CGFloat(shades.count)))]
            path.move(to: point(center, angle, start))
            path.addLine(to: point(center, angle, start + room * (0.04 + 0.96 * level)))
        }
        return width
    }

    /// The rays unrolled: they grow both ways from the middle line, bass in the
    /// centre and treble at both ends.
    static func rays(size: CGSize, levels: [CGFloat], into shades: inout [CGMutablePath]) -> CGFloat {
        let count = stripRayCount
        let width = max(1.2, size.width / CGFloat(count) * 0.38)
        let mid = size.height / 2
        let reach = mid - width / 2 - 1
        for step in shades.indices { shades[step] = CGMutablePath() }
        for i in 0..<count {
            let across = (Double(i) + 0.5) / Double(count)
            let level = sample(levels, at: abs(2 * across - 1))
            let x = CGFloat(across) * size.width, half = reach * (0.03 + 0.97 * level)
            let path = shades[min(shades.count - 1, Int(level * CGFloat(shades.count)))]
            path.move(to: CGPoint(x: x, y: mid - half))
            path.addLine(to: CGPoint(x: x, y: mid + half))
        }
        return width
    }

    /// The level at a share of the way from the lowest band (0) to the highest (1).
    private static func sample(_ levels: [CGFloat], at share: Double) -> CGFloat {
        let position = min(max(share, 0), 1) * Double(levels.count - 1)
        let index = Int(position), blend = CGFloat(position - Double(index))
        return levels[index] * (1 - blend) + levels[min(index + 1, levels.count - 1)] * blend
    }

    /// Mirrored radial bars around the cover: bass at the top, treble at the bottom.
    static func radialBars(size: CGSize, levels: [CGFloat]) -> (CGPath, CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2
        let count = levels.count * 2
        let inner = outer / VisualizerView.ringScale + 3
        let width = max(1.5, 2 * .pi * inner / CGFloat(count) * 0.5)
        // Round caps stay clear of the cover outline and the view's edge.
        let start = inner + width / 2
        let room = outer - start - width / 2
        let path = CGMutablePath()
        for i in 0..<count {
            let level = levels[i < levels.count ? i : count - i - 1]
            let angle = (Double(i) + 0.5) / Double(count) * 2 * .pi - .pi / 2
            let length = room * (0.05 + 0.95 * level)
            path.move(to: point(center, angle, start))
            path.addLine(to: point(center, angle, start + length))
        }
        return (path, width)
    }

    /// One layer of the halo: which share of the spectrum it shows, how many
    /// petals it has, how far they reach (as shares of the room around the cover)
    /// and how fast it turns with the music.
    struct Tier {
        let bands: Range<Double>
        let petals: Int
        let rest: CGFloat
        let reach: CGFloat
        /// Higher values give narrower, pointier petals.
        let sharpness: Double
        let spin: Double
        static let all = [
            Tier(bands: 0..<0.25, petals: 4, rest: 0.2, reach: 1, sharpness: 1, spin: -0.05),       // ≈40–180 Hz
            Tier(bands: 0.25..<0.67, petals: 6, rest: 0.1, reach: 0.68, sharpness: 1.6, spin: 0.08), // ≈180 Hz–2.2 kHz
            Tier(bands: 0.67..<1, petals: 10, rest: 0.04, reach: 0.48, sharpness: 2, spin: -0.13), // ≈2.2–16 kHz
        ]
    }

    /// One filled layer around the cover (see `Tier.all`, back to front: bass,
    /// mids and treble). Each petal is as tall as its slice of that layer's bands,
    /// and each layer turns its own way at the music's pace, so the petals drift
    /// through each other.
    static func halo(_ tier: Tier, size: CGSize, levels: [CGFloat], clock: Double) -> CGPath {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2
        let cover = outer / VisualizerView.ringScale
        let room = outer - cover - 4
        // Committing a path costs per segment: 120 curves draw as smoothly as 240
        // lines did, for about a quarter less of the frame's commit.
        let samples = 120
        let range = Int(tier.bands.lowerBound * Double(levels.count))..<Int(tier.bands.upperBound * Double(levels.count))
        let path = CGMutablePath()
        smoothed(levels[range], groups: tier.petals) { heights in
            // Quiet petals keep a little height, so silence isn't a plain circle.
            func height(_ k: Int) -> CGFloat { 0.12 + 0.88 * heights[k] }
            let n = Double(tier.petals)
            let turn = clock * tier.spin
            withUnsafeTemporaryAllocation(of: CGPoint.self, capacity: samples) { points in
                for i in 0..<samples {
                    let angle = Double(i) / Double(samples) * 2 * .pi
                    // Petal centres sit on whole values of `u`; heights blend smoothly between them.
                    let u = (angle / (2 * .pi) * n).truncatingRemainder(dividingBy: n)
                    let k = Int(u), f = u - Double(k), eased = CGFloat(f * f * (3 - 2 * f))
                    let blended = height(k) * (1 - eased) + height((k + 1) % tier.petals) * eased
                    let petal = CGFloat(pow((1 + cos(2 * .pi * u)) / 2, tier.sharpness))
                    let radius = cover + room * (tier.rest + (tier.reach - tier.rest) * blended * petal)
                    points[i] = point(center, angle + turn - .pi / 2, radius)
                }
                // Catmull-Rom, so the outline still passes through every sample.
                path.move(to: points[0])
                for i in 0..<samples {
                    let p0 = points[(i + samples - 1) % samples], p1 = points[i]
                    let p2 = points[(i + 1) % samples], p3 = points[(i + 2) % samples]
                    path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                                  control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
                }
            }
        }
        path.closeSubpath()
        return path
    }

    /// The ring unrolled: bass in the middle, mirrored out to treble at both ends.
    static func bars(size: CGSize, levels: [CGFloat]) -> (CGPath, CGFloat) {
        let count = levels.count * 2
        let step = size.width / CGFloat(count)
        let width = max(2, step * 0.5)
        let bottom = size.height - width / 2
        let path = CGMutablePath()
        for i in 0..<count {
            let level = i < levels.count ? levels[levels.count - 1 - i] : levels[i - levels.count]
            let x = (CGFloat(i) + 0.5) * step
            path.move(to: CGPoint(x: x, y: bottom))
            path.addLine(to: CGPoint(x: x, y: bottom - (size.height - width) * (0.04 + 0.96 * level)))
        }
        return (path, width)
    }

    /// A twisted ribbon of beads drifting sideways, bass in the middle. Each bead
    /// takes its height from the spectrum at its own centre, so beads stay round
    /// and swell or shrink as they pass; a dimmer chain shows through the pinches.
    static func beads(size: CGSize, levels: [CGFloat], clock: Double) -> (front: CGPath, echo: CGPath) {
        let mid = size.height / 2
        let beads = 12.0
        let steps = Int(beads * 24)
        return smoothed(levels[...], groups: levels.count) { half in
            withUnsafeTemporaryAllocation(of: CGFloat.self, capacity: half.count * 2) { mirrored in
                for i in half.indices {
                    mirrored[i] = half[half.count - 1 - i]
                    mirrored[half.count + i] = half[i]
                }
                func height(at t: Double) -> CGFloat {
                    let x = min(max(t, 0), 1) * Double(mirrored.count - 1)
                    let i = Int(x), f = CGFloat(x - Double(i))
                    let level = mirrored[i] * (1 - f) + mirrored[min(i + 1, mirrored.count - 1)] * f
                    return (mid - 3) * (0.08 + 0.92 * level) * CGFloat(sin(.pi * min(max(t, 0), 1)).squareRoot())
                }
                func chain(phase: Double) -> CGPath {
                    withUnsafeTemporaryAllocation(of: CGPoint.self, capacity: steps + 1) { top in
                        for i in 0...steps {
                            let t = Double(i) / Double(steps)
                            let angle = .pi * beads * t + phase
                            let center = ((angle / .pi).rounded(.down) + 0.5) * .pi
                            // Beads cut by the strip's edge still close to a point.
                            let edge = CGFloat(min(1, sin(.pi * t) * 4))
                            let swell = height(at: (center - phase) / (.pi * beads)) * CGFloat(abs(sin(angle))) * edge
                            top[i] = CGPoint(x: t * size.width, y: mid - swell)
                        }
                        let path = CGMutablePath()
                        path.move(to: top[0])
                        for point in top.dropFirst() { path.addLine(to: point) }
                        for point in top.reversed() { path.addLine(to: CGPoint(x: point.x, y: 2 * mid - point.y)) }
                        path.closeSubpath()
                        return path
                    }
                }
                let phase = clock * 1.1
                return (chain(phase: phase), chain(phase: phase + .pi / 2))
            }
        }
    }

    /// Averages neighbouring bands into `groups`, then blurs once more so
    /// outlines get a few broad lobes; `body` reads the result.
    private static func smoothed<Result>(_ levels: ArraySlice<CGFloat>, groups: Int,
                                         _ body: (UnsafeMutableBufferPointer<CGFloat>) -> Result) -> Result {
        withUnsafeTemporaryAllocation(of: CGFloat.self, capacity: groups * 2) { scratch in
            let averaged = UnsafeMutableBufferPointer(rebasing: scratch[0..<groups])
            let blurred = UnsafeMutableBufferPointer(rebasing: scratch[groups...])
            let base = levels.startIndex
            for g in 0..<groups {
                let range = (g * levels.count / groups)..<((g + 1) * levels.count / groups)
                var sum: CGFloat = 0
                for i in range { sum += levels[base + i] }
                averaged[g] = sum / CGFloat(max(1, range.count))
            }
            for i in 0..<groups {
                blurred[i] = (averaged[max(0, i - 1)] + 2 * averaged[i] + averaged[min(groups - 1, i + 1)]) / 4
            }
            return body(blurred)
        }
    }

    private static func point(_ center: CGPoint, _ angle: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}
