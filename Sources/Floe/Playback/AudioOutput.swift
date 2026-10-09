import AVFoundation
import CFloeCore
import os

/// Pulls PCM from the Rust core into AVAudioEngine. Volume is applied here;
/// the analysis tap sits in the core, before this volume.
@MainActor
final class AudioOutput {
    /// Built on the first `start()`: wiring the graph to the output device takes
    /// ~50 ms of main thread, which launch doesn't need to pay before any audio.
    private var engine: AVAudioEngine?
    private var wantsRunning = false
    private var configObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "audio")

    /// Linear gain; kept here until the graph exists.
    var volume: Float = 1 {
        didSet { engine?.mainMixerNode.outputVolume = volume }
    }

    func start() {
        wantsRunning = true
        let engine = engine ?? makeEngine()
        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            log.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pausing the engine stops the render callback entirely (≈0% CPU when idle).
    func pause() {
        wantsRunning = false
        engine?.pause()
    }

    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        // librespot always decodes to 44.1 kHz stereo; the mixer resamples to the device.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let source = Self.makeSourceNode(format: format)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        // Output device changes (headphones, AirPods) stop the engine; resume if we were playing.
        // The observer runs on the main queue, so it is on the main actor.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfNeeded() }
        }
        self.engine = engine
        return engine
    }

    private func restartIfNeeded() {
        guard wantsRunning else { return }
        start()
    }

    /// Built outside the main actor on purpose: the render block runs on Core Audio's
    /// real-time thread and must not inherit main-actor isolation checks.
    private nonisolated static func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { @Sendable isSilence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            if floe_render(left, right, frameCount) == 0 {
                isSilence.pointee = true
            }
            return noErr
        }
    }
}
