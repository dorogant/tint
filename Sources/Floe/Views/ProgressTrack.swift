import AppKit
import SwiftUI

/// A slim capsule track with the elapsed part filled, like the system's media
/// scrubbers. Under the pointer the track thickens a little and a round thumb
/// grows out of the playhead; held, the thumb swells a touch more. Core
/// Animation glides the playhead between SwiftUI's once-a-second updates and
/// runs the springs, so playback and hovering cost no per-frame work in the app.
/// Seeks and drags jump instead of gliding. Paused, nothing animates.
struct ProgressTrack: NSViewRepresentable {
    var progress: Double
    var fill: Color
    var metrics: ProgressTrackView.Metrics
    /// Glide to the new playhead over the next second of playback; false while
    /// paused, scrubbing or with Reduce Motion.
    var glide: Bool
    var emphasis = ProgressTrackView.Emphasis.rest
    /// Reduce Motion: the track keeps its size and the thumb fades in instead of growing.
    var still = false

    func makeNSView(context: Context) -> ProgressTrackView { ProgressTrackView(metrics: metrics) }

    func updateNSView(_ view: ProgressTrackView, context: Context) {
        view.update(progress: progress, fill: NSColor(fill), glide: glide, emphasis: emphasis, still: still)
    }
}

final class ProgressTrackView: NSView {
    /// Track heights at rest and under the pointer, and the thumb's diameter.
    struct Metrics: Equatable {
        var track: CGFloat
        var activeTrack: CGFloat
        var thumb: CGFloat

        /// Now Playing.
        static let regular = Metrics(track: 5, activeTrack: 8, thumb: 14)
        /// The mini player; matches the volume slider beside it.
        static let compact = Metrics(track: 4, activeTrack: 6, thumb: 12)
    }

    enum Emphasis { case rest, hover, grab }

    private static let restTrack = NSColor(white: 1, alpha: 0.16)
    private static let activeTrack = NSColor(white: 1, alpha: 0.24)

    private let track = CALayer()
    private let fill = CALayer()
    private let thumb = CALayer()
    private let metrics: Metrics
    private var progress = 0.0
    private var emphasis = Emphasis.rest
    private var still = false
    private var laidOutSize = CGSize.zero

    init(metrics: Metrics = .regular) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        for layer in [track, fill, thumb] { self.layer?.addSublayer(layer) }
        track.backgroundColor = Self.restTrack.cgColor
        // The fill is its own capsule rather than a clipped rectangle, so no mask
        // is needed; its round end sits under the thumb when the thumb shows.
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        for layer in [track, fill] {
            layer.cornerCurve = .circular
            layer.bounds.size.height = metrics.track
            layer.cornerRadius = metrics.track / 2
        }
        thumb.bounds = CGRect(x: 0, y: 0, width: metrics.thumb, height: metrics.thumb)
        thumb.cornerRadius = metrics.thumb / 2
        thumb.backgroundColor = NSColor.white.cgColor
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.35
        thumb.shadowRadius = 3
        thumb.shadowOffset = CGSize(width: 0, height: -1)
        thumb.shadowPath = CGPath(ellipseIn: thumb.bounds, transform: nil)
        thumb.opacity = 0
        thumb.transform = restingThumb
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The playhead as drawn right now, for the self-test's motion check.
    var playheadOffset: Double { Double((fill.presentation() ?? fill).bounds.width) }

    func update(progress: Double, fill color: NSColor, glide: Bool, emphasis: Emphasis = .rest, still: Bool = false) {
        let progress = min(max(progress, 0), 1)
        let jump = abs(progress - self.progress) * bounds.width > 8
        self.progress = progress
        self.still = still
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = color.cgColor
        CATransaction.commit()
        placePlayhead(glide: glide && !jump)
        setEmphasis(emphasis)
    }

    /// Only a size change re-places the playhead; a layout pass alone would
    /// cut short its glide.
    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.position = CGPoint(x: bounds.midX, y: bounds.midY)
        track.bounds.size.width = bounds.width
        fill.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
        placePlayhead(glide: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [track, fill, thumb] { layer.contentsScale = scale }
    }

    /// The fill never gets narrower than it is tall, so the start of a song
    /// shows a dot rather than a squashed sliver.
    private func placePlayhead(glide: Bool) {
        let split = bounds.width * progress
        let width = min(bounds.width, max(fill.bounds.height, split))
        let from = (fill.presentation() ?? fill).bounds.width
        let thumbFrom = (thumb.presentation() ?? thumb).position.x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds.size.width = width
        thumb.position = CGPoint(x: split, y: bounds.midY)
        CATransaction.commit()
        guard glide else {
            fill.removeAnimation(forKey: "glide")
            thumb.removeAnimation(forKey: "glide")
            return
        }
        // Linear, so consecutive one-second glides join into steady motion.
        for (layer, key, value, target) in [(fill, "bounds.size.width", from, width),
                                            (thumb, "position.x", thumbFrom, split)] {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = value
            animation.toValue = target
            animation.duration = 1
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(animation, forKey: "glide")
        }
    }

    private var restingThumb: CATransform3D {
        let scale = still ? 1 : metrics.track / metrics.thumb
        return CATransform3DMakeScale(scale, scale, 1)
    }

    /// Short springs with no bounce, from wherever things are now, so quick
    /// passes over the bar retarget instead of queueing. With Reduce Motion
    /// only colour and the thumb's opacity change.
    private func setEmphasis(_ state: Emphasis) {
        guard state != emphasis else { return }
        let grows = state != .rest && emphasis == .rest
        emphasis = state
        let height = state == .rest || still ? metrics.track : metrics.activeTrack
        let thumbScale: CGFloat = switch state {
        case .rest: still ? 1 : metrics.track / metrics.thumb
        case .hover: 1
        case .grab: still ? 1 : 1.15
        }
        var changes: [(CALayer, String, Any, Any)] = []
        for layer in [track, fill] {
            let current = layer.presentation() ?? layer
            changes.append((layer, "bounds.size.height", current.bounds.height, height))
            changes.append((layer, "cornerRadius", current.cornerRadius, height / 2))
        }
        let currentScale = ((thumb.presentation() ?? thumb).value(forKeyPath: "transform.scale.x") as? CGFloat) ?? 1
        changes.append((thumb, "transform.scale", currentScale, thumbScale))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [track, fill] {
            layer.bounds.size.height = height
            layer.cornerRadius = height / 2
        }
        thumb.transform = CATransform3DMakeScale(thumbScale, thumbScale, 1)
        let fromOpacity = (thumb.presentation() ?? thumb).opacity
        thumb.opacity = state == .rest ? 0 : 1
        track.backgroundColor = (state == .rest ? Self.restTrack : Self.activeTrack).cgColor
        CATransaction.commit()
        // Near the start of a song the fill's width follows its height; elsewhere
        // re-placing would cut short the playhead's glide.
        if bounds.width * progress < metrics.activeTrack { placePlayhead(glide: false) }

        if !still {
            for (layer, key, from, to) in changes {
                let spring = CASpringAnimation(perceptualDuration: grows ? 0.2 : 0.26, bounce: 0)
                spring.keyPath = key
                spring.fromValue = from
                spring.toValue = to
                spring.duration = spring.settlingDuration
                layer.add(spring, forKey: key)
            }
        }
        // The thumb arrives quickly and leaves a little slower, so a small dot never lingers.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = thumb.opacity
        fade.duration = still ? 0.15 : (state == .rest ? 0.16 : 0.08)
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        thumb.add(fade, forKey: "opacity")
    }
}
