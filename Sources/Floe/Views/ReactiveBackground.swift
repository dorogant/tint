import MetalKit
import QuartzCore
import SwiftUI

/// A Metal layer behind the glass, drawn in step with the display (up to 60 Hz)
/// at about one pixel per point. Its own clock freezes on pause and it never
/// recompiles the shaders per frame.
struct ReactiveBackground: NSViewRepresentable {
    /// The cover's colours, accent first.
    var colors: [RGB]
    /// A black-and-white or grey cover, drawn as clean white stage light.
    var neutral = false
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = BackgroundMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        // A drawable smaller than the Retina backing is filtered up, never blocky.
        view.layer?.magnificationFilter = .linear
        do {
            let renderer = try BackgroundRenderer(view: view, status: visualization)
            context.coordinator.renderer = renderer
            view.delegate = renderer
            view.onResize = { [weak renderer] in renderer?.redrawIfPaused() }
            view.onWindowChange = { [weak renderer] in renderer?.windowChanged() }
        } catch {
            DispatchQueue.main.async { visualization.backgroundFailure = L10n.string("Live background is unavailable on this Mac.") }
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
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

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        (view as? BackgroundMetalView)?.onResize = nil
        (view as? BackgroundMetalView)?.onWindowChange = nil
        coordinator.renderer?.stop()
        coordinator.renderer = nil
        view.delegate = nil
    }

    final class Coordinator { var renderer: BackgroundRenderer? }
}

/// A paused background still needs one fresh frame when the window is resized,
/// and a running one follows its window to the display it's on.
private final class BackgroundMetalView: MTKView {
    var onResize: (() -> Void)?
    var onWindowChange: (() -> Void)?
    private var lastSize = CGSize.zero

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        onResize?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

@MainActor
final class BackgroundRenderer: NSObject, MTKViewDelegate {
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
    static func pixelBudget(_ kind: VisualSettings.BackgroundKind) -> CGFloat {
        kind == .beams ? 1_600_000 : 600_000
    }
    /// Frames allowed on the GPU at once while running; paused draws wait for none.
    private static let maximumInFlight = 2
    private weak var view: MTKView?
    private weak var status: VisualizationModel?
    private let commandQueue: MTLCommandQueue
    private let pipelines: Pipelines
    private let targets: Targets
    private var link: CADisplayLink?
    private var timer: DispatchSourceTimer?
    private var rate: Float = 60
    private var animator = BackgroundAnimator()
    private var configured = false
    private var previous: CFTimeInterval?
    private var inFlight = 0
    private var needsStaticDraw = true

    init(view: MTKView, status: VisualizationModel) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        commandQueue = queue
        pipelines = try Self.makePipelines(device: device, pixelFormat: view.colorPixelFormat)
        targets = Targets(device: device)
        self.view = view
        self.status = status
        super.init()
        DispatchQueue.main.async { status.backgroundFailure = nil }
    }

