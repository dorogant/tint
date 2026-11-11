import AppKit
import Metal
import QuartzCore
import SwiftUI
import Synchronization

/// A Metal layer behind the glass, drawn in step with the display (up to 60 Hz)
/// at about one pixel per point, on a thread of its own. Its clock freezes on
/// pause and it never recompiles the shaders per frame.
struct ReactiveBackground: NSViewRepresentable {
    /// The cover's colours, accent first.
    var colors: [RGB]
    /// A black-and-white or grey cover, drawn as clean white stage light.
    var neutral = false
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BackgroundMetalView {
        let view = BackgroundMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        do {
            context.coordinator.renderer = try BackgroundRenderer(view: view, status: visualization)
        } catch {
            DispatchQueue.main.async { visualization.backgroundFailure = L10n.string("Live background is unavailable on this Mac.") }
        }
        return view
    }

    func updateNSView(_ view: BackgroundMetalView, context: Context) {
        // The renderer reads each analysis frame itself; observing it here would
        // put the whole window through a SwiftUI update 30 times a second.
        context.coordinator.renderer?.update(running: visualization.isRunning, configuration: configuration)
    }

    private var configuration: BackgroundConfiguration {
        BackgroundConfiguration(kind: settings.backgroundKind, colors: colors, neutral: neutral,
                                reactivity: Float(settings.reactivity), speed: Float(settings.motionSpeed),
                                glow: Float(settings.glow), punch: Float(settings.punch),
                                vividness: Float(settings.vividness), beamCount: settings.beamCount,
                                strobe: settings.strobe)
    }

    static func dismantleNSView(_ view: BackgroundMetalView, coordinator: Coordinator) {
        view.onResize = nil
        view.onWindowChange = nil
        coordinator.renderer?.stop()
        coordinator.renderer = nil
    }

    final class Coordinator { var renderer: BackgroundRenderer? }
}

/// The view the background's Metal layer lives in. It draws nothing itself: it
/// tells the renderer its size, its display's scale and when its window changes.
final class BackgroundMetalView: NSView {
    let metalLayer = CAMetalLayer()
    var onResize: (() -> Void)?
    var onWindowChange: (() -> Void)?
    private var lastSize = CGSize.zero

    init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        // A drawable smaller than the Retina backing is filtered up, never blocky.
        metalLayer.magnificationFilter = .linear
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { metalLayer }

    /// The pixels of the frame last asked for.
    var drawableSize: CGSize { metalLayer.drawableSize }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        onResize?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onResize?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

/// The main thread's side of the live background: what SwiftUI and the view
/// tell it goes to `RenderLoop`, which owns the motion and draws every frame on
/// its own thread. A busy interface (a page being built, a list scrolling)
/// therefore can't make the background drop frames. Measured in a real window
/// with the main thread blocked for half a second: Beams showed all 30 of its
/// frames, where it showed none before.
@MainActor
final class BackgroundRenderer {
    enum Failure: Error { case unavailable }
    /// One pipeline per kind (and Beams' haze), all compiled once when the view is made.
    struct Pipelines {
        let fluid: MTLRenderPipelineState
        let beams: MTLRenderPipelineState
        let haze: MTLRenderPipelineState
    }
    /// Pixels per frame at most: a large window draws Beams at about one pixel
    /// per point, a small one at full Retina. The shaders pre-filter every line
    /// for the pixel size they get, so Core Animation's upscale stays smooth.
    /// Fluid has no hard edges anywhere, so it gets by with far fewer.
    nonisolated static func pixelBudget(_ kind: VisualSettings.BackgroundKind) -> CGFloat {
        switch kind {
        case .beams: 1_600_000
        case .fluid: 600_000
        }
    }

    private enum Clock { case link, timer }
    private weak var view: BackgroundMetalView?
    private weak var status: VisualizationModel?
    private let loop: RenderLoop
    /// What `update` was last asked for. SwiftUI asks again on every update of
    /// the backdrop; only a change is passed on to the render thread.
    private var request: (running: Bool, configuration: BackgroundConfiguration)?
    private var clock: Clock?
    private var rate: Float = 60
    /// While the frames come from a timer: looks for the window coming on screen.
    private var watch: Timer?

