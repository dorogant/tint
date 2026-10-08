import AppKit
import SwiftUI

/// The time under the pointer, in a small capsule that follows it along a
/// progress bar. AppKit tracks the pointer and Core Animation moves the
/// capsule, so hovering costs SwiftUI nothing; while scrubbing, SwiftUI pins
/// it to the drag. The bar sits along the bottom `trackHeight` of this view,
/// and the capsule floats in the room above it.
struct ScrubReadout: NSViewRepresentable {
    var durationMs: Double
    /// The drag's position while scrubbing; nil follows the pointer.
    var scrub: Double?
    var trackHeight: CGFloat
    /// From the bar's centre line to the capsule's bottom edge.
    var clearance: CGFloat
    var still: Bool
    var enabled: Bool

    func makeNSView(context: Context) -> ScrubReadoutView { ScrubReadoutView() }

    func updateNSView(_ view: ScrubReadoutView, context: Context) {
        view.configure(durationMs: durationMs, scrub: scrub, trackHeight: trackHeight, clearance: clearance,
                       still: still, enabled: enabled)
    }
}

final class ScrubReadoutView: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let height: CGFloat = 19
    /// Strong ease-out: the capsule answers at once and settles softly.
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    private let capsule = CALayer()
    private let label = CATextLayer()
    private var durationMs = 0.0
    private var scrub: Double?
    private var pointer: CGFloat?
    private var trackHeight: CGFloat = 12
    private var clearance: CGFloat = 8
    private var still = false
    private var enabled = true
    private var shown = false
    private var text = ""
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(capsule)
        capsule.addSublayer(label)
        capsule.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        capsule.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        capsule.borderWidth = 0.5
        capsule.cornerRadius = Self.height / 2
        capsule.cornerCurve = .continuous
        capsule.shadowColor = NSColor.black.cgColor
        capsule.shadowOpacity = 0.35
        capsule.shadowRadius = 6
        capsule.shadowOffset = CGSize(width: 0, height: -2)
        // Bottom centre, so it grows out of the bar rather than from its middle.
        capsule.anchorPoint = CGPoint(x: 0.5, y: 0)
        capsule.opacity = 0
        label.alignmentMode = .center
        label.foregroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        label.font = Self.font
        label.fontSize = Self.font.pointSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clicks and drags belong to the SwiftUI bar underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(durationMs: Double, scrub: Double?, trackHeight: CGFloat, clearance: CGFloat,
                   still: Bool, enabled: Bool) {
        let trackChanged = trackHeight != self.trackHeight
        self.durationMs = durationMs
        self.scrub = scrub
        self.trackHeight = trackHeight
        self.clearance = clearance
        self.still = still
        self.enabled = enabled
        if trackChanged { updateTrackingAreas() }
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        // Only the bar itself; the room above it belongs to whatever is there.
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: min(trackHeight, bounds.height))
        // Exits during a drag still count, so a scrub released off the bar hides it.
        let tracking = NSTrackingArea(rect: bar, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp,
                                                           .enabledDuringMouseDrag], owner: self)
        addTrackingArea(tracking)
        area = tracking
    }

    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseMoved(with event: NSEvent) { follow(event) }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        refresh()
    }

    /// SwiftUI may configure before the first layout, when there's no width yet.
    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [capsule, label] { layer.contentsScale = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { pointer = nil; refresh() }
    }

    private func follow(_ event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil).x
        refresh()
    }

    private func refresh() {
        let width = max(bounds.width, 1)
        guard enabled, durationMs > 0,
              let fraction = scrub ?? pointer.map({ Double(min(max($0 / width, 0), 1)) })
        else { setShown(false); return }
        let seconds = Int(fraction * durationMs / 1000)
        let text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if text != self.text {
            self.text = text
            label.string = text
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
            capsule.bounds = CGRect(x: 0, y: 0, width: textWidth + 14, height: Self.height)
            capsule.shadowPath = CGPath(roundedRect: capsule.bounds, cornerWidth: Self.height / 2,
                                        cornerHeight: Self.height / 2, transform: nil)
            let lineHeight = ceil(Self.font.ascender - Self.font.descender)
            label.frame = CGRect(x: 0, y: (Self.height - lineHeight) / 2, width: textWidth + 14, height: lineHeight)
        }
        // The pointer is followed exactly: this is a readout, not decoration.
        capsule.position = CGPoint(x: CGFloat(fraction) * bounds.width, y: trackHeight / 2 + clearance)
        CATransaction.commit()
        setShown(true)
    }

    /// Fades in from 95% with a 3 pt rise toward its place; leaves faster.
    private func setShown(_ visible: Bool) {
        guard visible != shown else { return }
        shown = visible
        let resting = still ? CATransform3DIdentity
            : CATransform3DTranslate(CATransform3DMakeScale(0.95, 0.95, 1), 0, -3, 0)
        if visible {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if capsule.opacity == 0 { capsule.transform = resting }
            CATransaction.commit()
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(visible ? 0.16 : 0.1)
        CATransaction.setAnimationTimingFunction(Self.easeOut)
        capsule.opacity = visible ? 1 : 0
        capsule.transform = visible ? CATransform3DIdentity : resting
        CATransaction.commit()
    }
}
