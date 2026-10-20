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

    func makeNSView(context: Context) -> BackgroundMetalView {
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
        view.delegate = nil
    }

    final class Coordinator { var renderer: BackgroundRenderer? }
}

/// A paused background still needs one fresh frame when the window is resized,
/// and a running one follows its window to the display it's on.
final class BackgroundMetalView: MTKView {
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
    /// One pipeline per kind (and Beams' haze and Bloom's fields), all compiled once when the view is made.
    struct Pipelines {
        let fluid: MTLRenderPipelineState
        let beams: MTLRenderPipelineState
        let haze: MTLRenderPipelineState
        let bloom: MTLRenderPipelineState
        let bloomField: MTLRenderPipelineState
        let bloomCrowd: MTLRenderPipelineState
    }
    /// Pixels per frame at most: a large window draws Beams at about one pixel
    /// per point, a small one at full Retina. The shaders pre-filter every line
    /// for the pixel size they get, so Core Animation's upscale stays smooth.
    /// Fluid has no hard edges anywhere, so it gets by with far fewer.
    /// Bloom iterates a fractal per pixel, so it stops at about one pixel per
    /// point of a large window; its filaments are pre-filtered like the beams.
    static func pixelBudget(_ kind: VisualSettings.BackgroundKind) -> CGFloat {
        switch kind {
        case .beams: 1_600_000
        case .fluid: 600_000
        case .bloom: 1_300_000
        }
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
                         haze: try pipeline("floeHazeFragment", Targets.hazeFormat),
                         bloom: try pipeline("floeBloomFragment", pixelFormat),
                         bloomField: try pipeline("floeBloomField", Targets.fieldFormat),
                         bloomCrowd: try pipeline("floeBloomCrowd", Targets.fieldFormat))
    }

    /// Beams' smoke and Bloom's crowding at a quarter of the drawable's
    /// resolution, with the passes that draw them, and Bloom's fields, each made
    /// again only when the drawable's size changes.
    final class Targets {
        static let hazeFormat = MTLPixelFormat.rg16Float
        static let fieldFormat = MTLPixelFormat.rgba16Float
        /// Bloom works out one block of its field in this many afresh each
        /// frame and carries the rest over: 8, or 16 while a deep, crowded
        /// stretch would cost more than the budget, and for a dive fading out
        /// under the next.
        private(set) var fieldTurns = 8
        /// Bloom's GPU time per frame, smoothed, in milliseconds.
        private var bloomCost = 0.0
        private let device: MTLDevice
        private var haze: MTLTexture?
        private var crowd: MTLTexture?
        /// What a dive found per pixel, last frame's and this one's in turn, and
        /// which dive of which rig drew the latest, through which view.
        private struct Field {
            let textures: [MTLTexture]
            let passes: [MTLRenderPassDescriptor]
            var latest = 0
            var frame = 0
            var drawn: (run: UInt64, dive: Int, view: BloomView)?
        }
        /// Two, so the next dive keeps its own while it fades in.
        private var fields: [Field?] = [nil, nil]
        private let smoke = Targets.quarterPass(), crowding = Targets.quarterPass()

        private static func quarterPass() -> MTLRenderPassDescriptor {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            return pass
        }

        init(device: MTLDevice) { self.device = device }

        /// The smoke texture for a drawable of this size, and the pass that renders into it.
        func haze(width: Int, height: Int) -> (texture: MTLTexture, pass: MTLRenderPassDescriptor)? {
            quarter(&haze, smoke, format: Self.hazeFormat, width: width, height: height)
        }

        /// Bloom's crowding texture for a drawable of this size, and the pass that renders into it.
        func crowd(width: Int, height: Int) -> (texture: MTLTexture, pass: MTLRenderPassDescriptor)? {
            quarter(&crowd, crowding, format: Self.fieldFormat, width: width, height: height)
        }

        private func quarter(_ texture: inout MTLTexture?, _ pass: MTLRenderPassDescriptor, format: MTLPixelFormat, width: Int, height: Int)
            -> (texture: MTLTexture, pass: MTLRenderPassDescriptor)? {
            let w = max(1, (width + 3) / 4), h = max(1, (height + 3) / 4)
            if let texture, texture.width == w, texture.height == h { return (texture, pass) }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
            pass.colorAttachments[0].texture = texture
            return texture.map { ($0, pass) }
        }

        /// This frame's field for the `dive`th dive of rig `run`, seen through
        /// `view` as the uniforms' `layer`: last frame's to carry over from, the
        /// pass that draws this frame's, and what that pass needs. After a resize,
        /// or for a dive not drawn last frame, every pixel is worked out afresh.
        func bloomField(run: UInt64, dive: Int, layer: Int, view: BloomView, turns: Int, width: Int, height: Int)
            -> (last: MTLTexture, next: MTLTexture, pass: MTLRenderPassDescriptor, uniforms: BloomPassUniforms)? {
            let slot = dive % 2
            if fields[slot].map({ $0.textures[0].width != width || $0.textures[0].height != height }) ?? true {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.fieldFormat, width: width, height: height, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                guard let first = device.makeTexture(descriptor: descriptor), let second = device.makeTexture(descriptor: descriptor) else { return nil }
                let passes = [first, second].map { texture in
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = texture
                    pass.colorAttachments[0].loadAction = .dontCare
                    pass.colorAttachments[0].storeAction = .store
                    return pass
                }
                fields[slot] = Field(textures: [first, second], passes: passes)
            }
            guard var field = fields[slot] else { return nil }
            var all: Int32 = 1, history = SIMD4<Float>(0, 0, 1, 0)
            if let drawn = field.drawn, drawn.run == run, drawn.dive == dive {
                // Screen point v now is where (offset − last offset + per-unit·v) / last per-unit was.
                let turn = view.perScreenUnit / drawn.view.perScreenUnit
                let shift = (view.offset - drawn.view.offset) / drawn.view.perScreenUnit
                // A jump further than the dive goes in a few frames is worked out
                // afresh: carried that far, the old field would show.
                if turn.magnitude > 0.95 && turn.magnitude < 1.05 && shift.magnitude < 0.25 {
                    all = 0
                    history = SIMD4(Float(shift.re), Float(shift.im), Float(turn.re), Float(turn.im))
                }
            }
            let last = field.textures[field.latest]
            field.latest = 1 - field.latest
            field.frame = all == 1 ? 0 : field.frame + 1
            field.drawn = (run, dive, view)
            fields[slot] = field
            return (last, field.textures[field.latest], field.passes[field.latest],
                    BloomPassUniforms(layer: Int32(layer), phase: Int32(field.frame % turns), all: all,
                                      turns: Int32(turns), history: history))
        }

        /// How long the GPU took over a Bloom frame: past about 2 ms, fresh
        /// blocks come half as often until the dive is cheaper again.
        func recordBloomFrame(milliseconds: Double) {
            bloomCost += (milliseconds - bloomCost) * 0.1
            if fieldTurns == 8, bloomCost > 2.2 { fieldTurns = 16 }
            else if fieldTurns == 16, bloomCost < 1.1 { fieldTurns = 8 }
        }

        /// Lets Bloom's fields go while another kind draws.
        func releaseFields() {
            if fields[0] != nil || fields[1] != nil { fields = [nil, nil] }
            crowd = nil
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
        if animator.configuration.kind != .bloom { targets.releaseFields() }
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
        case .bloom:
            var uniforms = animator.bloomUniforms(width: width, height: height)
            let rig = animator.bloom, views = rig.views
            // Each dive's field first, then how crowded it is, then the light from them.
            func field(_ layer: Int, dive: Int, view: BloomView, turns: Int) -> MTLTexture? {
                guard let target = targets.bloomField(run: rig.run, dive: dive, layer: layer, view: view, turns: turns,
                                                      width: Int(width), height: Int(height)),
                      let encoder = command.makeRenderCommandEncoder(descriptor: target.pass) else { return nil }
                var passUniforms = target.uniforms
                encoder.setRenderPipelineState(pipelines.bloomField)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BloomUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&passUniforms, length: MemoryLayout<BloomPassUniforms>.stride, index: 1)
                encoder.setFragmentTexture(target.last, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
                return target.next
            }
            let turns = targets.fieldTurns
            guard let current = field(0, dive: rig.dive, view: views.current, turns: rig.next == nil ? turns : 16) else { return false }
            let incoming = views.incoming.flatMap { field(1, dive: rig.dive + 1, view: $0, turns: turns) } ?? current
            guard let (crowd, crowding) = targets.crowd(width: Int(width), height: Int(height)),
                  let first = command.makeRenderCommandEncoder(descriptor: crowding) else { return false }
            first.setRenderPipelineState(pipelines.bloomCrowd)
            first.setFragmentTexture(current, index: 0)
            first.setFragmentTexture(incoming, index: 1)
            first.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            first.endEncoding()
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.setRenderPipelineState(pipelines.bloom)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BloomUniforms>.stride, index: 0)
            encoder.setFragmentTexture(current, index: 0)
            encoder.setFragmentTexture(incoming, index: 1)
            encoder.setFragmentTexture(crowd, index: 2)
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
    /// drifts and swells, and Bloom dives slowly, so half that looks the same at half the cost.
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
            let milliseconds = (command.gpuEndTime - command.gpuStartTime) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight -= 1
                if succeeded {
                    self.status?.backgroundFramesDrawn += 1
                    if self.animator.configuration.kind == .bloom { self.targets.recordBloomFrame(milliseconds: milliseconds) }
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