    init(view: BackgroundMetalView, status: VisualizationModel) throws {
        guard let device = view.metalLayer.device, let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        let pipelines = try Self.makePipelines(device: device, pixelFormat: view.metalLayer.pixelFormat)
        loop = RenderLoop(layer: view.metalLayer, commandQueue: queue, pipelines: pipelines,
                          targets: Targets(device: device), feed: status.feed)
        self.view = view
        self.status = status
        loop.onFailure = { [weak self] in
            DispatchQueue.main.async { self?.failed() }
        }
        view.onResize = { [weak self] in self?.layoutChanged() }
        view.onWindowChange = { [weak self] in self?.windowChanged() }
        layoutChanged()
        DispatchQueue.main.async { status.backgroundFailure = nil }
    }

    deinit { loop.shutDown() }

    nonisolated static func makePipelines(device: MTLDevice, pixelFormat: MTLPixelFormat) throws -> Pipelines {
        let library = try device.makeLibrary(source: ReactiveShader.source, options: nil)
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "floeBackgroundVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        return Pipelines(fluid: try pipeline("floeFluidFragment", pixelFormat), beams: try pipeline("floeBeamsFragment", pixelFormat),
                         haze: try pipeline("floeHazeFragment", Targets.hazeFormat))
    }

    /// Beams' smoke at a quarter of the drawable's resolution, with the pass
    /// that draws it, made again only when its size changes.
    final class Targets {
        static let hazeFormat = MTLPixelFormat.rg16Float
        private let device: MTLDevice
        private var haze: MTLTexture?
        private let smoke = MTLRenderPassDescriptor()

        init(device: MTLDevice) {
            self.device = device
            smoke.colorAttachments[0].loadAction = .dontCare
            smoke.colorAttachments[0].storeAction = .store
        }

        /// The smoke texture for a drawable of this size, and the pass that renders into it.
        func haze(width: Int, height: Int) -> (texture: MTLTexture, pass: MTLRenderPassDescriptor)? {
            let w = max(1, (width + 3) / 4), h = max(1, (height + 3) / 4)
            if let haze, haze.width == w, haze.height == h { return (haze, smoke) }
            haze = texture(Self.hazeFormat, width: w, height: h)
            smoke.colorAttachments[0].texture = haze
            return haze.map { ($0, smoke) }
        }

        private func texture(_ format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
    }

    /// The pixels to draw for a view of `points` on a display of `scale`.
    nonisolated static func drawableSize(points: CGSize, scale: CGFloat, kind: VisualSettings.BackgroundKind = .beams) -> CGSize {
        let area = max(1, points.width * points.height)
        let s = min(max(scale, 1), max(0.5, (pixelBudget(kind) / area).squareRoot()))
        return CGSize(width: max(1, (points.width * s).rounded()), height: max(1, (points.height * s).rounded()))
    }

    /// Encodes one frame of the animator's current state into `pass`.
    @discardableResult
    nonisolated static func encode(_ command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, pipelines: Pipelines, targets: Targets,
                                   animator: BackgroundAnimator, width: Float, height: Float) -> Bool {
        switch animator.configuration.kind {
        case .fluid:
            var uniforms = animator.fluidUniforms(width: width, height: height)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.setRenderPipelineState(pipelines.fluid)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FluidUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return true
        case .beams:
            return encodeBeams(command, pass: pass, pipelines: pipelines, targets: targets, animator: animator, width: width, height: height)
        }
    }

