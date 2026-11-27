import AVFoundation
import Foundation

/// The equalizer without Soloist or an audio device: its settings, the ring
/// that carries the tapped sound to the output (single-threaded, then with a
/// writer and a reader racing), and the real audio graph rendered offline,
/// measured tone by tone against what the settings promise.
@main
@MainActor
struct EqualizerTests {
    static var checks = 0

    static func main() {
        modelChecks()
        ringChecks()
        ringThreadChecks()
        graphChecks()
        print("PASS: \(checks) equalizer checks (settings, presets, headroom, ring, threads, audio graph)")
    }

    // MARK: - Settings

    static func modelChecks() {
        var equalizer = Equalizer()
        check(!equalizer.isOn && equalizer.preset == .flat && equalizer.headroom() == 0, "a fresh equalizer must be off and flat")
        for preset in Equalizer.Preset.chosen {
            guard let gains = preset.gains else { fail("\(preset) has no gains") }
            check(gains.count == Equalizer.frequencies.count && gains.allSatisfy(Equalizer.gainRange.contains), "\(preset) must set every band, within range")
            equalizer.choose(preset)
            check(equalizer.preset == preset && equalizer.gains == gains, "choosing \(preset) must set its gains")
        }
        check(Set(Equalizer.Preset.chosen.compactMap(\.gains)).count == Equalizer.Preset.chosen.count, "no two presets may be the same")
        equalizer.choose(.rock)
        equalizer.setGain(40, band: 2)
        check(equalizer.preset == .custom && equalizer.gains[2] == Equalizer.gainRange.upperBound, "moving a band must clamp it and make the preset Custom")
        equalizer.setGain(3, band: 2)
        check(equalizer.preset == .rock, "moving a band back onto a preset must name it again")
        equalizer.setGain(1, band: 99)
        check(equalizer.preset == .rock, "a band that doesn't exist must change nothing")

        equalizer.choose(.bassBoost)
        check(abs(equalizer.headroom() + equalizer.peakGain()) < 0.001 && equalizer.peakGain() > 6 && equalizer.peakGain() < 9,
              "boosts must be paid for in headroom (\(equalizer.peakGain()) dB peak, \(equalizer.headroom()) dB headroom)")
        equalizer.choose(.bassReducer)
        check(equalizer.headroom() == 0, "cuts need no headroom (\(equalizer.headroom()))")

        let defaults = TestDefaults.make()
        var stored = Equalizer()
        stored.isOn = true
        stored.choose(.vocal)
        stored.setGain(-4.5, band: 9)
        stored.save(to: defaults)
        check(Equalizer(defaults: defaults) == stored && stored.preset == .custom, "a custom equalizer must come back as it was saved")
        stored.choose(.electronic)
        stored.save(to: defaults)
        defaults.set([Double](repeating: 1, count: 10), forKey: "equalizerGains")
        check(Equalizer(defaults: defaults).gains == Equalizer.Preset.electronic.gains, "a preset saved by name must load its current gains")
        defaults.set([1.0, 2.0], forKey: "equalizerGains")
        defaults.set("nonsense", forKey: "equalizerPreset")
        check(Equalizer(defaults: defaults).gains == [Float](repeating: 0, count: 10), "damaged settings must load flat")
        check(Equalizer(defaults: TestDefaults.make()) == Equalizer(), "no settings must load the fresh equalizer")
    }

    // MARK: - Ring

    /// Writes a ramp (each sample its own index, the right channel negated), so
    /// any lost, repeated or misplaced frame shows in what's read.
    @MainActor final class Ramp {
        let ring = AudioRing()
        var written = 0
        private var left = [Float](repeating: 0, count: 8192), right = [Float](repeating: 0, count: 8192)
        var outLeft = [Float](repeating: 0, count: 8192), outRight = [Float](repeating: 0, count: 8192)

        func write(_ frames: Int) {
            for i in 0..<frames { left[i] = Float(written + i); right[i] = -Float(written + i) }
            ring.write(left: left, right: right, frames: frames)
            written += frames
        }

