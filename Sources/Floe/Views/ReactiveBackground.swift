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
                                strobe: settings.strobe, bloomQuality: settings.bloomQuality)
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
        /// Bloom's light while a step in its field's size crossfades.
        let bloomFading: MTLRenderPipelineState
        let bloomField: MTLRenderPipelineState
        let bloomStats: MTLRenderPipelineState
        let bloomSmooth: MTLRenderPipelineState
        let bloomSoft: MTLRenderPipelineState
    }
    /// Pixels per frame at most: a large window draws Beams at about one pixel
    /// per point, a small one at full Retina. The shaders pre-filter every line
    /// for the pixel size they get, so Core Animation's upscale stays smooth.
    /// Fluid has no hard edges anywhere, so it gets by with far fewer.
    /// Bloom's colour is cheap per pixel and its filaments are finer than any
    /// pre-filter could keep sharp through an upscale, so it draws at full
    /// Retina even full screen; only its fractal field stops at `bloomFieldBudget`.
    static func pixelBudget(_ kind: VisualSettings.BackgroundKind) -> CGFloat {
        switch kind {
        case .beams: 1_600_000
        case .fluid: 600_000
        case .bloom: 8_000_000
        }
    }
    /// Bloom iterates the fractal afresh for every pixel of its field every
    /// frame, so that stops at about a pixel per point of a full-screen window
    /// at High detail, and at a bit over half a pixel per point at Lighter;
    /// the colour is drawn from it at the drawable's full resolution.
    static func bloomFieldBudget(_ quality: VisualSettings.BloomQuality) -> Int {
        switch quality {
        case .high: 1_300_000
        case .lighter: 500_000
        }
    }

    /// The size of Bloom's field for a drawable of `width`×`height`: the same
    /// when it fits `budget`, else scaled down evenly to fit.
    static func bloomFieldSize(width: Int, height: Int, budget: Int) -> (width: Int, height: Int) {
        let area = width * height
        guard area > budget else { return (width, height) }
        let s = (Double(budget) / Double(area)).squareRoot()
        return (max(1, Int((Double(width) * s).rounded())), max(1, Int((Double(height) * s).rounded())))
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
        func pipeline(_ fragment: String, _ format: MTLPixelFormat, sizeFading: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "floeBackgroundVertex")
            var fading = sizeFading
            let constants = MTLFunctionConstantValues()
            constants.setConstantValue(&fading, type: .bool, index: 0)
            descriptor.fragmentFunction = try library.makeFunction(name: fragment, constantValues: constants)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        func soft() throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "floeBackgroundVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "floeBloomSoft")
            for (index, format) in Targets.softFormats.enumerated() { descriptor.colorAttachments[index].pixelFormat = format }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        return Pipelines(fluid: try pipeline("floeFluidFragment", pixelFormat), beams: try pipeline("floeBeamsFragment", pixelFormat),
                         haze: try pipeline("floeHazeFragment", Targets.hazeFormat),
                         bloom: try pipeline("floeBloomFragment", pixelFormat),
                         bloomFading: try pipeline("floeBloomFragment", pixelFormat, sizeFading: true),
                         bloomField: try pipeline("floeBloomField", Targets.fieldFormat),
                         bloomStats: try pipeline("floeBloomStats", Targets.statsFormat),
                         bloomSmooth: try pipeline("floeBloomSmooth", Targets.statsFormat),
                         bloomSoft: try soft())
    }

    /// Beams' smoke at a quarter of the drawable's resolution, with the pass
    /// that draws it, and Bloom's fields, each made again only when its size
    /// changes.
    final class Targets {
        static let hazeFormat = MTLPixelFormat.rg16Float
        static let fieldFormat = MTLPixelFormat.rgba16Float
        /// What the bands' light follows round each field pixel, before and after smoothing.
        static let statsFormat = MTLPixelFormat.rg16Float
        /// Bloom's smooth colour per dive: outside the set, inside it, the filaments'.
        static let softFormats: [MTLPixelFormat] = [.rg11b10Float, .rg11b10Float, .rgba16Float]
        /// What a dive found per pixel, what its light follows round them (at
        /// half the size, then smoothed), its smooth colour, and the passes
        /// that draw them.
        struct BloomField {
            let texture: MTLTexture
            let pass: MTLRenderPassDescriptor
            let stats: MTLTexture
            let statsPass: MTLRenderPassDescriptor
            let smooth: MTLTexture
            let smoothPass: MTLRenderPassDescriptor
            let soft: [MTLTexture]
            let softPass: MTLRenderPassDescriptor
        }
        /// Bloom's field shrinks a step, a share of its pixels, once a stretch
        /// of the dive has cost the GPU more than `costCeiling` a frame for
        /// `overloadFrames` frames running, and grows back once the bigger
        /// field would have cost under `costFloor` for `underloadFrames`. Each
        /// step crossfades from the old size over `fadeFrames` frames, so the
        /// light's sharpness never changes from one frame to the next.
        static let bloomShares = [1.0, 0.7, 0.5, 0.35, 0.25]
        /// Milliseconds of GPU time per Bloom frame.
        private static let costCeiling = 4.2, costFloor = 3.3
        /// Half a second, two seconds, and 0.37 s of frames at Bloom's 30 Hz.
        private static let overloadFrames = 15, underloadFrames = 60
        static let fadeFrames = 11
        private(set) var bloomShare = 0
        /// The share a step left, while its crossfade runs.
        private(set) var fadingShare: Int?
        private var fadeDrawn = 0
        private var overloaded = 0, underloaded = 0
        /// Bloom's GPU time per frame, smoothed, in milliseconds.
        private var bloomCost = 0.0
        private let device: MTLDevice
        private var haze: MTLTexture?
        private let smoke = MTLRenderPassDescriptor()
        /// Each dive's, this frame: two, so the next dive has its own while it
        /// fades in, and both again at the old size while a step crossfades.
        private var fields: [BloomField?] = [nil, nil, nil, nil]
        /// What each dive found per pixel last frame, for tests to read back.
        var fieldTextures: [MTLTexture?] { fields.map { $0?.texture } }

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

        /// The field of `width`×`height` kept in `slot`: the dive drawn as the
        /// uniforms' layer 0 or 1, plus 2 at the size a step is fading from.
        func bloomField(slot: Int, width: Int, height: Int) -> BloomField? {
            if let field = fields[slot], field.texture.width == width, field.texture.height == height { return field }
            let made = ([Self.fieldFormat] + Self.softFormats).compactMap { texture($0, width: width, height: height) }
            let half = [Self.statsFormat, Self.statsFormat].compactMap { texture($0, width: (width + 1) / 2, height: (height + 1) / 2) }
            guard made.count == 1 + Self.softFormats.count, half.count == 2 else { return nil }
            func pass(_ textures: ArraySlice<MTLTexture>) -> MTLRenderPassDescriptor {
                let pass = MTLRenderPassDescriptor()
                for (index, texture) in textures.enumerated() {
                    pass.colorAttachments[index].texture = texture
                    pass.colorAttachments[index].loadAction = .dontCare
                    pass.colorAttachments[index].storeAction = .store
                }
                return pass
            }
            fields[slot] = BloomField(texture: made[0], pass: pass(made[0...0]), stats: half[0], statsPass: pass(half[0...0]),
                                      smooth: half[1], smoothPass: pass(half[1...1]),
                                      soft: Array(made.dropFirst()), softPass: pass(made.dropFirst()))
            return fields[slot]
        }

        private func texture(_ format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }

        /// How long the GPU took over a Bloom frame. A crossfade's frames draw
        /// both sizes, so they don't count.
        func recordBloomFrame(milliseconds: Double) {
            guard fadingShare == nil else { return }
            bloomCost += (milliseconds - bloomCost) * 0.15
            let shares = Self.bloomShares
            overloaded = bloomCost > Self.costCeiling && bloomShare < shares.count - 1 ? overloaded + 1 : 0
            underloaded = bloomShare > 0 && bloomCost * shares[bloomShare - 1] / shares[bloomShare] < Self.costFloor ? underloaded + 1 : 0
            if overloaded >= Self.overloadFrames { step(to: bloomShare + 1) }
            else if underloaded >= Self.underloadFrames { step(to: bloomShare - 1) }
        }

        private func step(to share: Int) {
            bloomCost *= Self.bloomShares[share] / Self.bloomShares[bloomShare]
            (fadingShare, bloomShare, fadeDrawn, overloaded, underloaded) = (bloomShare, share, 0, 0, 0)
        }

        /// For the frame being drawn: how much of it the old size still draws
        /// while a step crossfades (eased from 1 to 0), else nil.
        func nextFade() -> Float? {
            guard fadingShare != nil else { return nil }
            fadeDrawn += 1
            guard fadeDrawn <= Self.fadeFrames else {
                fadingShare = nil
                fields[2] = nil
                fields[3] = nil
                return nil
            }
            let x = Float(fadeDrawn) / Float(Self.fadeFrames + 1)
            return 1 - x * x * (3 - 2 * x)
        }

        /// Lets Bloom's fields go while another kind draws.
        func releaseFields() {
            if fields.contains(where: { $0 != nil }) { fields = [nil, nil, nil, nil] }
        }
    }

    /// The pixels to draw for a view of `points` on a display of `scale`.
    static func drawableSize(points: CGSize, scale: CGFloat, kind: VisualSettings.BackgroundKind = .beams) -> CGSize {
        let area = max(1, points.width * points.height)
        let s = min(max(scale, 1), max(0.5, (pixelBudget(kind) / area).squareRoot()))
        return CGSize(width: max(1, (points.width * s).rounded()), height: max(1, (points.height * s).rounded()))
    }

    /// Encodes one frame of the animator's current state into `pass`.
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
            return true
        case .beams:
            return encodeBeams(command, pass: pass, pipelines: pipelines, targets: targets, animator: animator, width: width, height: height)
        case .bloom:
            return encodeBloom(command, pass: pass, pipelines: pipelines, targets: targets, animator: animator, width: width, height: height)
        }
    }

    /// Beams draws its smoke small first, then the light over it.
    private static func encodeBeams(_ command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, pipelines: Pipelines, targets: Targets,
                                    animator: BackgroundAnimator, width: Float, height: Float) -> Bool {
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

    /// Each dive's field and smooth colour, then the light from them at the
    /// drawable's size. While one dive hands over to the next, the fainter of
    /// the two is worked out at half the resolution; while the field's size
    /// steps, both dives are worked out at the old size too, fading out.
    private static func encodeBloom(_ command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, pipelines: Pipelines, targets: Targets,
                                    animator: BackgroundAnimator, width: Float, height: Float) -> Bool {
        var uniforms = animator.bloomUniforms(width: width, height: height)
        let fade = targets.nextFade()
        uniforms.view.w = fade ?? 0
        let rig = animator.bloom
        let budget = Double(bloomFieldBudget(animator.configuration.bloomQuality))
        func dive(_ layer: Int, faint: Bool, share: Int, slot: Int) -> Targets.BloomField? {
            let full = bloomFieldSize(width: Int(width), height: Int(height), budget: Int(budget * Targets.bloomShares[share]))
            let size = faint ? (width: max(1, full.width / 2), height: max(1, full.height / 2)) : full
            guard let target = targets.bloomField(slot: slot, width: size.width, height: size.height) else { return nil }
            return encodeDive(command, target: target, layer: layer, uniforms: &uniforms, pipelines: pipelines) ? target : nil
        }
        let handing = rig.next != nil
        func dives(share: Int, slots: Int) -> (Targets.BloomField, Targets.BloomField)? {
            guard let current = dive(0, faint: handing && rig.blend > 0.5, share: share, slot: slots) else { return nil }
            return (current, handing ? dive(1, faint: rig.blend <= 0.5, share: share, slot: slots + 1) ?? current : current)
        }
        guard let (current, next) = dives(share: targets.bloomShare, slots: 0) else { return false }
        let (fadingCurrent, fadingNext) = fade != nil ? targets.fadingShare.flatMap { dives(share: $0, slots: 2) } ?? (current, next) : (current, next)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(fade != nil ? pipelines.bloomFading : pipelines.bloom)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BloomUniforms>.stride, index: 0)
        // One by one: an array of them would be made anew every frame.
        func bind(_ field: Targets.BloomField, from first: Int) {
            encoder.setFragmentTexture(field.texture, index: first)
            for (index, texture) in field.soft.enumerated() { encoder.setFragmentTexture(texture, index: first + 1 + index) }
        }
        bind(current, from: 0)
        bind(next, from: 4)
        bind(fadingCurrent, from: 8)
        bind(fadingNext, from: 12)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// One dive's field, worked out afresh, then what its light follows round
    /// each pixel, smoothed, then its smooth colour from them.
    private static func encodeDive(_ command: MTLCommandBuffer, target: Targets.BloomField, layer: Int,
                                   uniforms: inout BloomUniforms, pipelines: Pipelines) -> Bool {
        var dive = BloomPassUniforms(layer: Int32(layer), pixel: 2 / Float(target.texture.height))
        guard let field = command.makeRenderCommandEncoder(descriptor: target.pass) else { return false }
        field.setRenderPipelineState(pipelines.bloomField)
        field.setFragmentBytes(&uniforms, length: MemoryLayout<BloomUniforms>.stride, index: 0)
        field.setFragmentBytes(&dive, length: MemoryLayout<BloomPassUniforms>.stride, index: 1)
        field.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        field.endEncoding()
        guard let stats = command.makeRenderCommandEncoder(descriptor: target.statsPass) else { return false }
        stats.setRenderPipelineState(pipelines.bloomStats)
        stats.setFragmentTexture(target.texture, index: 0)
        stats.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        stats.endEncoding()
        guard let smooth = command.makeRenderCommandEncoder(descriptor: target.smoothPass) else { return false }
        smooth.setRenderPipelineState(pipelines.bloomSmooth)
        smooth.setFragmentTexture(target.stats, index: 0)
        smooth.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        smooth.endEncoding()
        guard let soft = command.makeRenderCommandEncoder(descriptor: target.softPass) else { return false }
        soft.setRenderPipelineState(pipelines.bloomSoft)
        soft.setFragmentBytes(&uniforms, length: MemoryLayout<BloomUniforms>.stride, index: 0)
        soft.setFragmentBytes(&dive, length: MemoryLayout<BloomPassUniforms>.stride, index: 1)
        soft.setFragmentTexture(target.texture, index: 0)
        soft.setFragmentTexture(target.smooth, index: 1)
        soft.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        soft.endEncoding()
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
