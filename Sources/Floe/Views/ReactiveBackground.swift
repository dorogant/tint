import MetalKit
import SwiftUI

/// A low-resolution Metal layer stretched behind the glass, drawing at 30 Hz.
/// Its own clock freezes on pause and never recompiles the shader per frame.
struct ReactiveBackground: NSViewRepresentable {
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings
    @Environment(\.coverPalette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        do {
            let renderer = try BackgroundRenderer(view: view, status: visualization)
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } catch {
            DispatchQueue.main.async { visualization.backgroundFailure = L10n.string("Live background is unavailable on this Mac.") }
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        // The renderer reads each analysis frame itself; observing it here would
        // put the whole window through a SwiftUI update 30 times a second.
        context.coordinator.renderer?.update(running: visualization.isRunning, color: palette.rgb,
                                            reactivity: Float(settings.reactivity))
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.stop()
        coordinator.renderer = nil
        view.delegate = nil
    }

    final class Coordinator { var renderer: BackgroundRenderer? }
}

@MainActor
final class BackgroundRenderer: NSObject, MTKViewDelegate {
    enum Failure: Error { case unavailable }
    private struct Uniforms {
        var color = SIMD4<Float>(0, 0, 0, 1)
        var motion = SIMD4<Float>(0, 0, 1, 0)
        var size = SIMD4<Float>(512, 320, 0, 0)
        var beams = (SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>())
    }
    private static let beamCount = 12
    private weak var view: MTKView?
    private weak var status: VisualizationModel?
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var timer: DispatchSourceTimer?
    private var uniforms = Uniforms()
    /// Beam targets from the newest analysis frame; each tick eases toward them.
    private var targets = [Float](repeating: 0, count: beamCount)
    private var levels = [Float](repeating: 0, count: beamCount)
    private var bass: Float = 0
    private var time: Float = 0
    private var previous: Date?
    private var busy = false

    init(view: MTKView, status: VisualizationModel) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        commandQueue = queue
        let library = try device.makeLibrary(source: ReactiveShader.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "floeBackgroundVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "floeBackgroundFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.view = view
        self.status = status
        super.init()
        DispatchQueue.main.async { status.backgroundFailure = nil }
    }

    func update(running: Bool, color: RGB, reactivity: Float) {
        uniforms.color = SIMD4(Float(color.r), Float(color.g), Float(color.b), 1)
        uniforms.motion.z = reactivity
        guard running else {
            stop()
            if time == 0 { view?.draw() } // one static frame for Reduce Motion / paused startup
            return
        }
        guard timer == nil else { return }
        previous = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            if let previous = self.previous { self.time += Float(now.timeIntervalSince(previous)) }
            self.previous = now
            self.uniforms.motion.x = self.time
            if let frame = self.status?.frame { self.aim(at: frame) }
            self.ease()
            self.view?.draw()
        }
        self.timer = timer
        timer.resume()
    }

    private func aim(at frame: SpectrumFrame) {
        uniforms.motion.y = min(1, max(0, frame.rms * 6))
        // Six band groups per side, mirrored so bass lights the middle beams. The
        // levels adapt to each song, so every group's hits make its beams flare.
        let half = Self.beamCount / 2
        let group = max(1, frame.levels.count / half)
        for g in 0..<half {
            let slice = frame.levels.dropFirst(g * group).prefix(group)
            let level = slice.reduce(0, +) / Float(max(1, slice.count))
            targets[half - 1 - g] = level
            targets[half + g] = level
        }
    }

    /// Quick attack, slower release: beams flare on hits and fall back smoothly.
    private func ease() {
        for i in levels.indices {
            levels[i] += (targets[i] - levels[i]) * (targets[i] > levels[i] ? 0.55 : 0.14)
        }
        let low = (targets[Self.beamCount / 2 - 1] + targets[Self.beamCount / 2]) / 2
        bass += (low - bass) * (low > bass ? 0.6 : 0.12)
        uniforms.motion.w = bass
        uniforms.beams = (SIMD4(levels[0], levels[1], levels[2], levels[3]),
                          SIMD4(levels[4], levels[5], levels[6], levels[7]),
                          SIMD4(levels[8], levels[9], levels[10], levels[11]))
    }

    func stop() {
        timer?.cancel()
        timer = nil
        previous = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !busy, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let aspect = view.bounds.height / view.bounds.width
        let size = CGSize(width: 512, height: max(160, min(640, 512 * aspect)))
        if view.drawableSize != size { view.drawableSize = size }
        uniforms.size = SIMD4(Float(size.width), Float(size.height), 0, 0)
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = commandQueue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        busy = true
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.addCompletedHandler { [weak self] command in
            let succeeded = command.status == .completed
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                if succeeded { self.status?.backgroundFramesDrawn += 1 }
                else { self.status?.backgroundFailure = L10n.string("Live background stopped unexpectedly."); self.stop() }
            }
        }
        command.commit()
    }
}
