import AppKit
import SwiftUI

/// The cover as a plain disc with a hairline rim. One layer holds it, so the
/// hero flight and the lyrics toggle only resize a layer, and a new song's
/// cover crossfades in the render server.
struct DiscCover: NSViewRepresentable {
    let image: CGImage
    let rim: NSColor
    let rimWidth: CGFloat
    let fade: Bool

    func makeNSView(context: Context) -> DiscCoverView { DiscCoverView() }

    func updateNSView(_ view: DiscCoverView, context: Context) {
        view.update(image: image, rim: rim, rimWidth: rimWidth, fade: fade)
    }
}

final class DiscCoverView: NSView {
    private let disc = CALayer()
    private var image: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(disc)
        disc.contentsGravity = .resizeAspectFill
        disc.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(image: CGImage, rim: NSColor, rimWidth: CGFloat, fade: Bool) {
        // Only the image may ease in; a rim that faded would lag behind the new cover's colours.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if image !== self.image {
            if fade && self.image != nil {
                let transition = CATransition()
                transition.type = .fade
                transition.duration = 0.35
                disc.add(transition, forKey: "contents")
            }
            disc.contents = image
            self.image = image
        }
        disc.borderColor = rim.cgColor
        disc.borderWidth = rimWidth
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = side / 2
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        disc.contentsScale = window?.backingScaleFactor ?? 2
    }
}
