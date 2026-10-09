import Foundation

/// Synthetic songs for the auto preset's sound classifier, at 44.1 kHz and
/// through the real analyzer, so it sees the frames the app would. Each is a
/// caricature of a style: what it has to tell apart, not a realistic mix.
struct SongSynth {
    enum Style: String, CaseIterable {
        /// The live-background tests' groove: kick every beat at 120 BPM, hats on the eighths, snare on two and four.
        case groove
        /// 124 BPM house: four-on-the-floor kick, off-beat open hat, clap, pumping bass.
        case club
        /// 140 BPM trap in half time: long 808s off the grid, one snare a bar, hat rolls.
        case trap
        /// 90 BPM boom bap: kick on one and the and of three, snare on two and four, heavy bass.
        case boomBap
        /// 120 BPM rock: kick on one and three, loud backbeat, ride cymbal, distorted power chords.
        case rock
        /// A slow pad that swells, over a soft sustained bass.
        case pad
        /// The live-background tests' bare pad.
        case quietPad
        /// Plucked guitar chords and a voice, no drums.
        case acoustic
        case silence
    }

    private var random: UInt64 = 0x2545F4914F6CDD1D
    private var hissA: Float = 0, hissB: Float = 0, rattlePrevious: Float = 0

    private mutating func noise() -> Float {
        random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(random >> 40) / Float(1 << 24) * 2 - 1
    }

    /// Noise rising 12 dB an octave: hats and cymbals.
    private mutating func hiss() -> Float {
        let x = noise()
        defer { hissB = hissA; hissA = x }
        return (x - 2 * hissA + hissB) * 0.5
    }

    /// Noise rising 6 dB an octave: a snare's rattle or a clap.
    private mutating func rattle() -> Float {
        let x = noise()
        defer { rattlePrevious = x }
        return (x - rattlePrevious) * 0.7
    }

    /// Time since the last of `hits` (in beats, repeating every `length` beats), in seconds, or nil before the first.
    private static func since(_ t: Float, bpm: Float, hits: [Float], length: Float) -> Float? {
        let beat = 60 / bpm
        let position = t / beat
        let inBar = position.truncatingRemainder(dividingBy: length)
        var best: Float?
        for hit in hits {
            var delta = inBar - hit
            if delta < 0 { delta += length }
            if position - delta < 0 { continue }
            if best == nil || delta < best! { best = delta }
        }
        return best.map { $0 * beat }
    }

    private static func kick(_ s: Float, low: Float = 50, decay: Float = 0.12) -> Float {
        let phase = 2 * .pi * (low * s + 3 * (1 - expf(-s / 0.03)))
        return sinf(phase) * expf(-s / decay)
    }

    private static func pad(_ t: Float, _ frequencies: [Float]) -> Float {
        frequencies.reduce(0) { $0 + sinf(2 * .pi * $1 * t) } / Float(frequencies.count)
    }

    private static func vocal(_ t: Float) -> Float {
        let phase = 2 * .pi * 440 * t - 8 / 5 * cosf(2 * .pi * 5 * t)
        let syllable = 0.5 + 0.5 * sinf(2 * .pi * 1.3 * t)
        return syllable * (sinf(phase) + 0.5 * sinf(2 * phase) + 0.3 * sinf(3 * phase)) / 1.8
    }

