import AppKit
import SwiftUI

/// The visualizer, drawn by Core Animation: GPU shape layers carry a gradient
/// fill, a soft glow and a rim, and a 30 Hz timer feeds them each analysis
/// frame directly. Driving a SwiftUI Canvas instead put the whole window through
/// a SwiftUI update every frame (~15% CPU). Every style shares one look: rounded
/// strokes, pale at the top and saturated at the bottom, with a faint glow beneath.
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
        view.configure(style: circular ? (settings.shape == .wave ? .halo : .radialBars)
                                       : (settings.shape == .wave ? .beads : .bars),
                       sensitivity: Float(settings.sensitivity), color: NSColor(palette.highlight),
                       pale: NSColor(palette.highlight.mix(with: .white, by: 0.55)),
                       running: visualization.isRunning)
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
        for layer in [glow, echoClip, fill, rim] { container.addSublayer(layer) }
        for shape in [glow, rim, echoMask, fillMask] {
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
        rim.isHidden = style == .bars || style == .radialBars
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
        for layer in [glow, echoClip, echoExclusion, echo, echoMask, fill, fillMask, rim] { layer.frame = bounds }
        CATransaction.commit()
        drawnFrame = nil
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [container, glow, echoClip, echoExclusion, echo, echoMask, fill, fillMask, rim] { layer.contentsScale = scale }
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
            let path = VisualizerGeometry.halo(size: size, levels: levels).cgPath
            outline(path, glowWidth: 10, glowAlpha: 0.12)
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

    /// A soft filled halo whose few broad lobes follow the spectrum.
    static func halo(size: CGSize, levels: [CGFloat]) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2
        let cover = outer / VisualizerView.ringScale
        let room = outer - cover - 4
        let lobes = emphasized(smoothed(levels, groups: 12))
        let half = Double(lobes.count)
        // Right side runs top to bottom; the left side mirrors it back up.
        let right = lobes.enumerated().map { g, level in
            (angle: -.pi / 2 + (Double(g) + 0.5) / half * .pi, radius: cover + room * (0.22 + 0.78 * level))
        }
        let points = (right + right.reversed().map { (angle: .pi - $0.angle, radius: $0.radius) })
            .map { point(center, $0.angle, $0.radius) }
        var path = Path()
        addCurve(through: points, to: &path, closed: true)
        return path
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

    /// Smoothing flattens the outline, so stretch each lobe away from the mean:
    /// the shape follows the spectrum while its overall size follows loudness.
    private static func emphasized(_ values: [CGFloat], by factor: CGFloat = 1.5) -> [CGFloat] {
        let mean = values.reduce(0, +) / CGFloat(max(1, values.count))
        return values.map { min(1, max(0, mean + ($0 - mean) * factor)) }
    }

    private static func point(_ center: CGPoint, _ angle: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    /// Catmull-Rom through every point, so peaks stay where the data puts them.
    private static func addCurve(through points: [CGPoint], to path: inout Path, closed: Bool) {
        guard points.count > 1 else { return }
        path.move(to: points[0])
        func point(_ index: Int) -> CGPoint {
            points[closed ? (index + points.count) % points.count : min(points.count - 1, max(0, index))]
        }
        for i in 0..<(closed ? points.count : points.count - 1) {
            let p0 = point(i - 1), p1 = point(i), p2 = point(i + 1), p3 = point(i + 2)
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed { path.closeSubpath() }
    }
}