        /// The frames read: nil where the ring gave silence.
        func read(_ frames: Int) -> [Int?] {
            let any = ring.read(left: &outLeft, right: &outRight, frames: frames)
            var result: [Int?] = []
            var together = true
            for i in 0..<frames {
                // Frame 0 reads as silence too; the tests start the ramp past it.
                if outLeft[i] == 0, outRight[i] == 0 { result.append(nil) } else {
                    together = together && outRight[i] == -outLeft[i]
                    result.append(Int(outLeft[i]))
                }
            }
            if !together || any != result.contains(where: { $0 != nil }) {
                fail("left and right must stay together, and the ring must say whether it gave any sound")
            }
            return result
        }
    }

    static func ringChecks() {
        let ramp = Ramp()
        ramp.written = 1
        check(ramp.read(512).allSatisfy { $0 == nil }, "an empty ring must give silence")
        ramp.write(512)
        ramp.write(512)
        check(ramp.read(512).allSatisfy { $0 == nil }, "the ring must hold back until its cushion is in (one delivery and 1024 frames)")
        ramp.write(512)
        var heard = ramp.read(512).compactMap { $0 }
        check(heard == Array(1...512), "once the cushion is in, the sound must start from its first frame (\(heard.first ?? -1)…\(heard.last ?? -1))")
        // The two sides taking turns in every order a pair of 512-frame clocks can produce.
        var next = 513
        var random = SystemRandomNumberGenerator()
        var pendingWrites = 0, pendingReads = 0
        for _ in 0..<4000 {
            // Either side may run up to two turns ahead of the other, never more.
            if pendingWrites - pendingReads >= 2 || (pendingReads - pendingWrites < 2 && Bool.random(using: &random)) {
                heard = ramp.read(512).compactMap { $0 }
                pendingReads += 1
                check(heard == Array(next..<next + 512), "frames must come out once each and in order (expected \(next), got \(heard.first ?? -1), \(heard.count) frames)")
                next += 512
            } else {
                ramp.write(512)
                pendingWrites += 1
            }
        }
        check(ramp.written > AudioRing.capacity * 10, "the turns must have wrapped the ring many times")

        // The tap stops (a pause): what's left plays out, then silence, and the
        // cushion is gathered again before the sound goes on, with nothing lost.
        var tail: [Int] = []
        for _ in 0..<8 { tail += ramp.read(512).compactMap { $0 } }
        check(tail == Array(next..<ramp.written), "what's in the ring must play out when the tap stops (\(tail.count) of \(ramp.written - next) frames)")
        next = ramp.written
        ramp.write(512)
        check(ramp.read(512).allSatisfy { $0 == nil }, "after running dry the ring must gather its cushion again")
        ramp.write(512); ramp.write(512)
        heard = ramp.read(512).compactMap { $0 }
        check(heard.first == next, "and then go on from where the sound stopped (\(heard.first ?? -1) for \(next))")

        // The output stalls: it mustn't play ever later afterwards.
        for _ in 0..<40 { ramp.write(512) }
        heard = ramp.read(512).compactMap { $0 }
        let behind = ramp.written - (heard.first ?? 0)
        check(heard.count == 512 && behind <= 512 + 1024 && behind >= 512, "after a stall the ring must skip to the newest sound (\(behind) frames behind)")

        // A new start doesn't open with the end of the last one.
        ramp.ring.reset()
        let before = ramp.written
        ramp.write(512); ramp.write(512); ramp.write(512); ramp.write(512)
        heard = ramp.read(512).compactMap { $0 }
        check(heard.first.map { $0 >= before } ?? true, "a reset must drop what was waiting (\(heard.first ?? -1), reset at \(before))")

        // A tap that delivers in long bursts (some Bluetooth devices) gets a longer cushion.
        let bursty = Ramp()
        bursty.written = 1
        bursty.write(4096)
        check(bursty.read(512).allSatisfy { $0 == nil }, "a 4096-frame delivery needs more than itself as a cushion")
        bursty.write(4096)
        var expected = 1
        for turn in 0..<400 {
            if turn % 8 == 7 { bursty.write(4096) }
            heard = bursty.read(512).compactMap { $0 }
            check(heard == Array(expected..<expected + 512), "bursts must still play without a gap (turn \(turn))")
            expected += 512
        }
    }

