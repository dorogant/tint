import Foundation
import Observation

/// A ten-band graphic equalizer as the user set it. `EqualizerOutput` applies it.
struct Equalizer: Equatable, Sendable {
    /// Band centres, an octave apart, in Hz.
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// How far a band can be raised or cut, in dB.
    static let gainRange: ClosedRange<Float> = -12...12
    /// Each band's width in octaves: bands an octave apart, an octave wide.
    static let bandwidth: Float = 1

    var isOn = false
    var preset = Preset.flat
    /// dB per band, in the order of `frequencies`.
    private(set) var gains = [Float](repeating: 0, count: frequencies.count)

    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case flat, bassBoost, bassReducer, trebleBoost, vocal, rock, electronic, hipHop, acoustic, smallSpeakers, custom
        var id: Self { self }

        /// What the picker offers. Custom is what editing a band makes of any of them.
        static let chosen = allCases.filter { $0 != .custom }

        var title: String {
            switch self {
            case .flat: "Flat"
            case .bassBoost: "Bass boost"
            case .bassReducer: "Bass reducer"
            case .trebleBoost: "Treble boost"
            case .vocal: "Vocal"
            case .rock: "Rock"
            case .electronic: "Electronic"
            case .hipHop: "Hip-hop"
            case .acoustic: "Acoustic"
            case .smallSpeakers: "Small speakers"
            case .custom: "Custom"
            }
        }

        var gains: [Float]? {
            switch self {
            case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            case .bassBoost: [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]
            case .bassReducer: [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]
            case .trebleBoost: [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]
            case .vocal: [-2, -3, -3, 1, 3.5, 4, 3, 1.5, 0, -1.5]
            case .rock: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]
            case .electronic: [4.5, 4, 1, 0, -2, 2, 1, 1.5, 4, 5]
            case .hipHop: [5, 4.5, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]
            case .acoustic: [4, 4, 3, 1, 2, 2, 3, 3.5, 3, 2]
            // What a laptop can't play is left alone; the low mids it can are filled in.
            case .smallSpeakers: [0, 3, 5, 4, 2, 0, -1, -1.5, -2, -2.5]
            case .custom: nil
            }
        }
    }

    init() {}

    mutating func choose(_ preset: Preset) {
        guard let gains = preset.gains else { return }
        self.preset = preset
        self.gains = gains
    }

    /// Moves one band. The result is Custom unless it happens to be a preset.
    mutating func setGain(_ gain: Float, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, gain))
        preset = Preset.chosen.first { $0.gains == gains } ?? .custom
    }

    /// The gain, in dB, applied to everything so that no frequency leaves louder
    /// than it came in. A song mastered to full scale has no room for a boost:
    /// +6 dB on the bass would clip it. So the boosts are had by turning the
    /// rest down, and the system volume makes up the difference. It depends a
    /// little on the sample rate: at 44.1 kHz the top band reaches 0.5 dB
    /// higher than at 48 kHz.
    func headroom(sampleRate: Float = 48_000) -> Float { -max(0, peakGain(sampleRate: sampleRate)) }

    /// The largest gain, in dB, the bands add up to at any frequency. Neighbours
    /// overlap, so two bands at +6 reach about +8 between them.
    func peakGain(sampleRate: Float = 48_000) -> Float {
        var peak = -Float.infinity
        var frequency: Float = 20
        while frequency <= min(20_000, sampleRate * 0.49) {
            peak = max(peak, response(at: frequency, sampleRate: sampleRate))
            frequency *= 1.03
        }
        return peak
    }

    /// The gain in dB at `frequency`, by the standard peaking-filter formulas
    /// (Bristow-Johnson's). The real audio unit measures within 0.1 dB of this
    /// (`scripts/test-equalizer.sh`), so the headroom can be trusted.
    func response(at frequency: Float, sampleRate: Float = 48_000) -> Float {
        // In doubles: at a low frequency and a high rate the terms nearly cancel,
        // and single precision was a quarter of a dB out at 22 Hz and 96 kHz.
        let rate = Double(sampleRate)
        let w = 2 * Double.pi * Double(frequency) / rate
        var total = 0.0
        for (centre, gain) in zip(Self.frequencies, gains) where gain != 0 && centre < sampleRate / 2 {
            let a = pow(10, Double(gain) / 40)
            let w0 = 2 * Double.pi * Double(centre) / rate
            let alpha = sin(w0) * sinh(log(2) / 2 * Double(Self.bandwidth) * w0 / sin(w0))
            let cosine = -2 * cos(w0)
            func power(_ b0: Double, _ b2: Double) -> Double {
                let real = b0 + cosine * cos(w) + b2 * cos(2 * w)
                let imaginary = -cosine * sin(w) - b2 * sin(2 * w)
                return real * real + imaginary * imaginary
            }
            total += 10 * log10(power(1 + alpha * a, 1 - alpha * a) / power(1 + alpha / a, 1 - alpha / a))
        }
        return Float(total)
    }

    // MARK: - Persistence

    init(defaults: UserDefaults) {
        isOn = defaults.bool(forKey: "equalizerOn")
        let stored = (defaults.array(forKey: "equalizerGains") as? [Double])?.map(Float.init)
        if let stored, stored.count == gains.count {
            for (band, gain) in stored.enumerated() { setGain(gain, band: band) }
        }
        // A preset by name wins over its stored gains, so retuning one in an update reaches people who chose it.
        if let preset = defaults.string(forKey: "equalizerPreset").flatMap(Preset.init), preset != .custom { choose(preset) }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(isOn, forKey: "equalizerOn")
        defaults.set(preset.rawValue, forKey: "equalizerPreset")
        defaults.set(gains.map(Double.init), forKey: "equalizerGains")
    }
}

/// Whether the equalizer is really shaping the sound, for Settings to say so.
@MainActor @Observable final class EqualizerStatus {
    static let shared = EqualizerStatus()

    enum State: Equatable {
        /// Off, or nothing is playing through Soloist.
        case idle
        /// Tint hasn't yet heard Soloist through the system's audio tap, so it
        /// can't take the sound over: nothing is playing, or the permission is missing.
        case listening
        case shaping
    }
    var state = State.idle
}
