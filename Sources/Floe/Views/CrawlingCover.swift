import AppKit
import SwiftUI

/// The cover's scalloped mask and rim, run by Core Animation: the petals crawl
/// around an upright image while the edge breathes. Driving this from SwiftUI
/// re-rendered the whole window 20 times a second (~10% CPU); here the render
/// server does it, and SwiftUI updates only when the image, colour, size or
/// running state changes.
struct CrawlingCover: NSViewRepresentable {
    let image: CGImage
    let rim: NSColor
    let rimWidth: CGFloat
    let running: Bool
    let fade: Bool

    func makeNSView(context: Context) -> CrawlingCoverView { CrawlingCoverView() }

    func updateNSView(_ view: CrawlingCoverView, context: Context) {
        view.update(image: image, rim: rim, rimWidth: rimWidth, running: running, fade: fade)
    }
}

final class CrawlingCoverView: NSView {
    /// One petal crawls past in about a second, like the SwiftUI version.
    private static let turn: CFTimeInterval = 2 * .pi / 0.3
    /// The three-lobe ripple travels once around in this time.
    private static let breath: CFTimeInterval = 2 * .pi / 0.65

    private let content = CALayer()
    private let imageLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    private let rimLayer = CAShapeLayer()
    /// Hold the paths at the size they were built for and scale them to the
    /// current size while a resize is in flight.
    private let maskHost = CALayer()
    private let rimHost = CALayer()
    private var image: CGImage?
    private var running = false
    private var epoch: CFTimeInterval?
    private var pathSize: CGSize = .zero
    private var rimWidth: CGFloat = 0
    private var settle: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(content)
        content.addSublayer(imageLayer)
        content.addSublayer(rimHost)
        rimHost.addSublayer(rimLayer)
        maskHost.addSublayer(maskLayer)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.mask = maskHost
        rimLayer.fillColor = nil
        rimLayer.lineJoin = .round
        // Start frozen; `update` sets the clock running.
        content.speed = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The mask's on-screen rotation, for the self-test's motion check.
    var crawlAngle: Double {
        (maskLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
    }

    func update(image: CGImage, rim: NSColor, rimWidth: CGFloat, running: Bool, fade: Bool) {
        // Implicit animations would freeze halfway while the clock is paused, so
        // every change lands immediately; only a playing cover gets the crossfade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if image !== self.image {
            if fade && running && self.image != nil {
                let transition = CATransition()
                transition.type = .fade
                transition.duration = 0.35
                imageLayer.add(transition, forKey: "contents")
            }
            imageLayer.contents = image
            self.image = image
        }
        rimLayer.strokeColor = rim.cgColor
        self.rimWidth = rimWidth
        rimLayer.lineWidth = rimWidth / hostScale
        CATransaction.commit()
        setRunning(running)
    }

    /// How far the hosts currently stretch the paths (1 once they're rebuilt).
    private var hostScale: CGFloat { rimHost.sublayerTransform.m11 }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        imageLayer.frame = bounds
        for host in [maskHost, rimHost] { host.frame = bounds }
        for shape in [maskLayer, rimLayer] { shape.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2) }
        if pathSize == .zero {
            rebuild()
        } else if bounds.width > 0, bounds.height > 0 {
            // Scaling mid-flight is free on the render server; rebuilding the
            // paths every frame of the hero flight or the lyrics toggle was
            // main-thread work. Rebuild once the size has been still a moment.
            let scale = CATransform3DMakeScale(
                bounds.width / pathSize.width, bounds.height / pathSize.height, 1)
            if !CATransform3DEqualToTransform(scale, rimHost.sublayerTransform) {
                for host in [maskHost, rimHost] { host.sublayerTransform = scale }
                rimLayer.lineWidth = rimWidth / hostScale
                settle?.cancel()
                settle = bounds.size == pathSize ? nil : Task { @MainActor [weak self] in
                    guard (try? await Task.sleep(for: .seconds(0.15))) != nil else { return }
                    self?.rebuild()
                }
            }
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [content, imageLayer, maskHost, rimHost, maskLayer, rimLayer] { layer.contentsScale = scale }
    }

    /// Builds the paths at the current size and drops the stretch.
    private func rebuild() {
        settle?.cancel()
        settle = nil
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pathSize = bounds.size
        for host in [maskHost, rimHost] { host.sublayerTransform = CATransform3DIdentity }
        for shape in [maskLayer, rimLayer] {
            shape.bounds = CGRect(origin: .zero, size: pathSize)
            shape.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        }
        rimLayer.lineWidth = rimWidth
        installMotion()
        CATransaction.commit()
    }

    /// The petals turn with the mask (the image doesn't), and the ripple
    /// cycles through three phases. Both keep their place in time when the
    /// size changes mid-animation, e.g. during the hero flight.
    private func installMotion() {
        let rect = CGRect(origin: .zero, size: pathSize)
        let breaths = (0..<3).map { step in
            BlobShape(phase: Double(step) * 2 * .pi / 3).path(in: rect).cgPath
        }
        maskLayer.path = breaths[0]
        rimLayer.path = breaths[0]
        // A beginTime of exactly 0 means "now" to Core Animation, which would
        // restart the cycle on every resize; never hand it a 0.
        let now = content.convertTime(CACurrentMediaTime(), from: nil)
        let start = epoch ?? max(now, 1e-6)
        epoch = start
        for shape in [maskLayer, rimLayer] {
            let crawl = CABasicAnimation(keyPath: "transform.rotation.z")
            crawl.fromValue = 0
            crawl.toValue = -2 * Double.pi
            crawl.duration = Self.turn
            crawl.repeatCount = .infinity
            crawl.beginTime = start
            shape.add(crawl, forKey: "crawl")
            let breathe = CAKeyframeAnimation(keyPath: "path")
            breathe.values = breaths + [breaths[0]]
            breathe.duration = Self.breath
            breathe.repeatCount = .infinity
            breathe.beginTime = start
            shape.add(breathe, forKey: "breathe")
        }
    }

    private func setRunning(_ running: Bool) {
        guard running != self.running else { return }
        self.running = running
        running ? content.resumeClock() : content.pauseClock()
    }
}