    /// A writer and a reader on two threads, as in the app, each at its own
    /// pace for two seconds. Whatever the interleaving, what's read must be
    /// frames that were written, moving forward, with left and right together.
    static func ringThreadChecks() {
        final class Shared: @unchecked Sendable {
            let ring = AudioRing()
            var faults = 0, frames = 0, skips = 0
            var stop = false
        }
        let shared = Shared()
        let done = DispatchSemaphore(value: 0)
        let writer = Thread {
            var left = [Float](repeating: 0, count: 480), right = [Float](repeating: 0, count: 480)
            var written = 1
            while !shared.stop {
                for i in 0..<480 { left[i] = Float(written + i); right[i] = -Float(written + i) }
                shared.ring.write(left: left, right: right, frames: 480)
                written = written + 480 < 1 << 23 ? written + 480 : 1
                usleep(500)
            }
            done.signal()
        }
        let reader = Thread {
            var left = [Float](repeating: 0, count: 512), right = [Float](repeating: 0, count: 512)
            var last = 0
            let end = Date().addingTimeInterval(2)
            while Date() < end {
                _ = shared.ring.read(left: &left, right: &right, frames: 512)
                for i in 0..<512 where left[i] != 0 || right[i] != 0 {
                    let value = Int(left[i])
                    if right[i] != -left[i] || Float(value) != left[i] { shared.faults += 1 }
                    // Forward by one, or a skip forward after a stall; back only where the ramp restarts.
                    if value != last + 1 {
                        if value > last || value < 2000 { shared.skips += 1 } else { shared.faults += 1 }
                    }
                    last = value
                    shared.frames += 1
                }
                usleep(520)
            }
            shared.stop = true
            done.signal()
        }
        writer.start()
        reader.start()
        done.wait()
        done.wait()
        print("Ring across two threads: \(shared.frames) frames read, \(shared.skips) skips, \(shared.faults) faults")
        check(shared.frames > 200_000 && shared.faults == 0, "the ring must never hand out a frame that wasn't written, out of order or torn (\(shared.faults) faults in \(shared.frames))")
    }

    // MARK: - The audio graph

    /// The production graph (`EqualizerOutput.build`), rendered offline: tones go
    /// in through the ring as the tap would write them, and come out of the mixer.
    @MainActor final class Graph {
        let engine = AVAudioEngine()
        let ring = AudioRing()
        let unit: AVAudioUnitEQ
        let sampleRate: Double
        private let buffer: AVAudioPCMBuffer
        private var phase = 0.0
        private var input = [Float](repeating: 0, count: 512)

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            unit = EqualizerOutput.build(engine, ring: ring, sampleRate: sampleRate)
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            do {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
                try engine.start()
            } catch { fail("the equalizer's graph must start offline: \(error)") }
            buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        }

