import Foundation

/// Finds kicks in the bass and follows how the song's energy moves, for the live
/// backgrounds. Fed one analysis frame per 30 Hz tick on the main thread.
struct BeatDetector {
    /// What the backgrounds react to, all 0…1.
    struct Pulse: Equatable {
        /// The strength of a beat landing on this tick, otherwise 0.
        var beat: Float = 0
        /// Jumps on each beat and fades within about 0.2 s.
        var kick: Float = 0
        /// Smoothed loudness.
        var energy: Float = 0
        /// Loudness against the last few seconds: low in a breakdown, high on a drop.
        var lift: Float = 0.5
        /// Smoothed adapted levels of the low, middle and high bands.
        var bass: Float = 0
        var mid: Float = 0
        var high: Float = 0
    }
    /// At most three beats a second, so beat-synced flashes stay within WCAG 2.3.1.
    static let minimumInterval: Float = 0.34
    static let bassBands = 0..<12
    static let midBands = 12..<32
    static let highBands = 32..<48
    private(set) var pulse = Pulse()
    private var previousBass = [Float](repeating: 0, count: bassBands.count)
    private var previousRMS: Float = 0
    private var onsetMean: Float = 0
    private var onsetSpread: Float = 0
    private var sinceBeat: Float = 1
    private var fast: Float = 0
    private var slow: Float = 0

    /// Onsets are rises in the bass (a share of the RMS rise catches kicks that
    /// land on an already loud bassline), measured against their own recent
    /// average and spread, so a busy bassline doesn't fire on every frame.
    mutating func update(_ frame: SpectrumFrame, dt: Float) -> Pulse {
        let dt = min(max(dt, 0.001), 0.25)
        sinceBeat += dt
        var flux: Float = 0
        var bass: Float = 0
        for (i, band) in Self.bassBands.enumerated() where band < frame.bands.count {
            flux += max(0, frame.bands[band] - previousBass[i])
            bass += frame.bands[band]
            previousBass[i] = frame.bands[band]
        }
        flux /= Float(Self.bassBands.count)
        bass /= Float(Self.bassBands.count)
        let rise = max(0, frame.rms - previousRMS) * 3
        previousRMS = frame.rms
        let onset = flux + rise
        let threshold = onsetMean + 1.4 * onsetSpread + 0.025
        pulse.beat = 0
        if onset > threshold, sinceBeat >= Self.minimumInterval, bass > 0.32 {
            pulse.beat = min(1, max(0.35, 0.45 + 0.55 * (onset - threshold) / max(threshold, 0.04)))
            sinceBeat = 0
        }
        let learn = Self.rate(dt, 1.2)
        onsetMean += (onset - onsetMean) * learn
        onsetSpread += (abs(onset - onsetMean) - onsetSpread) * learn
        pulse.kick = max(pulse.beat, pulse.kick * expf(-dt / 0.07))

        let loudness = frame.bands.isEmpty ? 0 : frame.bands.reduce(0, +) / Float(frame.bands.count)
        fast += (loudness - fast) * Self.rate(dt, 0.25)
        slow += (loudness - slow) * Self.rate(dt, 4)
        pulse.energy = min(1, max(0, (fast - 0.12) * 1.9))
        pulse.lift = min(1, max(0, 0.5 + (fast - slow) * 3.5))
        let band = Self.rate(dt, 0.12)
        pulse.bass += (Self.mean(frame.levels, Self.bassBands) - pulse.bass) * band
        pulse.mid += (Self.mean(frame.levels, Self.midBands) - pulse.mid) * band
        pulse.high += (Self.mean(frame.levels, Self.highBands) - pulse.high) * band
        return pulse
    }

    /// The share of the way an exponential follower moves in `dt` with time constant `tau`.
    static func rate(_ dt: Float, _ tau: Float) -> Float { 1 - expf(-dt / tau) }

    private static func mean(_ values: [Float], _ range: Range<Int>) -> Float {
        let slice = values[min(range.lowerBound, values.count)..<min(range.upperBound, values.count)]
        return slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count)
    }
}
