import AppKit
import SwiftUI

/// Elapsed part as a scrolling sine wave, the rest as a flat line, and a knob
/// at the playhead. Core Animation scrolls the wave and glides the playhead
/// between SwiftUI's once-a-second updates, so playback costs no per-frame work
/// in the app. Seeks and drags jump instead of gliding.
struct WavyProgress: NSViewRepresentable {
    var progress: Double
    var color: Color
    /// Scroll the wave; false while paused or with Reduce Motion.
    var moving: Bool
    /// Glide to the new playhead over the next second of playback.
    var glide: Bool

    func makeNSView(context: Context) -> WavyProgressView { WavyProgressView() }

    func updateNSView(_ view: WavyProgressView, context: Context) {
        view.update(progress: progress, color: NSColor(color), moving: moving, glide: glide)
    }
}

final class WavyProgressView: NSView {
    private static let amplitude: CGFloat = 3.5
    private static let wavelength: CGFloat = 26
    private static let lineWidth: CGFloat = 3.5
    /// One wavelength scrolls past in this time (the old 1.2 rad/s phase).
    private static let period: CFTimeInterval = 2 * .pi / 1.2

    private let elapsed = CALayer()
    private let wave = CAShapeLayer()
    private let rest = CAShapeLayer()
    private let knob = CALayer()
    private var progress = 0.0
    private var moving = false
    private var pathSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for layer in [rest, elapsed, knob] { self.layer?.addSublayer(layer) }
        elapsed.masksToBounds = true
        elapsed.addSublayer(wave)
        for shape in [wave, rest] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            shape.lineJoin = .round
        }
        rest.strokeColor = NSColor.white.withAlphaComponent(0.25).cgColor
        knob.cornerRadius = 2.5
        wave.speed = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The wave's on-screen scroll, for the self-test's motion check.
    var scrollOffset: Double {
        (wave.presentation()?.value(forKeyPath: "transform.translation.x") as? Double) ?? 0
    }

    func update(progress: Double, color: NSColor, moving: Bool, glide: Bool) {
        let jump = abs(progress - self.progress) * bounds.width > 8
        self.progress = min(max(progress, 0), 1)
        // The wave's clock may be paused, which would freeze an implicit colour fade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wave.strokeColor = color.cgColor
        knob.backgroundColor = color.cgColor
        CATransaction.commit()
        CATransaction.begin()
        if glide && !jump {
            CATransaction.setAnimationDuration(1)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        placePlayhead()
        CATransaction.commit()
        setMoving(moving)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bounds.size != pathSize, bounds.width > 0, bounds.height > 0 {
            pathSize = bounds.size
            drawPaths()
        }
        placePlayhead()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [elapsed, wave, rest, knob] { layer.contentsScale = scale }
    }

    /// The wave runs a wavelength past both ends so scrolling never shows a gap.
    private func drawPaths() {
        let mid = bounds.midY
        let path = CGMutablePath()
        var x = -Self.wavelength
        path.move(to: CGPoint(x: x, y: mid))
        while x <= bounds.width + Self.wavelength {
            path.addLine(to: CGPoint(x: x, y: mid + sin(x / Self.wavelength * 2 * .pi) * Self.amplitude))
            x += 1.5
        }
        wave.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        wave.path = path
        let scroll = CABasicAnimation(keyPath: "transform.translation.x")
        scroll.fromValue = 0
        scroll.toValue = Self.wavelength
        scroll.duration = Self.period
        scroll.repeatCount = .infinity
        wave.add(scroll, forKey: "scroll")
    }

    private func placePlayhead() {
        let split = bounds.width * progress
        let mid = bounds.midY
        // Inset by the stroke so the wave's round end stays inside the clip.
        elapsed.frame = CGRect(x: 0, y: 0, width: max(0, split), height: bounds.height)
        let line = CGMutablePath()
        line.move(to: CGPoint(x: min(bounds.width, split + 6), y: mid))
        line.addLine(to: CGPoint(x: bounds.width, y: mid))
        rest.frame = bounds
        rest.path = split + 6 < bounds.width ? line : nil
        knob.frame = CGRect(x: split - 2.5, y: mid - 9, width: 5, height: 18)
    }

    private func setMoving(_ moving: Bool) {
        guard moving != self.moving else { return }
        self.moving = moving
        moving ? wave.resumeClock() : wave.pauseClock()
    }
}
