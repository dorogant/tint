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
    var knob = WavyProgressView.Knob.rest

    func makeNSView(context: Context) -> WavyProgressView { WavyProgressView() }

    func updateNSView(_ view: WavyProgressView, context: Context) {
        view.update(progress: progress, color: NSColor(color), moving: moving, glide: glide, knob: knob)
    }
}

final class WavyProgressView: NSView {
    /// The playhead grows under the pointer, and a little more while dragged.
    enum Knob {
        case rest, hover, grab

        var size: CGSize {
            switch self {
            case .rest: CGSize(width: 5, height: 18)
            case .hover: CGSize(width: 7, height: 22)
            case .grab: CGSize(width: 8, height: 24)
            }
        }
    }

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
    private var knobState = Knob.rest
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
        knob.bounds = CGRect(origin: .zero, size: Knob.rest.size)
        knob.cornerRadius = Knob.rest.size.width / 2
        wave.speed = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The wave's on-screen scroll, for the self-test's motion check.
    var scrollOffset: Double {
        (wave.presentation()?.value(forKeyPath: "transform.translation.x") as? Double) ?? 0
    }

    func update(progress: Double, color: NSColor, moving: Bool, glide: Bool, knob shape: Knob = .rest) {
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
        setKnob(shape)
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
        knob.position = CGPoint(x: split, y: mid)
    }

    /// A short spring with no bounce, from wherever the knob is now, so quick
    /// passes over the bar retarget instead of queueing.
    private func setKnob(_ state: Knob) {
        guard state != knobState else { return }
        let grows = state.size.width > knobState.size.width
        knobState = state
        let from = (knob.presentation() ?? knob).bounds
        let fromRadius = (knob.presentation() ?? knob).cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.bounds = CGRect(origin: .zero, size: state.size)
        knob.cornerRadius = state.size.width / 2
        CATransaction.commit()
        for (key, value, target) in [("bounds", NSValue(rect: from), NSValue(rect: knob.bounds)),
                                     ("cornerRadius", fromRadius as NSNumber, knob.cornerRadius as NSNumber)] {
            let spring = CASpringAnimation(perceptualDuration: grows ? 0.17 : 0.24, bounce: 0)
            spring.keyPath = key
            spring.fromValue = value
            spring.toValue = target
            spring.duration = spring.settlingDuration
            knob.add(spring, forKey: key)
        }
    }

    private func setMoving(_ moving: Bool) {
        guard moving != self.moving else { return }
        self.moving = moving
        moving ? wave.resumeClock() : wave.pauseClock()
    }
}