    /// Beams draws its smoke small first, then the light over it.
    private nonisolated static func encodeBeams(_ command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, pipelines: Pipelines,
                                                targets: Targets, animator: BackgroundAnimator, width: Float, height: Float) -> Bool {
        var uniforms = animator.beamUniforms(width: width, height: height)
        guard let (haze, smoke) = targets.haze(width: Int(width), height: Int(height)),
              let first = command.makeRenderCommandEncoder(descriptor: smoke) else { return false }
        first.setRenderPipelineState(pipelines.haze)
        first.setFragmentBytes(&uniforms, length: MemoryLayout<BeamUniforms>.stride, index: 0)
        first.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        first.endEncoding()
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipelines.beams)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BeamUniforms>.stride, index: 0)
        encoder.setFragmentTexture(haze, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    func update(running: Bool, configuration: BackgroundConfiguration) {
        if let request, request.running == running, request.configuration == configuration { return }
        let changed = request?.configuration != configuration
        request = (running, configuration)
        // A running palette change crossfades; paused (and Reduce Motion) ones apply at once.
        if changed { loop.perform { $0.configure(configuration, animated: running) } }
        guard running else {
            stopClock()
            loop.perform { $0.rest(changed: changed) }
            return
        }
        if clock == nil {
            startClock()
        } else if rate != Self.frameRate(configuration.kind) {
            stopClock()
            startClock()
        }
    }

    /// Beams' punches and wobbles need every refresh up to 60 Hz; Fluid only
    /// drifts and swells, so half that looks the same at half the cost.
    private static func frameRate(_ kind: VisualSettings.BackgroundKind) -> Float { kind == .beams ? 60 : 30 }

    /// Frames come from the display's own clock, so each is shown for the same
    /// number of refreshes and motion doesn't judder against an unrelated timer.
    /// The link is made here, where the view may be asked for it, and then
    /// runs on the render thread. A view that isn't on screen yet gets a plain
    /// timer there instead.
    private func startClock() {
        guard let configuration = request?.configuration else { return }
        let rate = Self.frameRate(configuration.kind)
        self.rate = rate
        if let view, view.window?.isVisible == true {
            let link = view.displayLink(target: loop, selector: #selector(RenderLoop.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: rate, preferred: rate)
            clock = .link
            // Handed over whole: nothing here touches the link again.
            nonisolated(unsafe) let handed = link
            loop.perform { $0.run(on: handed) }
        } else {
            clock = .timer
            loop.perform { $0.run(every: 1 / Double(rate)) }
            let watch = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
                let alive = MainActor.assumeIsolated {
                    guard let self else { return false }
                    // The window came on screen: move over to its display's clock.
                    if self.view?.window?.isVisible == true { self.windowChanged() }
                    return true
                }
                if !alive { timer.invalidate() }
            }
            RunLoop.main.add(watch, forMode: .common)
            self.watch = watch
        }
    }

    private func stopClock() {
        watch?.invalidate()
        watch = nil
        guard clock != nil else { return }
        clock = nil
        loop.perform { $0.halt() }
    }

    /// The view moved to another window (or into its first), or its window came
    /// on screen: a running clock restarts on the right source.
    func windowChanged() {
        layoutChanged()
        guard clock != nil else { return }
        stopClock()
        startClock()
    }

    /// The render thread can't ask the view for its size, so it is told. A
    /// paused background draws one fresh frame at the new size.
    private func layoutChanged() {
        guard let view else { return }
        let points = view.bounds.size, scale = view.window?.backingScaleFactor ?? 2
        loop.perform { $0.resize(points: points, scale: scale) }
    }

    /// Stops drawing. The next `update` starts from nothing, as the first did.
    func stop() {
        stopClock()
        request = nil
    }

    private func failed() {
        status?.backgroundFailure = L10n.string("Live background stopped unexpectedly.")
        stop()
    }

    /// Frames the render thread tried to draw, and the last texture it presented
    /// (kept only when the layer's textures can be read back). For the tests.
    var drawAttempts: Int { loop.attempts.load(ordering: .relaxed) }
    var lastTexture: MTLTexture? { loop.lastPresented }
}

/// The live background's own thread: its display link, the motion and every
/// draw. Unchecked because everything mutable here is touched only on that
/// thread, which is what `perform` and the link's callback run on. The
/// exceptions are the atomics, which a finished frame updates from Metal's
/// thread, and `presented`, which has a lock.
final class RenderLoop: NSObject, @unchecked Sendable {
    /// Frames allowed on the GPU at once while running; paused draws wait for none.
    private static let maximumInFlight = 2
    private let layer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let pipelines: BackgroundRenderer.Pipelines
    private let targets: BackgroundRenderer.Targets
    private let feed: BackgroundFeed
    private let runLoop: CFRunLoop
    private let pass = MTLRenderPassDescriptor()
    /// Set once, before the first frame.
    fileprivate var onFailure: (@Sendable () -> Void)?

    private var animator = BackgroundAnimator()
    private var configured = false
    private var link: CADisplayLink?
    private var timer: Timer?
    private var previous: CFTimeInterval?
    private var points = CGSize.zero
    private var scale: CGFloat = 2
    private var needsStaticDraw = true

    private let inFlight = Atomic<Int>(0)
    /// A still frame was asked for while another was on the GPU: draw it when that one is done.
    private let stillPending = Atomic<Bool>(false)
    fileprivate let attempts = Atomic<Int>(0)
    private let presentedLock = NSLock()
    private var presented: MTLTexture?
    fileprivate var lastPresented: MTLTexture? { presentedLock.withLock { presented } }

    fileprivate init(layer: CAMetalLayer, commandQueue: MTLCommandQueue, pipelines: BackgroundRenderer.Pipelines,
                     targets: BackgroundRenderer.Targets, feed: BackgroundFeed) {
        self.layer = layer
        self.commandQueue = commandQueue
        self.pipelines = pipelines
        self.targets = targets
        self.feed = feed
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        runLoop = Self.startThread()
        super.init()
    }

