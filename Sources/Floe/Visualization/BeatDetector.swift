import Foundation

/// Turns analysis frames into what the live backgrounds react to. Fed once per
/// analysis frame (30 Hz), never per drawn frame, so no hit counts twice.
struct BeatDetector {
    /// What the backgrounds react to, all 0…1 unless noted.
    struct Pulse: Equatable {
        /// A kick strong enough to count as a beat, at most three a second, so
        /// beat-synced flashes stay within WCAG 2.3.1; otherwise 0.
        var beat: Float = 0
        /// This frame's hits, 0 when none: in the bass, the mids and the highs.
        var kick: Float = 0
        var snare: Float = 0
        var hat: Float = 0
        /// Smoothed loudness.
        var energy: Float = 0
        /// Loudness against the last few seconds: low in a breakdown, high on a drop.
        var lift: Float = 0.5
        /// Each layer's envelope (see `MusicLayers`).
        var bass: Float = 0
        var lowMid: Float = 0
        var mid: Float = 0
        var high: Float = 0
        var lead: Float = 0
        /// The song's beat clock (beats; the fraction is the phase), its tempo in
        /// BPM (0 until locked) and how steady the pulse is.
        var beats: Float = 0
        var tempo: Float = 0
        var confidence: Float = 0
    }
    /// At most three beats a second, so beat-synced flashes stay within WCAG 2.3.1.
    static let minimumInterval: Float = 0.34
    private(set) var pulse = Pulse()
    private var sinceBeat: Float = 1
    private var fast: Float = 0
    private var slow: Float = 0

    mutating func update(_ frame: SpectrumFrame, dt: Float) -> Pulse {
        let dt = min(max(dt, 0.001), 0.25)
        let layers = frame.layers
        sinceBeat += dt
        // On a steady groove, kicks on the beat grid count fully and stray bass
        // swells between them (a bassline beating against a kick's tail) hardly
        // at all. Looser grooves keep their off-beat kicks.
        var kick = layers.kick
        if kick > 0, layers.tempo > 0 {
            let offset = abs(layers.beats - layers.beats.rounded())
            kick *= 1 - 0.85 * layers.confidence * Self.smoothstep(0.12, 0.3, offset)
        }
        pulse.kick = kick
        pulse.snare = layers.snare
        pulse.hat = layers.hat
        pulse.beat = 0
        if kick > 0.3, sinceBeat >= Self.minimumInterval {
            pulse.beat = kick
            sinceBeat = 0
        }

        let loudness = frame.bands.isEmpty ? 0 : frame.bands.reduce(0, +) / Float(frame.bands.count)
        fast += (loudness - fast) * Self.rate(dt, 0.25)
        slow += (loudness - slow) * Self.rate(dt, 4)
        pulse.energy = min(1, max(0, (fast - 0.12) * 1.9))
        pulse.lift = min(1, max(0, 0.5 + (fast - slow) * 3.5))
        pulse.bass = layers.bass
        pulse.lowMid = layers.lowMid
        pulse.mid = layers.mid
        pulse.lead = layers.lead
        pulse.high = layers.high
        pulse.beats = layers.beats
        pulse.tempo = layers.tempo
        pulse.confidence = layers.confidence
        return pulse
    }

    /// The share of the way an exponential follower moves in `dt` with time constant `tau`.
    static func rate(_ dt: Float, _ tau: Float) -> Float { 1 - expf(-dt / tau) }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}

/// A damped spring: chases its target with inertia, so whatever rides on it
/// swings, overshoots a little if underdamped, and never jumps.
struct Spring: Equatable {
    var position: Float = 0
    var velocity: Float = 0

    /// `frequency` in Hz; `damping` 1 settles without overshoot, lower wobbles.
    /// Sub-stepped, so a long frame after a stall can't blow it up.
    mutating func step(toward target: Float, frequency: Float, damping: Float, dt: Float, maximumSpeed: Float = .infinity) {
        let omega = 2 * Float.pi * frequency
        var remaining = min(max(dt, 0), 0.25)
        while remaining > 0 {
            let h = min(remaining, 1 / 240)
            velocity += (omega * omega * (target - position) - 2 * damping * omega * velocity) * h
            velocity = min(maximumSpeed, max(-maximumSpeed, velocity))
            position += velocity * h
            remaining -= h
        }
    }
}
