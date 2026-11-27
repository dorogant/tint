import AppKit
import SwiftUI

/// The cover as a card standing in perspective over its own reflection, swaying
/// slowly while the song plays. Core Animation turns it, as it crawls the
/// flower's petals (see `CrawlingCover`), so playback costs no per-frame work
/// and SwiftUI updates only when the image, size or running state changes.
struct FloatingCover: NSViewRepresentable {
    /// The reflection's room under the card, as a share of the cover's width:
    /// the view is that much taller than it is wide.
    nonisolated static let foot: CGFloat = 0.16
    /// The card's side as a share of the width. The rest is room for the near
    /// edge, which perspective draws about 6% taller than the card.
    nonisolated static let inset: CGFloat = 0.9

    let image: CGImage
    let running: Bool
    let sways: Bool
    let fade: Bool

    func makeNSView(context: Context) -> FloatingCoverView { FloatingCoverView() }

    func updateNSView(_ view: FloatingCoverView, context: Context) {
        view.update(image: image, running: running, sways: sways, fade: fade)
    }
}

final class FloatingCoverView: NSView {
    /// The card turns this far to each side, in radians (about 19°).
    static let swing = 0.34
    /// Where the card stands when it doesn't sway, and where a sway starts (12°).
    static let rest = -0.21
    /// One sway there and back.
    private static let period: CFTimeInterval = 11.4

    /// Carries the clock: pausing it freezes the sway and the crossfade.
    private let content = CALayer()
    /// Gives its sublayers perspective, from the middle of the card.
    private let stage = CALayer()
    private let card = CALayer()
    private let gloss = CAGradientLayer()
    /// Turns with the card, about the same axis; its image hangs upside down.
    private let mirror = CALayer()
    private let mirrorImage = CALayer()
    private let mirrorFade = CAGradientLayer()
    private var image: CGImage?
    private var running = false
    private var sways = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(content)
        content.addSublayer(stage)
        stage.addSublayer(mirror)
        stage.addSublayer(card)
        card.addSublayer(gloss)
        mirror.addSublayer(mirrorImage)
        mirror.mask = mirrorFade
        mirrorImage.transform = CATransform3DMakeScale(1, -1, 1)
        for layer in [card, mirrorImage] {
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            layer.cornerCurve = .continuous
        }
        // A turned layer's edges are jagged without this.
        for layer in [card, mirror, mirrorImage] { layer.allowsEdgeAntialiasing = true }
        card.borderWidth = 1
        card.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        // Light falling across the top left corner.
        gloss.colors = [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        gloss.locations = [0, 0.45]
        gloss.startPoint = CGPoint(x: 0, y: 0)
        gloss.endPoint = CGPoint(x: 1, y: 1)
        // The reflection is a third as bright where it meets the card and gone at the view's foot.
        mirrorFade.colors = [NSColor.black.withAlphaComponent(0.32).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        mirrorFade.startPoint = CGPoint(x: 0.5, y: 0)
        // Start frozen; `update` sets the clock running.
        content.speed = 0
        stand()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Top-down, like the layout below; AppKit carries this to the layers.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The card's on-screen turn, for the motion checks.
    var tilt: Double {
        (card.presentation()?.value(forKeyPath: "transform.rotation.y") as? Double) ?? Self.rest
    }

    func update(image: CGImage, running: Bool, sways: Bool, fade: Bool) {
        // Implicit animations would freeze halfway while the clock is paused, so
        // every change lands immediately; only a playing cover gets the crossfade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if image !== self.image {
            if fade && running && self.image != nil {
                for layer in [card, mirrorImage] {
                    let transition = CATransition()
                    transition.type = .fade
                    transition.duration = 0.35
                    layer.add(transition, forKey: "contents")
                }
            }
            card.contents = image
            mirrorImage.contents = image
            self.image = image
        }
        if sways != self.sways {
            self.sways = sways
            sways ? sway() : stand()
        }
        CATransaction.commit()
        if running != self.running {
            self.running = running
            running ? content.resumeClock() : content.pauseClock()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The card sits in the square at the top; the reflection takes what is below it.
        let width = bounds.width, side = width * FloatingCover.inset
        content.frame = bounds
        stage.frame = CGRect(x: 0, y: 0, width: width, height: width)
        var perspective = CATransform3DIdentity
        // The eye is 2.8 card widths away: near enough to read as depth, too far to distort the artwork.
        perspective.m34 = side > 0 ? -1 / (2.8 * side) : 0
        stage.sublayerTransform = perspective
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        // Bounds and position, not frames: a frame is undefined on a turned layer.
        card.bounds = square
        card.position = CGPoint(x: width / 2, y: width / 2)
        mirror.bounds = square
        mirror.position = CGPoint(x: width / 2, y: width / 2 + side + 1)
        mirrorImage.bounds = square
        mirrorImage.position = CGPoint(x: side / 2, y: side / 2)
        gloss.frame = square
        mirrorFade.frame = square
        for layer in [card, mirrorImage] { layer.cornerRadius = side * 0.085 }
        // The hero flight starts from a square with no room below; the reflection grows in with it.
        let room = bounds.height - (width / 2 + side / 2 + 1)
        mirror.isHidden = room <= 1 || side <= 0
        if !mirror.isHidden { mirrorFade.endPoint = CGPoint(x: 0.5, y: min(1, room / side)) }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [content, stage, card, gloss, mirror, mirrorImage, mirrorFade] { layer.contentsScale = scale }
    }

    /// Holds the card at its resting turn.
    private func stand() {
        for layer in [card, mirror] {
            layer.removeAnimation(forKey: "sway")
            layer.setValue(Self.rest, forKeyPath: "transform.rotation.y")
        }
    }

    /// One sway as turns a 48th of the period apart: a sine that starts from
    /// the resting turn, so switching it on or showing a paused card never jumps.
    static var swayTurns: [Double] {
        let steps = 48, phase = asin(rest / swing)
        return (0...steps).map { swing * sin(2 * .pi * Double($0) / Double(steps) + phase) }
    }

    private func sway() {
        let turns = Self.swayTurns
        // A beginTime of exactly 0 means "now" to Core Animation; never hand it a 0.
        let start = max(content.convertTime(CACurrentMediaTime(), from: nil), 1e-6)
        for layer in [card, mirror] {
            let sway = CAKeyframeAnimation(keyPath: "transform.rotation.y")
            sway.values = turns
            sway.duration = Self.period
            sway.repeatCount = .infinity
            sway.beginTime = start
            layer.add(sway, forKey: "sway")
        }
    }
}
