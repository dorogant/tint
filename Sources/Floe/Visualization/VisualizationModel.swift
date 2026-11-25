import CFloeCore
import Foundation
import Observation
import Synchronization

/// Publishes compact frames at 30 Hz only when a visible effect needs them.
///
/// Only `isRunning` and `backgroundFailure` are observed. Everything that
/// changes per frame is ignored by Observation, so no SwiftUI view can come to
/// depend on it and re-render the window 30 times a second; the visualizer
/// takes frames through `setFrameListener`, and the live background, which
/// draws on its own thread, straight from the analysis queue through `feed`.
@MainActor
@Observable
final class VisualizationModel {
    var backgroundFailure: String?
    private(set) var isRunning = false
    /// The live background's frames, handed over without the main thread.
    @ObservationIgnored let feed = BackgroundFeed()
    var backgroundFramesDrawn: UInt64 { feed.framesDrawn }
    @ObservationIgnored private(set) var frame = SpectrumFrame.quiet
    @ObservationIgnored private let counters = AnalysisCounters()
    var framesAnalyzed: UInt64 { counters.analyzed.load(ordering: .relaxed) }
    /// A clock in seconds that runs faster when the music is louder; drifting
    /// visuals use it so their pace follows the song. Frozen while analysis is off.
    @ObservationIgnored private(set) var flow: Double = 0
    @ObservationIgnored private let worker = AnalysisWorker()
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var listeners: [ObjectIdentifier: () -> Void] = [:]

    /// Calls `listener` on the main thread as each analysis frame arrives, so a
    /// view draws every frame once, in step with the analysis rather than on a
    /// clock of its own. One listener per owner; `nil` removes it.
    func setFrameListener(for owner: AnyObject, _ listener: (() -> Void)?) {
        listeners[ObjectIdentifier(owner)] = listener
        let needed = !listeners.isEmpty || UserDefaults.standard.bool(forKey: "FloeSelfTest")
        counters.needsMainDelivery.store(needed, ordering: .relaxed)
    }

    func setRunning(_ running: Bool) {
        guard isRunning != running else { return }
        generation += 1
        isRunning = running
        if running {
            let generation = generation
            worker.start(feed: feed, counters: counters) { [weak self] frame in
                guard let self, self.isRunning, self.generation == generation else { return }
                self.frame = frame
                self.flow += (0.5 + min(1.5, Double(frame.rms) * 5)) / 30
                for listener in self.listeners.values { listener() }
            }
        } else {
            worker.stop()
        }
    }
}

/// Shared atomics between the main actor and `AnalysisWorker` so frames stay
/// off the main thread when only the live background is listening.
private final class AnalysisCounters: Sendable {
    let analyzed = Atomic<UInt64>(0)
    let needsMainDelivery = Atomic<Bool>(UserDefaults.standard.bool(forKey: "FloeSelfTest"))
}

/// All mutable DSP state belongs to this serial queue. The render callback only
/// writes the independent bounded Rust tap; no timers or FFT touch that callback.
/// Unchecked because every stored property is read and written only on `queue`
/// (`start` and `stop` hop onto it, and the timer fires on it).
private final class AnalysisWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.antonchurchyn.floe.analysis", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var analyzer: SpectrumAnalyzer?
    private var left = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var right = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var epoch: UInt64 = 0
    private var feed: BackgroundFeed?

    func start(feed: BackgroundFeed, counters: AnalysisCounters,
               deliver: @escaping @MainActor @Sendable (SpectrumFrame) -> Void) {
        queue.async { [self] in
            guard timer == nil else { return }
            if analyzer == nil { analyzer = SpectrumAnalyzer() }
            guard analyzer != nil else { return }
            analyzer?.reset()
            feed.clear()
            self.feed = feed
            floe_set_analysis_enabled(true)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(4))
            timer.setEventHandler { [weak self] in
                guard let self, let analyzer = self.analyzer else { return }
                var epoch: UInt64 = 0
                let count = Int(floe_read_analysis(&self.left, &self.right, UInt32(SpectrumAnalyzer.size), &epoch))
                if epoch != self.epoch { analyzer.reset(); self.epoch = epoch }
                let frame = analyzer.process(left: self.left, right: self.right, count: count)
                counters.analyzed.add(1, ordering: .relaxed)
                self.feed?.post(frame)
                if counters.needsMainDelivery.load(ordering: .relaxed) {
                    DispatchQueue.main.async { deliver(frame) }
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            // After the last frame this queue will post, so none is left for the next song.
            feed?.clear()
            floe_set_analysis_enabled(false)
        }
    }
}