        /// Plays a tone for `seconds` and returns the output's level against the
        /// input's, in dB, over the second half (the first lets the filters settle),
        /// with the largest sample that came out.
        func gain(at frequency: Double, amplitude: Float = 0.25, seconds: Double = 0.8) -> (dB: Float, peak: Float) {
            let blocks = Int(seconds * sampleRate / 512)
            // Whole periods only: a part of one at the end misreads a low tone's level by up to 0.07 dB.
            let period = sampleRate / frequency
            let measured = Int((Double(blocks / 2 * 512) / period).rounded(.down) * period)
            var sum = 0.0, count = 0, peak: Float = 0
            for block in 0..<blocks {
                for i in 0..<512 {
                    input[i] = amplitude * Float(sin(phase))
                    phase += 2 * .pi * frequency / sampleRate
                }
                phase.formTruncatingRemainder(dividingBy: 2 * .pi)
                ring.write(left: input, right: input, frames: 512)
                guard (try? engine.renderOffline(512, to: buffer)) == .success, let channels = buffer.floatChannelData else { fail("offline render") }
                guard block >= blocks / 2 else { continue }
                for i in 0..<Int(buffer.frameLength) where count < measured {
                    let l = channels[0][i], r = channels[1][i]
                    sum += Double(l * l + r * r) / 2
                    peak = max(peak, abs(l), abs(r))
                    count += 1
                }
            }
            let rms = (sum / Double(max(1, count))).squareRoot()
            return (Float(20 * log10(max(rms, 1e-9) / (Double(amplitude) / 2.0.squareRoot()))), peak)
        }
    }

    static func graphChecks() {
        // Band centres and the points between them, where neighbours add up.
        var tones: [Double] = []
        for centre in Equalizer.frequencies { tones += [Double(centre), Double(centre) * 1.41] }
        tones = [22] + tones.filter { $0 < 20_000 }

        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            let graph = Graph(sampleRate: sampleRate)
            var flat = Equalizer()
            flat.isOn = true
            EqualizerOutput.apply(flat, to: graph.unit, sampleRate: sampleRate)
            let flatErrors = tones.map { abs(graph.gain(at: $0).dB) }
            if ProcessInfo.processInfo.environment["FLOE_EQ_DEBUG"] != nil { print(zip(tones, flatErrors).map { String(format: "%.0f Hz %.3f", $0, $1) }) }
            let flatError = flatErrors.max()!
            print(String(format: "Graph at %.0f Hz: flat is within %.3f dB of unchanged", sampleRate, flatError))
            check(flatError < 0.05, "a flat equalizer must leave the sound as it was (\(flatError) dB off at \(sampleRate) Hz)")

            var worstModel: Float = 0, loudest: Float = -100, quietestPeak: Float = 0
            var extreme = Equalizer()
            for band in Equalizer.frequencies.indices { extreme.setGain(12, band: band) }
            var jagged = Equalizer()
            for band in Equalizer.frequencies.indices { jagged.setGain(band % 2 == 0 ? 12 : -12, band: band) }
            let settings = Equalizer.Preset.chosen.map { preset -> (String, Equalizer) in
                var equalizer = Equalizer()
                equalizer.choose(preset)
                return (preset.rawValue, equalizer)
            } + [("every band +12", extreme), ("alternating ±12", jagged)]
            for (name, equalizer) in settings {
                EqualizerOutput.apply(equalizer, to: graph.unit, sampleRate: sampleRate)
                var peakOut: Float = -100
                for tone in tones {
                    let measured = graph.gain(at: tone)
                    let promised = equalizer.response(at: Float(tone), sampleRate: Float(sampleRate)) + equalizer.headroom(sampleRate: Float(sampleRate))
                    worstModel = max(worstModel, abs(measured.dB - promised))
                    peakOut = max(peakOut, measured.dB)
                    check(measured.peak <= 0.25 * 1.06, "\(name): no tone may come out louder than it went in (\(tone) Hz: \(measured.peak / 0.25)×)")
                }
                loudest = max(loudest, peakOut)
                quietestPeak = min(quietestPeak, peakOut)
                print(String(format: "Graph at %.0f Hz, %@: headroom %.1f dB, loudest tone %+.2f dB", sampleRate, name, equalizer.headroom(sampleRate: Float(sampleRate)), peakOut))
                // Headroom that gives away more than it has to makes the equalizer sound quiet for nothing.
                check(peakOut > -1.5 || equalizer.peakGain() <= 0, "\(name): the headroom must not be more than the boost needs (loudest tone \(peakOut) dB)")
            }
            print(String(format: "Graph at %.0f Hz: the audio unit is within %.2f dB of the formula; loudest tone over all settings %+.2f dB",
                         sampleRate, worstModel, loudest))
            check(worstModel < 0.2, "the audio unit must do what the settings' formula says, or the headroom is wrong (\(worstModel) dB apart)")
            check(loudest < 0.1, "with its headroom, no setting may raise any tone above its level going in (\(loudest) dB)")

            // A full-scale tone through a boost: the case the headroom is for.
            var boosted = Equalizer()
            boosted.choose(.bassBoost)
            EqualizerOutput.apply(boosted, to: graph.unit, sampleRate: sampleRate)
            let full = graph.gain(at: 50, amplitude: 1)
            check(full.peak <= 1.03, "a full-scale bass note through Bass boost must not clip (\(full.peak))")

            // A change while playing takes hold, as it does when a slider moves.
            EqualizerOutput.apply(flat, to: graph.unit, sampleRate: sampleRate)
            let back = graph.gain(at: 50)
            check(abs(back.dB) < 0.1, "a change of settings must reach a running graph (\(back.dB) dB after going back to flat)")
            graph.engine.stop()
        }
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition { fail(message()) }
    }

    nonisolated static func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
    }
}