    static func makePipelines(device: MTLDevice, pixelFormat: MTLPixelFormat) throws -> Pipelines {
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

    /// Scratch textures that follow the drawable's size: Beams' smoke at a quarter
    /// of its resolution.
    final class Targets {
        static let hazeFormat = MTLPixelFormat.rg16Float
        private let device: MTLDevice
        private var haze: MTLTexture?

        init(device: MTLDevice) { self.device = device }

        func haze(width: Int, height: Int) -> MTLTexture? {
            let w = max(1, (width + 3) / 4), h = max(1, (height + 3) / 4)
            if let haze, haze.width == w, haze.height == h { return haze }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.hazeFormat, width: w, height: h, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            haze = device.makeTexture(descriptor: descriptor)
            return haze
        }
    }

    /// The pixels to draw for a view of `points` on a display of `scale`.
    static func drawableSize(points: CGSize, scale: CGFloat, kind: VisualSettings.BackgroundKind = .beams) -> CGSize {
        let area = max(1, points.width * points.height)
        let s = min(max(scale, 1), max(0.5, (pixelBudget(kind) / area).squareRoot()))
        return CGSize(width: max(1, (points.width * s).rounded()), height: max(1, (points.height * s).rounded()))
    }

    /// Encodes one frame of the animator's current state: Beams first draws its
    /// smoke small, then the light over it into `pass`.
    @discardableResult
    static func encode(_ command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, pipelines: Pipelines, targets: Targets,
                       animator: BackgroundAnimator, width: Float, height: Float) -> Bool {
        switch animator.configuration.kind {
        case .fluid:
            var uniforms = animator.fluidUniforms(width: width, height: height)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.setRenderPipelineState(pipelines.fluid)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FluidUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        case .beams:
            var uniforms = animator.beamUniforms(width: width, height: height)
            guard let haze = targets.haze(width: Int(width), height: Int(height)) else { return false }
            let smoke = MTLRenderPassDescriptor()
            smoke.colorAttachments[0].texture = haze
            smoke.colorAttachments[0].loadAction = .dontCare
            smoke.colorAttachments[0].storeAction = .store
            guard let first = command.makeRenderCommandEncoder(descriptor: smoke) else { return false }
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
        }
        return true
    }

    func update(running: Bool, configuration: BackgroundConfiguration) {
        var changed = !configured || animator.configuration != configuration
        // A running palette change crossfades; paused (and Reduce Motion) ones apply at once.
        if changed { animator.configure(configuration, animated: running && configured) }
        configured = true
        guard running else {
            stop()
            if animator.settle() { changed = true }
            if changed || needsStaticDraw { redrawIfPaused() }
            return
        }
        if !isTicking {
            start()
        } else if rate != Self.frameRate(configuration.kind) {
            stop()
            start()
        }
    }

    private var isTicking: Bool { link != nil || timer != nil }

    /// Beams' punches and wobbles need every refresh up to 60 Hz; Fluid only
    /// drifts and swells, so half that looks the same at half the cost.
    private static func frameRate(_ kind: VisualSettings.BackgroundKind) -> Float { kind == .beams ? 60 : 30 }

    /// Frames come from the display's own clock, so each is shown for the same
    /// number of refreshes and motion doesn't judder against an unrelated timer.
    /// A view that isn't on screen yet gets a plain timer instead.
    private func start() {
        previous = nil
        rate = Self.frameRate(animator.configuration.kind)
        if let view, view.window?.isVisible == true {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / rate)), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                // The window came on screen: move over to its display's clock.
                if self.view?.window?.isVisible == true { self.stop(); self.start(); return }
                self.advance(to: CACurrentMediaTime())
            }
            self.timer = timer
            timer.resume()
        }
    }

    @objc private func tick(_ link: CADisplayLink) { advance(to: link.targetTimestamp) }

    /// New analysis is taken once per frame that arrived; the motion moves on by
    /// the display's own time step, so it's smooth between analysis frames.
    private func advance(to time: CFTimeInterval) {
        let dt = previous.map { Float(time - $0) } ?? 1 / 60
        previous = time
        if let frame = status?.takeFrame() { animator.receive(frame) }
        animator.step(by: dt)
        if inFlight < Self.maximumInFlight { view?.draw() }
    }

    /// The view moved to another window (or into its first): a running clock
    /// restarts on the right source.
    func windowChanged() {
        guard isTicking else { return }
        stop()
        start()
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.cancel()
        timer = nil
        previous = nil
    }

    func redrawIfPaused() {
        guard !isTicking else { return }
        needsStaticDraw = true
        if inFlight == 0 { view?.draw() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let limit = isTicking ? Self.maximumInFlight : 1
        guard inFlight < limit, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let size = Self.drawableSize(points: view.bounds.size, scale: view.window?.backingScaleFactor ?? 2,
                                     kind: animator.configuration.kind)
        if view.drawableSize != size { view.drawableSize = size }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = commandQueue.makeCommandBuffer(),
              Self.encode(command, pass: pass, pipelines: pipelines, targets: targets, animator: animator,
                          width: Float(size.width), height: Float(size.height))
        else { return }
        inFlight += 1
        needsStaticDraw = false
        command.present(drawable)
        command.addCompletedHandler { [weak self] command in
            let succeeded = command.status == .completed
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight -= 1
                if succeeded {
                    self.status?.backgroundFramesDrawn += 1
                    // A color/resize update can arrive while the last GPU frame
                    // is in flight. Draw its replacement once, without a timer.
                    if self.needsStaticDraw { self.redrawIfPaused() }
                }
                else { self.status?.backgroundFailure = L10n.string("Live background stopped unexpectedly."); self.stop() }
            }
        }
        command.commit()
    }
}
