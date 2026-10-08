import CFloeCore
import Foundation
import Observation

/// Publishes compact frames at 30 Hz only when a visible effect needs them.
@MainActor
@Observable
final class VisualizationModel {
    var backgroundFailure: String?
    var backgroundFramesDrawn: UInt64 = 0
    private(set) var frame = SpectrumFrame.quiet
    private(set) var isRunning = false
    private(set) var framesAnalyzed: UInt64 = 0
    /// A clock in seconds that runs faster when the music is louder; drifting
    /// visuals use it so their pace follows the song. Frozen while analysis is off.
    private(set) var flow: Double = 0
    @ObservationIgnored private let worker = AnalysisWorker()
    @ObservationIgnored private var generation: UInt64 = 0

    func setRunning(_ running: Bool) {
        guard isRunning != running else { return }
        generation += 1
        isRunning = running
        if running {
            let generation = generation
            worker.start { [weak self] frame in
                guard let self, self.isRunning, self.generation == generation else { return }
                self.frame = frame
                self.framesAnalyzed += 1
                self.flow += (0.5 + min(1.5, Double(frame.rms) * 5)) / 30
            }
        } else { worker.stop() }
    }
}

/// All mutable DSP state belongs to this serial queue. The render callback only
/// writes the independent bounded Rust tap; no timers or FFT touch that callback.
private final class AnalysisWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.antonchurchyn.floe.analysis", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var analyzer: SpectrumAnalyzer?
    private var left = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var right = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var epoch: UInt64 = 0

    func start(deliver: @escaping @MainActor @Sendable (SpectrumFrame) -> Void) {
        queue.async { [self] in
            guard timer == nil else { return }
            if analyzer == nil { analyzer = SpectrumAnalyzer() }
            guard analyzer != nil else { return }
            analyzer?.reset()
            floe_set_analysis_enabled(true)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(4))
            timer.setEventHandler { [weak self] in
                guard let self, let analyzer = self.analyzer else { return }
                var epoch: UInt64 = 0
                let count = Int(floe_read_analysis(&self.left, &self.right, UInt32(SpectrumAnalyzer.size), &epoch))
                if epoch != self.epoch { analyzer.reset(); self.epoch = epoch }
                let frame = analyzer.process(left: self.left, right: self.right, count: count)
                DispatchQueue.main.async { deliver(frame) }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            floe_set_analysis_enabled(false)
        }
    }
}
