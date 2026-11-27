import AVFoundation
import Synchronization
import os

/// Sound on its way from the tap on Soloist to Tint's own output: one thread
/// writes (Core Audio's, for the tap), one reads (Core Audio's, for the output),
/// and neither ever waits for the other or allocates.
///
/// The reader holds back a cushion before it plays, so the two threads' turns
/// can come in any order without it running dry: one tap delivery plus 1024
/// frames, about 32 ms at 48 kHz. That is the delay the equalizer adds.
final class AudioRing: @unchecked Sendable {
    static let capacity = 1 << 15
    private static let mask = capacity - 1
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    /// Frames written so far; the writer's alone to change, and it only grows.
    private let written = Atomic<Int>(0)
    /// The largest delivery so far, which the cushion has to cover.
    private let largestWrite = Atomic<Int>(0)
    private let resetRequested = Atomic<Bool>(false)
    /// Counts the reader's turns, so the app can tell an output that has
    /// stopped asking for sound while the tap still mutes Soloist.
    private let turns = Atomic<Int>(0)
    /// The reader's alone.
    private var read = 0
    private var primed = false

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var readerTurns: Int { turns.load(ordering: .relaxed) }

    /// Forgets what's waiting, so a new start doesn't open with the end of the
    /// last one. Only while nothing is writing.
    func reset() {
        largestWrite.store(0, ordering: .relaxed)
        resetRequested.store(true, ordering: .releasing)
    }

    /// The writer's side.
    func write(left newLeft: UnsafePointer<Float>, right newRight: UnsafePointer<Float>, frames: Int) {
        guard frames > 0, frames <= Self.capacity else { return }
        let start = written.load(ordering: .relaxed)
        let offset = start & Self.mask
        let first = min(frames, Self.capacity - offset)
        (left + offset).update(from: newLeft, count: first)
        (right + offset).update(from: newRight, count: first)
        if first < frames {
            left.update(from: newLeft + first, count: frames - first)
            right.update(from: newRight + first, count: frames - first)
        }
        if frames > largestWrite.load(ordering: .relaxed) { largestWrite.store(frames, ordering: .relaxed) }
        written.store(start + frames, ordering: .releasing)
    }

    /// The reader's side: fills both outputs, with silence where there's no
    /// sound yet. False when all of it is silence.
    func read(left outLeft: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        turns.add(1, ordering: .relaxed)
        let end = written.load(ordering: .acquiring)
        if resetRequested.exchange(false, ordering: .acquiring) {
            read = end
            primed = false
        }
        let cushion = largestWrite.load(ordering: .relaxed) + max(1024, 2 * frames)
        var available = end - read
        // Far behind (the output stalled, or its clock runs slower than the
        // tap's): skip to the newest sound rather than play ever later.
        if available > max(3 * cushion, cushion + 4096) || available > Self.capacity {
            read = end - min(cushion, Self.capacity)
            available = end - read
        }
        if !primed, available >= cushion { primed = true }
        let count = primed ? min(frames, available) : 0
        if count > 0 {
            let offset = read & Self.mask
            let first = min(count, Self.capacity - offset)
            outLeft.update(from: left + offset, count: first)
            outRight.update(from: right + offset, count: first)
            if first < count {
                (outLeft + first).update(from: left, count: count - first)
                (outRight + first).update(from: right, count: count - first)
            }
            read += count
        }
        if count < frames {
            (outLeft + count).update(repeating: 0, count: frames - count)
            (outRight + count).update(repeating: 0, count: frames - count)
            // Ran dry: gather the cushion again before playing on.
            primed = false
        }
        return count > 0
    }
}

/// Plays what the tap on Soloist hears through an equalizer. Soloist plays its
/// own sound and has no equalizer, so while this runs the tap mutes Soloist's
/// output (`SoloistAudioTap`) and Tint's engine plays in its place.
@MainActor
final class EqualizerOutput {
    let ring = AudioRing()
    private var engine: AVAudioEngine?
    private var unit: AVAudioUnitEQ?
    private var sampleRate: Double = 0
    private var wantsRunning = false
    private nonisolated(unsafe) var configObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "equalizer")
    /// The output device or its format changed (headphones, AirPods) while this
    /// was running. The tap's rate may have changed with it, so the owner
    /// starts both again.
    var onConfigurationChange: (() -> Void)?

    var equalizer = Equalizer() {
        didSet { if let unit, equalizer != oldValue { Self.apply(equalizer, to: unit, sampleRate: sampleRate) } }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// False if the engine wouldn't start; the caller then leaves Soloist audible.
    func start(sampleRate: Double) -> Bool {
        guard sampleRate > 0 else { return false }
        if engine == nil || sampleRate != self.sampleRate { rebuild(sampleRate: sampleRate) }
        guard let engine else { return false }
        wantsRunning = true
        if engine.isRunning { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            log.error("Equalizer output failed to start: \(error.localizedDescription, privacy: .public)")
            wantsRunning = false
            return false
        }
    }

    func stop() {
        wantsRunning = false
        engine?.pause()
    }

    /// Drops the engine, so the next start builds a new one: for an engine
    /// that says it runs but has stopped asking for sound.
    func discard() {
        wantsRunning = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.stop()
        engine = nil
        unit = nil
    }

    private func rebuild(sampleRate: Double) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine?.stop()
        let engine = AVAudioEngine()
        let unit = Self.build(engine, ring: ring, sampleRate: sampleRate)
        Self.apply(equalizer, to: unit, sampleRate: sampleRate)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning else { return }
                self.onConfigurationChange?()
            }
        }
        self.engine = engine
        self.unit = unit
        self.sampleRate = sampleRate
    }

    /// The graph: the ring, the equalizer, the mixer. The mixer converts from the
    /// tap's rate to the device's. Also what `scripts/test-equalizer.sh` renders offline.
    nonisolated static func build(_ engine: AVAudioEngine, ring: AudioRing, sampleRate: Double) -> AVAudioUnitEQ {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let source = makeSourceNode(format: format, ring: ring)
        let unit = AVAudioUnitEQ(numberOfBands: Equalizer.frequencies.count)
        engine.attach(source)
        engine.attach(unit)
        engine.connect(source, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        return unit
    }

    nonisolated static func apply(_ equalizer: Equalizer, to unit: AVAudioUnitEQ, sampleRate: Double) {
        for (band, (frequency, gain)) in zip(unit.bands, zip(Equalizer.frequencies, equalizer.gains)) {
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = Equalizer.bandwidth
            band.gain = gain
            band.bypass = false
        }
        unit.globalGain = equalizer.headroom(sampleRate: Float(sampleRate))
    }

    /// Built outside the main actor on purpose: the render block runs on Core Audio's
    /// real-time thread and must not inherit main-actor isolation checks.
    private nonisolated static func makeSourceNode(format: AVAudioFormat, ring: AudioRing) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { @Sendable isSilence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            if !ring.read(left: left, right: right, frames: Int(frameCount)) {
                isSilence.pointee = true
            }
            return noErr
        }
    }
}
