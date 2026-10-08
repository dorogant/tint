import AppKit
import SwiftUI

/// The visualizer, drawn by Core Animation: GPU shape layers carry a gradient
/// fill, a soft glow and a rim, and a 30 Hz timer feeds them each analysis
/// frame directly. Driving a SwiftUI Canvas instead put the whole window through
/// a SwiftUI update every frame (~15% CPU). The strokes and ribbons share one look:
/// rounded, pale at the top and saturated at the bottom, with a faint glow beneath.
/// The halo is three translucent layers instead, one each for bass, mids and treble.
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
        view.configure(style: circular ? (settings.shape == .wave ? .halo : .radialBars)
                                       : (settings.shape == .wave ? .beads : .bars),
                       sensitivity: Float(settings.sensitivity), color: tints.color, pale: tints.pale,
                       running: visualization.isRunning)
    }

    /// The saturated base and the pale top from the palette's highlight.
    nonisolated static func tints(_ highlight: Color) -> (color: NSColor, pale: NSColor) {
        (NSColor(highlight), NSColor(highlight.mix(with: .white, by: 0.55)))
    }
}

final class VisualizerLayerView: NSView {
    enum Style { case radialBars, halo, bars, beads }

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
    private var style = Style.radialBars
    private var sensitivity: Float = 1
    private var color = NSColor.white
    private var running = false
    private var timer: DispatchSourceTimer?
    private var drawnFrame: UInt64?

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Top-down, like the geometry below; AppKit carries this to the layers.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(style: Style, sensitivity: Float, color: NSColor, pale: NSColor, running: Bool) {
        self.style = style
        self.sensitivity = sensitivity
        self.color = color
        let beads = style == .beads
        let top = pale.withAlphaComponent(0.75).cgColor, bottom = color.withAlphaComponent(0.95).cgColor
        let gradient = beads ? [bottom, pale.withAlphaComponent(0.7).cgColor, bottom] : [top, bottom]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [fill, echo] {
            layer.colors = gradient
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
        }
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
        rim.isHidden = style == .bars || style == .radialBars || halo
        rim.strokeColor = beads ? color.blended(withFraction: 0.45, of: .black)?.withAlphaComponent(0.7).cgColor
                                : color.withAlphaComponent(0.45).cgColor
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
        for layer in [glow, echoClip, echoExclusion, echo, echoMask, fill, fillMask, rim] + tiers { layer.frame = bounds }
        CATransaction.commit()
        drawnFrame = nil
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [container, glow, echoClip, echoExclusion, echo, echoMask, fill, fillMask, rim] + tiers {
            layer.contentsScale = scale
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let wanted = running
        running = false
        setRunning(wanted)
    }

    private func setRunning(_ running: Bool) {
        let active = running && window != nil
        self.running = running
        guard active != (timer != nil) else { return }
        if active {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(4))
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.redraw() } }
            self.timer = timer
            timer.resume()
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    /// Redraws only when a new analysis frame has arrived.
    private func redraw() {
        guard let model, bounds.width > 0, bounds.height > 0, drawnFrame != model.framesAnalyzed else { return }
        drawnFrame = model.framesAnalyzed
        let size = bounds.size
        let levels = model.frame.levels.map { CGFloat(min(1, max(0, $0 * sensitivity))) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .radialBars:
            let (path, width) = VisualizerGeometry.radialBars(size: size, levels: levels)
            stroke(path.cgPath, width: width, glowWidth: width * 2.2, glowAlpha: 0.14)
        case .bars:
            let (path, width) = VisualizerGeometry.bars(size: size, levels: levels)
            stroke(path.cgPath, width: width, glowWidth: width * 1.8, glowAlpha: 0.1)
        case .halo:
            let paths = VisualizerGeometry.halo(size: size, levels: levels, clock: model.flow).map(\.cgPath)
            for (tier, path) in zip(tiers, paths) { tier.path = path }
            glow.path = paths[0]
            glow.lineWidth = 10
            glow.strokeColor = color.withAlphaComponent(0.12).cgColor
        case .beads:
            let (front, back) = VisualizerGeometry.beads(size: size, levels: levels, clock: model.flow)
            outline(front.cgPath, glowWidth: 6, glowAlpha: 0.12)
            echoMask.path = back.cgPath
            // Exclude the front ribbon in the compositor instead of computing
            // a polygon subtraction on the main thread for every audio frame.
            let exclusion = CGMutablePath()
            exclusion.addRect(CGRect(origin: .zero, size: size))
            exclusion.addPath(front.cgPath)
            echoExclusion.path = exclusion
        }
        CATransaction.commit()
    }

    private func stroke(_ path: CGPath, width: CGFloat, glowWidth: CGFloat, glowAlpha: CGFloat) {
        glow.path = path
        glow.lineWidth = glowWidth
        glow.strokeColor = color.withAlphaComponent(glowAlpha).cgColor
        fillMask.path = path
        fillMask.lineWidth = width
    }

    private func outline(_ path: CGPath, glowWidth: CGFloat, glowAlpha: CGFloat) {
        glow.path = path
        glow.lineWidth = glowWidth
        glow.strokeColor = color.withAlphaComponent(glowAlpha).cgColor
        fillMask.path = path
        rim.path = path
    }
}