    mutating func sample(_ style: Style, at t: Float) -> Float {
        switch style {
        case .silence:
            return 0
        case .quietPad:
            return 0.1 * Self.pad(t, [220, 277.2, 329.6])
        case .groove:
            var v = 0.1 * Self.pad(t, [220, 277.2, 329.6]) + 0.15 * sinf(2 * .pi * 55 * t)
            if let s = Self.since(t, bpm: 120, hits: [0], length: 1) { v += 0.8 * Self.kick(s, decay: 0.1) }
            let h = t.truncatingRemainder(dividingBy: 0.125)
            v += 0.08 * hiss() * expf(-h / 0.02)
            if let s = Self.since(t, bpm: 120, hits: [1, 3], length: 4) {
                v += 0.3 * min(1, s / 0.002) * (rattle() + 0.3 * sinf(2 * .pi * 200 * s)) * expf(-s / 0.06)
            }
            return v
        case .club:
            var v = 0.12 * Self.pad(t, [261.6, 311.1, 392])
            if let s = Self.since(t, bpm: 124, hits: [0], length: 1) { v += 0.9 * Self.kick(s, decay: 0.11) }
            if let s = Self.since(t, bpm: 124, hits: [0.5], length: 1) {
                v += 0.25 * sinf(2 * .pi * 55 * t) * expf(-s / 0.18) // the bass on the off-beat
                v += 0.12 * hiss() * expf(-s / 0.06) // open hat
            }
            if let s = Self.since(t, bpm: 124, hits: [0, 0.25, 0.5, 0.75], length: 1) { v += 0.04 * hiss() * expf(-s / 0.015) }
            if let s = Self.since(t, bpm: 124, hits: [1, 3], length: 4) {
                v += 0.3 * min(1, s / 0.002) * rattle() * expf(-s / 0.05)
            }
            return v
        case .trap:
            var v = 0.06 * Self.pad(t, [233.1, 277.2, 349.2]) + 0.08 * Self.vocal(t)
            // Long 808s with a pitch drop: the bass line is the kick.
            if let s = Self.since(t, bpm: 140, hits: [0, 1.5, 2.75, 4, 5.5], length: 8) {
                v += 0.9 * sinf(2 * .pi * (48 * s + 1.5 * (1 - expf(-s / 0.04)))) * expf(-s / 0.55)
            }
            if let s = Self.since(t, bpm: 140, hits: [2, 6], length: 8) {
                v += 0.35 * min(1, s / 0.002) * (rattle() + 0.3 * sinf(2 * .pi * 190 * s)) * expf(-s / 0.07)
            }
            // Hats on the eighths, rolling in sixteenth triplets at the end of every other bar.
            var hats: [Float] = stride(from: 0, to: 8, by: 0.5).map { $0 }
            hats += stride(from: 6.5, to: 8, by: 1.0 / 6).map { Float($0) }
            if let s = Self.since(t, bpm: 140, hits: hats, length: 8) { v += 0.06 * hiss() * expf(-s / 0.015) }
            return v
        case .boomBap:
            var v = 0.08 * Self.pad(t, [196, 233.1, 293.7]) + 0.1 * Self.vocal(t)
            if let s = Self.since(t, bpm: 90, hits: [0, 2.5], length: 4) {
                v += 0.9 * Self.kick(s, low: 45, decay: 0.25)
                v += 0.4 * sinf(2 * .pi * 45 * t) * expf(-s / 0.4)
            }
            if let s = Self.since(t, bpm: 90, hits: [1, 3], length: 4) {
                v += 0.4 * min(1, s / 0.002) * (rattle() + 0.3 * sinf(2 * .pi * 200 * s)) * expf(-s / 0.08)
            }
            if let s = Self.since(t, bpm: 90, hits: [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5], length: 4) {
                v += 0.04 * hiss() * expf(-s / 0.02)
            }
            return v
        case .rock:
            // Power chords chugging on the eighths, clipped hard.
            let chord = Self.since(t, bpm: 120, hits: [0, 0.5], length: 1).map { expf(-$0 / 0.2) } ?? 0
            let saw = { (f: Float) in 2 * (f * t - floorf(f * t + 0.5)) }
            var v = 0.22 * tanhf(4 * (saw(82.4) + saw(123.5) + saw(164.8)) / 3) * (0.5 + 0.5 * chord)
            v += 0.2 * sinf(2 * .pi * 82.4 * t) * (0.6 + 0.4 * chord)
            if let s = Self.since(t, bpm: 120, hits: [0, 2, 2.5], length: 4) { v += 0.7 * Self.kick(s, low: 60, decay: 0.08) }
            if let s = Self.since(t, bpm: 120, hits: [1, 3], length: 4) {
                v += 0.6 * min(1, s / 0.002) * (rattle() + 0.4 * sinf(2 * .pi * 220 * s)) * expf(-s / 0.1)
            }
            // Ride on the eighths, ringing, and a crash at each bar.
            if let s = Self.since(t, bpm: 120, hits: [0, 0.5], length: 1) { v += 0.1 * hiss() * expf(-s / 0.25) }
            if let s = Self.since(t, bpm: 120, hits: [0], length: 8) { v += 0.15 * hiss() * expf(-s / 1.2) }
            return v
        case .pad:
            let swell = 0.6 + 0.4 * sinf(2 * .pi * 0.1 * t)
            return 0.15 * swell * Self.pad(t, [174.6, 220, 261.6, 329.6]) + 0.12 * sinf(2 * .pi * 43.7 * t) * swell
        case .acoustic:
            // Strummed chords with uneven spacing, each string a decaying harmonic stack.
            var v = 0.12 * Self.vocal(t)
            if let s = Self.since(t, bpm: 96, hits: [0, 1, 1.5, 2.5, 3, 3.5], length: 4) {
                for (i, f) in [110, 164.8, 220, 277.2, 329.6].enumerated() {
                    let d = max(0, s - Float(i) * 0.012)
                    var string: Float = 0
                    for h in 1...6 { string += sinf(2 * .pi * Float(f) * Float(h) * d) / Float(h * h) }
                    v += 0.07 * string * expf(-d / 0.45) * (d > 0 ? 1 : 0)
                }
            }
            return v
        }
    }

    /// Analysis frames, one per 30 Hz tick, as the app's worker produces them;
    /// `gain` for a quieter or louder master, `clip` to squash it like a loud one.
    static func frames(_ sections: [(Style, Float)], gain: Float = 1, clip: Bool = false) -> [SpectrumFrame] {
        let analyzer = SpectrumAnalyzer()!
        var synth = SongSynth()
        let block = Int(SpectrumAnalyzer.sampleRate / 30)
        var samples = [Float](repeating: 0, count: block)
        var frames: [SpectrumFrame] = []
        var start = 0
        for (style, seconds) in sections {
            for _ in 0..<Int(seconds * 30) {
                for i in 0..<block {
                    let value = gain * synth.sample(style, at: Float(start + i) / SpectrumAnalyzer.sampleRate)
                    samples[i] = clip ? tanhf(value) : value
                }
                frames.append(analyzer.process(left: samples, right: samples, count: block))
                start += block
            }
        }
        return frames
    }
}