    /// A thread that sleeps in its run loop until a link, a timer or `perform`
    /// has work for it. It costs nothing while the background is paused.
    private static func startThread() -> CFRunLoop {
        final class Started: @unchecked Sendable { var runLoop: CFRunLoop? }
        let started = Started(), ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            started.runLoop = CFRunLoopGetCurrent()
            // A run loop with nothing in it returns at once; this never fires.
            RunLoop.current.add(Timer(fire: .distantFuture, interval: 0, repeats: false) { _ in }, forMode: .common)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.antonchurchyn.floe.background"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return started.runLoop!
    }

    /// Runs `work` on the render thread, after everything asked before it.
    fileprivate func perform(_ work: @escaping @Sendable (RenderLoop) -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in work(self) }
        CFRunLoopWakeUp(runLoop)
    }

    /// Ends the thread. The link holds this object until it is invalidated there.
    fileprivate func shutDown() {
        perform {
            $0.halt()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    // MARK: On the render thread

    fileprivate func configure(_ configuration: BackgroundConfiguration, animated: Bool) {
        animator.configure(configuration, animated: animated && configured)
        configured = true
    }

    fileprivate func resize(points: CGSize, scale: CGFloat) {
        guard points != self.points || scale != self.scale else { return }
        self.points = points
        self.scale = scale
        redrawIfPaused()
    }

    fileprivate func run(on link: CADisplayLink) {
        halt()
        link.add(to: .current, forMode: .common)
        self.link = link
    }

    fileprivate func run(every interval: TimeInterval) {
        halt()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.advance(to: CACurrentMediaTime()) }
        timer.tolerance = 0.002
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    fileprivate func halt() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        previous = nil
    }

    /// Paused: the motion comes to rest and one still frame shows it.
    fileprivate func rest(changed: Bool) {
        halt()
        if animator.settle() || changed || needsStaticDraw { redrawIfPaused() }
    }

    private var isTicking: Bool { link != nil || timer != nil }

    @objc fileprivate func tick(_ link: CADisplayLink) { advance(to: link.targetTimestamp) }

    /// New analysis is taken once per frame that arrived; the motion moves on by
    /// the display's own time step, so it's smooth between analysis frames.
    private func advance(to time: CFTimeInterval) {
        let dt = previous.map { Float(time - $0) } ?? 1 / 60
        previous = time
        if let frame = feed.take() { animator.receive(frame) }
        animator.step(by: dt)
        draw()
    }

    private func redrawIfPaused() {
        // The size arrives before the first colours do; there's nothing to show until both have.
        guard configured, !isTicking else { return }
        needsStaticDraw = true
        // Before looking at the GPU, so the frame that is on it can't finish unseen in between.
        stillPending.store(true, ordering: .sequentiallyConsistent)
        if inFlight.load(ordering: .sequentiallyConsistent) == 0 { draw() }
    }

    private func draw() {
        attempts.add(1, ordering: .relaxed)
        let limit = isTicking ? Self.maximumInFlight : 1
        guard inFlight.load(ordering: .sequentiallyConsistent) < limit, points.width > 0, points.height > 0 else { return }
        let size = BackgroundRenderer.drawableSize(points: points, scale: scale, kind: animator.configuration.kind)
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable(), let command = commandQueue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].texture = drawable.texture
        defer { pass.colorAttachments[0].texture = nil }
        guard BackgroundRenderer.encode(command, pass: pass, pipelines: pipelines, targets: targets, animator: animator,
                                        width: Float(size.width), height: Float(size.height))
        else { return }
        inFlight.add(1, ordering: .sequentiallyConsistent)
        needsStaticDraw = false
        stillPending.store(false, ordering: .sequentiallyConsistent)
        if !layer.framebufferOnly { presentedLock.withLock { presented = drawable.texture } }
        command.present(drawable)
        command.addCompletedHandler { [weak self] command in self?.finished(command.status == .completed) }
        command.commit()
    }

    /// On Metal's thread, when a frame has left the GPU.
    private func finished(_ succeeded: Bool) {
        inFlight.subtract(1, ordering: .sequentiallyConsistent)
        guard succeeded else {
            perform { $0.halt() }
            onFailure?()
            return
        }
        feed.countFrame()
        // A colour or size change can arrive while the last frame is on the GPU.
        // Its replacement is drawn once, without a clock.
        if stillPending.load(ordering: .sequentiallyConsistent) {
            perform { if $0.needsStaticDraw { $0.redrawIfPaused() } }
        }
    }
}