/// Outlines for each style, top-down in the view's size. Levels are 0…1, one per
/// analyser band, already adapted to the song.
enum VisualizerGeometry {
    /// Mirrored radial bars around the cover: bass at the top, treble at the bottom.
    static func radialBars(size: CGSize, levels: [CGFloat]) -> (Path, CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2
        let count = levels.count * 2
        let inner = outer / VisualizerView.ringScale + 3
        let width = max(1.5, 2 * .pi * inner / CGFloat(count) * 0.5)
        // Round caps stay clear of the cover outline and the view's edge.
        let start = inner + width / 2
        let room = outer - start - width / 2
        var path = Path()
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

    /// Three filled layers around the cover, back to front: bass, mids and treble.
    /// Each petal is as tall as its slice of that layer's bands, and each layer
    /// turns its own way at the music's pace, so the petals drift through each other.
    static func halo(size: CGSize, levels: [CGFloat], clock: Double) -> [Path] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2
        let cover = outer / VisualizerView.ringScale
        let room = outer - cover - 4
        let samples = 240
        return Tier.all.map { tier in
            let range = Int(tier.bands.lowerBound * Double(levels.count))..<Int(tier.bands.upperBound * Double(levels.count))
            // Quiet petals keep a little height, so silence isn't a plain circle.
            let heights = smoothed(Array(levels[range]), groups: tier.petals).map { 0.12 + 0.88 * $0 }
            let n = Double(tier.petals)
            let turn = clock * tier.spin
            let points = (0..<samples).map { i in
                let angle = Double(i) / Double(samples) * 2 * .pi
                // Petal centres sit on whole values of `u`; heights blend smoothly between them.
                let u = (angle / (2 * .pi) * n).truncatingRemainder(dividingBy: n)
                let k = Int(u), f = u - Double(k), eased = CGFloat(f * f * (3 - 2 * f))
                let height = heights[k] * (1 - eased) + heights[(k + 1) % tier.petals] * eased
                let petal = CGFloat(pow((1 + cos(2 * .pi * u)) / 2, tier.sharpness))
                let radius = cover + room * (tier.rest + (tier.reach - tier.rest) * height * petal)
                return point(center, angle + turn - .pi / 2, radius)
            }
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            return path
        }
    }

    /// The ring unrolled: bass in the middle, mirrored out to treble at both ends.
    static func bars(size: CGSize, levels: [CGFloat]) -> (Path, CGFloat) {
        let mirrored = levels.reversed() + levels
        let step = size.width / CGFloat(mirrored.count)
        let width = max(2, step * 0.5)
        let bottom = size.height - width / 2
        var path = Path()
        for (i, level) in mirrored.enumerated() {
            let x = (CGFloat(i) + 0.5) * step
            path.move(to: CGPoint(x: x, y: bottom))
            path.addLine(to: CGPoint(x: x, y: bottom - (size.height - width) * (0.04 + 0.96 * level)))
        }
        return (path, width)
    }

    /// A twisted ribbon of beads drifting sideways, bass in the middle. Each bead
    /// takes its height from the spectrum at its own centre, so beads stay round
    /// and swell or shrink as they pass; a dimmer chain shows through the pinches.
    static func beads(size: CGSize, levels: [CGFloat], clock: Double) -> (front: Path, echo: Path) {
        let mid = size.height / 2
        let half = smoothed(levels, groups: levels.count)
        let mirrored = half.reversed() + half
        let beads = 12.0
        func height(at t: Double) -> CGFloat {
            let x = min(max(t, 0), 1) * Double(mirrored.count - 1)
            let i = Int(x), f = CGFloat(x - Double(i))
            let level = mirrored[i] * (1 - f) + mirrored[min(i + 1, mirrored.count - 1)] * f
            return (mid - 3) * (0.08 + 0.92 * level) * CGFloat(sin(.pi * min(max(t, 0), 1)).squareRoot())
        }
        func chain(phase: Double) -> Path {
            let steps = Int(beads * 24)
            var path = Path()
            var top: [CGPoint] = []
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let angle = .pi * beads * t + phase
                let center = ((angle / .pi).rounded(.down) + 0.5) * .pi
                // Beads cut by the strip's edge still close to a point.
                let edge = CGFloat(min(1, sin(.pi * t) * 4))
                let swell = height(at: (center - phase) / (.pi * beads)) * CGFloat(abs(sin(angle))) * edge
                top.append(CGPoint(x: t * size.width, y: mid - swell))
            }
            path.move(to: top[0])
            for point in top.dropFirst() { path.addLine(to: point) }
            for point in top.reversed() { path.addLine(to: CGPoint(x: point.x, y: 2 * mid - point.y)) }
            path.closeSubpath()
            return path
        }
        let phase = clock * 1.1
        return (chain(phase: phase), chain(phase: phase + .pi / 2))
    }

    /// Averages neighbouring bands, then blurs once more so outlines get a few broad lobes.
    private static func smoothed(_ levels: [CGFloat], groups: Int) -> [CGFloat] {
        let averaged = (0..<groups).map { g in
            let range = (g * levels.count / groups)..<((g + 1) * levels.count / groups)
            return levels[range].reduce(0, +) / CGFloat(max(1, range.count))
        }
        return averaged.indices.map { i in
            (averaged[max(0, i - 1)] + 2 * averaged[i] + averaged[min(groups - 1, i + 1)]) / 4
        }
    }

    private static func point(_ center: CGPoint, _ angle: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}
