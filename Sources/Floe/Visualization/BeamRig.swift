import Foundation
import simd

/// Beams: moving heads on a truss along the top edge, sweeping through haze in
/// coordinated patterns that change every few bars or on a drop. Kicks punch
/// the light up and snap the sweep forward, the mids set the sweep speed and
/// the highs make the haze shimmer. Brightness follows how the energy moves,
/// so a breakdown goes dim and the drop after it blows up.
struct BeamRig {
    enum Pattern: Int, CaseIterable { case fan, scissors, circle, chase, wave }
    static let maximumHeads = 8
    /// Strobe flashes stay at three a second or fewer (WCAG 2.3.1).
    static let flashInterval: Float = 0.34
    private(set) var pattern = Pattern.fan
    private(set) var previous = Pattern.fan
    /// Progress from the previous pattern to the current one.
    private(set) var blend: Float = 1
    private(set) var phase: Float = 0
    private(set) var haze: Float = 0
    /// Overall brightness before punches.
    private(set) var level: Float = 0
    private(set) var punch: Float = 0
    private(set) var flash: Float = 0
    private(set) var shimmer: Float = 0
    /// The corner beams from the floor join in on drops.
    private(set) var floorLevel: Float = 0
    private var direction: Float = 1
    private var pendingSnap: Float = 0
    private var sinceFlash: Float = 10
    private var sincePattern: Float = 0
    private var beatsInPattern = 0
    private var scheme = 0
    private var random = SeededRandom(seed: 0xBEA5)

    mutating func advance(by dt: Float, pulse: BeatDetector.Pulse, configuration: BackgroundConfiguration) {
        let react = configuration.reactivity
        let speed = configuration.speed
        sincePattern += dt
        sinceFlash += dt
        haze += dt * speed * (0.5 + 0.6 * pulse.energy)
        let target = min(1.3, react * (0.17 + 0.58 * pulse.energy) * (0.25 + 1.15 * pulse.lift))
        level += (target - level) * BeatDetector.rate(dt, target > level ? 0.08 : 0.4)
        punch = min(1.5, pulse.kick * react)
        shimmer = min(1.5, pulse.high * react)
        let drop = smoothstep(0.62, 0.92, pulse.lift) * min(1, pulse.energy * react * 1.4)
        floorLevel += (drop - floorLevel) * BeatDetector.rate(dt, 0.25)

        // The mids set the sweep speed; a beat snaps it forward and it eases off.
        phase += dt * direction * speed * (0.3 + 1.2 * min(1, pulse.mid * react))
        flash *= expf(-dt / 0.045)
        if pulse.beat > 0 {
            pendingSnap += pulse.beat * react * speed * 0.5
            beatsInPattern += 1
            if (pulse.lift > 0.85 && sincePattern > 2) || (beatsInPattern >= 16 && sincePattern > 4) { change() }
            if configuration.strobe, pulse.beat > 0.5, pulse.energy > 0.35, sinceFlash >= Self.flashInterval {
                flash = 1
                sinceFlash = 0
            }
        } else if sincePattern > 14 {
            change()
        }
        let snap = pendingSnap * BeatDetector.rate(dt, 0.07)
        phase += snap * direction
        pendingSnap -= snap
        blend = min(1, blend + dt / 0.4)
    }

    /// Two contrasting palette slots per look: each pattern change leads with the
    /// next colour and pairs it with the one least like it.
    func colorPair(_ palette: [SIMD3<Float>]) -> (Int, Int) {
        let first = scheme % palette.count
        let second = palette.indices.max {
            simd_distance(palette[$0], palette[first]) < simd_distance(palette[$1], palette[first])
        } ?? first
        return (first, second)
    }

    /// Every head's angle, intensity, spread and palette slot; unused heads are zero.
    func heads(count: Int, colors: (Int, Int)) -> [SIMD4<Float>] {
        let k = blend * blend * (3 - 2 * blend)
        return (0..<Self.maximumHeads).map { i in
            guard i < count else { return .zero }
            let old = Self.aim(previous, head: i, count: count, phase: phase)
            let new = Self.aim(pattern, head: i, count: count, phase: phase)
            let lit = old.lit + (new.lit - old.lit) * k
            let slot = i % 2 == 0 ? colors.0 : colors.1
            return SIMD4(old.angle + (new.angle - old.angle) * k, (level + 0.75 * punch) * lit, spread, Float(slot))
        }
    }

    /// Kicks widen the cones as well as brightening them.
    var spread: Float { 0.05 * (1 + 0.6 * punch) }

    /// The floor beams lean in from the corners and scissor slowly.
    var floorAngle: Float { 0.5 + 0.25 * sin(phase * 0.7) }

    /// Where each pattern points a head (radians from straight down, positive
    /// to the right), and how lit it is.
    static func aim(_ pattern: Pattern, head i: Int, count: Int, phase: Float) -> (angle: Float, lit: Float) {
        let s = count > 1 ? Float(i) / Float(count - 1) * 2 - 1 : 0
        let offset = Float(i) / Float(count) * 2 * .pi
        switch pattern {
        case .fan: return (s * (0.1 + 0.55 * (0.5 + 0.5 * sin(phase))), 1)
        case .scissors: return ((i % 2 == 0 ? 1 : -1) * 0.5 * sin(phase * 0.8) + s * 0.12, 1)
        case .circle: return (0.42 * sin(phase + offset), 0.55 + 0.45 * cos(phase + offset))
        case .chase: return (0.45 * sin(phase * 0.6) + s * 0.08, 0.12 + 0.88 * powf(0.5 + 0.5 * cos(phase * 1.6 - offset), 4))
        case .wave: return (0.5 * sin(phase * 0.9 + s * 1.8), 1)
        }
    }

    private mutating func change() {
        previous = pattern
        let step = 1 + Int(random.next() * Float(Pattern.allCases.count - 1))
        pattern = Pattern(rawValue: (pattern.rawValue + step) % Pattern.allCases.count)!
        blend = 0
        if random.next() < 0.5 { direction = -direction }
        scheme += 1
        beatsInPattern = 0
        sincePattern = 0
    }

    private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
