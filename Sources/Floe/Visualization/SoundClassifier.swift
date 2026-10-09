import Foundation

/// Guesses a song's preset from how it sounds, for songs whose artist has no
/// Spotify genres. Fed the analysis frames the live background already gets
/// (30 Hz, while effects run), it sums a few cheap statistics over a window of
/// about ten seconds and decides once from them. Scalars only: nothing is
/// allocated per frame, and nothing reaches SwiftUI.
struct SoundClassifier {
    /// What a window of the song sounded like.
    struct Features: Equatable, CustomStringConvertible {
        /// The tracker's tempo in BPM (0 if it never locked) and how steady the
        /// pulse was, 0…1.
        var tempo: Float = 0
        var steadiness: Float = 0
        /// Hits a second in each layer.
        var kicks: Float = 0
        var snares: Float = 0
        var hats: Float = 0
        /// The share of kicks that landed on the beat grid.
        var onGrid: Float = 0
        /// Mean absolute level (0…1 across 65 dB) of the bass, the low mids and the highs.
        var bass: Float = 0
        var lowMid: Float = 0
        var high: Float = 0
        /// How much the loudness moves frame to frame (plucks, accents) rather
        /// than holding (pads, compressed masters).
        var dynamics: Float = 0

        /// Kicks per beat: about 1 on a four-on-the-floor, ½ or less in half time.
        var kicksPerBeat: Float { tempo > 0 ? kicks / (tempo / 60) : 0 }

        var description: String {
            String(format: "tempo %.0f steady %.2f kicks %.2f/s (%.2f/beat, %.0f%% on grid) snares %.2f/s hats %.2f/s "
                   + "bass %.2f lowMid %.2f high %.2f dynamics %.3f",
                   tempo, steadiness, kicks, kicksPerBeat, onGrid * 100, snares, hats, bass, lowMid, high, dynamics)
        }
    }

    /// Frames (at 30 Hz) of sound that make up one decision.
    static let window = 300
    /// The tempo tracker needs about four seconds before it locks; the pulse
    /// statistics skip a window's first frames until then.
    private static let settle = 120
    /// Below this RMS a frame is silence (an intro, a gap) and doesn't count.
    private static let audible: Float = 0.004

    private var frames = 0
    private var settled = 0, locked = 0
    private var kicks = 0, snares = 0, hats = 0, kicksOnGrid = 0, kicksTimed = 0
    private var tempo: Float = 0, steadiness: Float = 0
    private var bass: Float = 0, lowMid: Float = 0, high: Float = 0
    private var dynamics: Float = 0, lastLoudness: Float = 0
    /// Frames since the last reset, audible or not, for the tempo tracker's warm-up.
    private var sinceReset = 0

    /// Whether a full window has been heard.
    var isComplete: Bool { frames >= Self.window }

    /// The statistics so far.
    var features: Features {
        let seconds = max(Float(frames) / 30, 1 / 30)
        let n = Float(max(frames, 1))
        return Features(tempo: locked > 0 ? tempo / Float(locked) : 0,
                        steadiness: settled > 0 ? steadiness / Float(settled) : 0,
                        kicks: Float(kicks) / seconds, snares: Float(snares) / seconds, hats: Float(hats) / seconds,
                        onGrid: kicksTimed > 0 ? Float(kicksOnGrid) / Float(kicksTimed) : 0,
                        bass: bass / n, lowMid: lowMid / n, high: high / n,
                        dynamics: frames > 1 ? dynamics / Float(frames - 1) : 0)
    }

    /// Starts a new window. `restartTempo` if the analyzer itself was reset
    /// (a new song or a seek), so its tempo needs time to lock again.
    mutating func reset(restartTempo: Bool = true) {
        let since = sinceReset
        self = SoundClassifier()
        if !restartTempo { sinceReset = since }
    }

    mutating func add(_ frame: SpectrumFrame) {
        sinceReset += 1
        guard frame.rms > Self.audible, frame.bands.count >= MusicLayers.highBands.upperBound else { return }
        frames += 1
        let layers = frame.layers
        if layers.kick > 0 { kicks += 1 }
        if layers.snare > 0 { snares += 1 }
        if layers.hat > 0 { hats += 1 }
        var b: Float = 0, l: Float = 0, h: Float = 0
        for i in MusicLayers.bassBands { b += frame.bands[i] }
        for i in MusicLayers.lowMidBands { l += frame.bands[i] }
        for i in MusicLayers.highBands { h += frame.bands[i] }
        bass += b / Float(MusicLayers.bassBands.count)
        lowMid += l / Float(MusicLayers.lowMidBands.count)
        high += h / Float(MusicLayers.highBands.count)
        let loudness = 20 * log10f(max(frame.rms, 1e-5))
        if frames > 1 { dynamics += min(12, abs(loudness - lastLoudness)) }
        lastLoudness = loudness
        guard sinceReset > Self.settle else { return }
        settled += 1
        if layers.tempo > 0 { locked += 1; tempo += layers.tempo }
        steadiness += layers.confidence
        if layers.kick > 0, layers.tempo > 0 {
            kicksTimed += 1
            if abs(layers.beats - layers.beats.rounded()) < 0.15 { kicksOnGrid += 1 }
        }
    }

    /// The preset these features suggest. Deterministic and coarse on purpose:
    /// it only has to tell a club groove from a half-time 808 from a guitar band
    /// from a pad, and anything it isn't sure about stays Balanced.
    static func preset(for f: Features) -> BackgroundPreset {
        // How far the bass stands above the highs (in 65 dB units): 808s and
        // sub bass push it up, cymbals and distorted guitars pull it down.
        let tilt = f.bass - f.high
        // No drums (a low note can still read as a kick): pads and drones hold
        // still and are Chill; plucked and played music moves and is Acoustic.
        if f.snares + f.hats < 0.5 { return f.dynamics > 0.3 ? .acoustic : .chill }
        // Drums but no steady grid: sparse, booming 808s are hip-hop.
        if f.steadiness < 0.3 || f.tempo == 0 { return tilt > 0.45 ? .hipHop : .balanced }
        // A kick on every beat, on the grid, at dance tempo.
        let fourOnTheFloor = f.kicksPerBeat > 0.9 && f.onGrid > 0.6
        if fourOnTheFloor, f.tempo >= 110, f.tempo <= 150 { return .club }
        // Slow or half-time, with the bass carrying it.
        if f.tempo < 105 || f.kicksPerBeat < 0.75, tilt > 0.35 { return .hipHop }
        // Snares and cymbals busier than the kick, and a bright top: guitars and
        // ride. Relative to the bass, so a quiet or a squashed master reads the same.
        if f.snares + f.hats >= f.kicks, tilt < 0.4 { return .rock }
        if fourOnTheFloor { return .club }
        return tilt > 0.45 ? .hipHop : .balanced
    }
}
