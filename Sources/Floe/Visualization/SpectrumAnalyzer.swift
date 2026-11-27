import Accelerate
import simd
import Foundation

struct SpectrumFrame: Equatable, Sendable {
    /// Absolute band energy, 0…1 across a 65 dB range.
    var bands: [Float]
    /// What the visuals draw: each band relative to its own recent range, so a
    /// song's fixed tilt (bass always louder) doesn't decide the shape.
    var levels: [Float]
    var rms: Float
    /// The same audio split into musical layers, for the live backgrounds.
    var layers = MusicLayers()
    static let quiet = SpectrumFrame(bands: Array(repeating: 0, count: 48),
                                     levels: Array(repeating: 0, count: 48), rms: 0)

    /// This frame, keeping the onsets of an earlier one nobody read, so a busy
    /// main thread can't drop a kick between two analysis frames.
    func folding(onsetsOf earlier: SpectrumFrame) -> SpectrumFrame {
        var frame = self
        frame.layers.kick = max(layers.kick, earlier.layers.kick)
        frame.layers.snare = max(layers.snare, earlier.layers.snare)
        frame.layers.hat = max(layers.hat, earlier.layers.hat)
        return frame
    }
}

/// The music as the live backgrounds hear it: four layers of the spectrum,
/// the hits in them and the beat. Envelopes and onset strengths are 0…1.
struct MusicLayers: Equatable, Sendable {
    /// 40–157 Hz: the kick's body and the bassline.
    var bass: Float = 0
    /// 157–485 Hz: snare and tom bodies, warmth.
    var lowMid: Float = 0
    /// 485 Hz–4 kHz: vocals, leads, the snare's crack.
    var mid: Float = 0
    /// 4–16 kHz: hats, cymbals, air.
    var high: Float = 0
    /// The voice or the lead instrument: what in the mids is mixed to the centre
    /// and holds for a moment. Chords and pads spread to the sides, and a
    /// snare's crack, which `mid` takes in with the rest, are left out.
    var lead: Float = 0
    /// How hard a hit landed in the bass on this frame, otherwise 0.
    var kick: Float = 0
    /// A hit across the low-mids and mids (snares, claps, stabs), otherwise 0.
    var snare: Float = 0
    /// A hit in the highs (hats, shakers), otherwise 0.
    var hat: Float = 0
    /// Beats counted since the tempo locked; the fraction is the phase within the beat.
    var beats: Float = 0
    /// Beats per minute once locked, otherwise 0.
    var tempo: Float = 0
    /// How regular the hits are, 0 (no pulse) to 1 (a steady four-on-the-floor).
    var confidence: Float = 0

    static let bassBands = 0..<11
    static let lowMidBands = 11..<20
    static let midBands = 20..<37
    static let highBands = 37..<48
}

/// Queue-confined, reusable vDSP buffers. Stereo power avoids phase cancellation;
/// this never runs on Core Audio's render thread and never stores audio to disk.
final class SpectrumAnalyzer {
    static let size = 2048
    static let sampleRate: Float = 44_100
    static let bandCount = 48
    private let setup: FFTSetup
    private let log2Size = vDSP_Length(11)
    private var window = [Float](repeating: 0, count: size)
    private var left = [Float](repeating: 0, count: size)
    private var right = [Float](repeating: 0, count: size)
    private var weighted = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)
    private var stereoPower = [Float](repeating: 0, count: size / 2)
    /// The two channels' sum and difference, which are what gets transformed.
    private var centre = [Float](repeating: 0, count: size)
    private var sides = [Float](repeating: 0, count: size)
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private var average = [Float](repeating: 0, count: bandCount)
    private var spread = [Float](repeating: 0, count: bandCount)
    private var levels = [Float](repeating: 0, count: bandCount)
    private var adapted = 0
    private var level: Float = 0
    /// Each band's unsmoothed level this frame, for onsets.
    private var raw = [Float](repeating: 0, count: bandCount)
    /// The mids' power band by band, 1 being full scale: all of it, and the
    /// part the two channels share.
    private var midPower = [Float](repeating: 0, count: MusicLayers.midBands.count)
    private var sharedPower = [Float](repeating: 0, count: MusicLayers.midBands.count)
    /// Each band's level between its peaks, in the mids and highs (see `process`).
    private var rawFloor = [Float](repeating: 0, count: bandCount - MusicLayers.midBands.lowerBound)
    private var sorted = [Float](repeating: 0, count: size / 2)
    private var layerAnalyzer = LayerAnalyzer()
    private let ranges: [Range<Int>]

    init?() {
        guard let setup = vDSP_create_fftsetup(vDSP_Length(11), FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        ranges = (0..<Self.bandCount).map { i in
            let lo = 40 * powf(400, Float(i) / Float(Self.bandCount))
            let hi = 40 * powf(400, Float(i + 1) / Float(Self.bandCount))
            let start = max(1, Int(lo * Float(Self.size) / Self.sampleRate))
            let end = min(Self.size / 2, max(start + 1, Int(hi * Float(Self.size) / Self.sampleRate)))
            return start..<end
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() {
        left = Array(repeating: 0, count: Self.size)
        right = Array(repeating: 0, count: Self.size)
        smoothed = Array(repeating: 0, count: Self.bandCount)
        average = Array(repeating: 0, count: Self.bandCount)
        spread = Array(repeating: 0, count: Self.bandCount)
        levels = Array(repeating: 0, count: Self.bandCount)
        adapted = 0
        level = 0
        layerAnalyzer = LayerAnalyzer()
    }

    /// Append the newest block to a rolling 46 ms window; input buffers are reusable.
    func process(left inputLeft: [Float], right inputRight: [Float], count: Int) -> SpectrumFrame {
        let count = min(max(0, count), Self.size, inputLeft.count, inputRight.count)
        if count == 0 {
            for i in smoothed.indices { smoothed[i] *= 0.78 }
            level *= 0.78
            adapt()
            for i in raw.indices { raw[i] *= 0.78 }
            for i in midPower.indices { midPower[i] *= 0.3; sharedPower[i] *= 0.3 }
            for i in rawFloor.indices { rawFloor[i] *= 0.78 }
            return SpectrumFrame(bands: smoothed, levels: levels, rms: level,
                                 layers: layerAnalyzer.update(raw, mids: midPower, shared: sharedPower, floor: rawFloor, rms: 0))
        }
        append(inputLeft, count: count, to: &left)
        append(inputRight, count: count, to: &right)
        var leftMean: Float = 0, rightMean: Float = 0
        vDSP_measqv(left, 1, &leftMean, vDSP_Length(Self.size))
        vDSP_measqv(right, 1, &rightMean, vDSP_Length(Self.size))
        let rms = sqrtf((leftMean + rightMean) * 0.5)
        level += (rms - level) * (rms > level ? 0.8 : 0.18)
        // The channels' half sum and half difference are transformed in place of
        // the channels: the two powers add up to the same total (L² + R² is
        // 2(M² + S²)), for the same two transforms, and their difference is the
        // power the channels share. A part mixed dead centre has all its power
        // there; one panned hard to a side, or spread wide, has none.
        var half: Float = 0.5
        vDSP_vasm(left, 1, right, 1, &half, &centre, 1, vDSP_Length(Self.size))
        vDSP_vsbsm(left, 1, right, 1, &half, &sides, 1, vDSP_Length(Self.size))
        transform(centre, into: &stereoPower)
        transform(sides, into: &power)
        let scale = powf(2 / Float(Self.size), 2)
        let firstMid = MusicLayers.midBands.lowerBound
        for (i, range) in ranges.enumerated() {
            var maximum: Float = 0
            for bin in range { maximum = max(maximum, stereoPower[bin] + power[bin]) }
            let db = 10 * log10f(max(maximum * scale, 1e-12))
            let target = min(1, max(0, (db + 65) / 65))
            raw[i] = target
            smoothed[i] += (target - smoothed[i]) * (target > smoothed[i] ? 0.82 : 0.18)
            guard MusicLayers.midBands.contains(i) else { continue }
            // The band's power, and how much of it the channels have in common.
            // Summed over the band before the difference is taken: bin by bin,
            // two unrelated channels differ by chance, and the largest of those
            // chances read as a centre part only 3 dB down.
            var middle: Float = 0, side: Float = 0
            for bin in range { middle += stereoPower[bin]; side += power[bin] }
            midPower[i - firstMid] = (middle + side) * scale
            sharedPower[i - firstMid] = max(0, middle - side) * scale
        }
        // Each band's level between its peaks, from the mids up: the bin three
        // tenths of the way up the band's bins in order of power. A band's
        // level is its loudest bin, so a held note's partial decides it and a
        // drum's noise arriving in the twenty bins around that partial changes
        // nothing. Between the peaks it changes everything: this level jumps
        // with a hit and sits still through a note.
        for i in firstMid..<Self.bandCount {
            let range = ranges[i]
            let count = range.count
            for k in 0..<count { sorted[k] = stereoPower[range.lowerBound + k] + power[range.lowerBound + k] }
            sorted.withUnsafeMutableBufferPointer { vDSP_vsort($0.baseAddress!, vDSP_Length(count), 1) }
            let db = 10 * log10f(max(sorted[(count - 1) * 3 / 10] * scale, 1e-12))
            rawFloor[i - firstMid] = min(1, max(0, (db + 65) / 65))
        }
        adapt()
        return SpectrumFrame(bands: smoothed, levels: levels, rms: level,
                             layers: layerAnalyzer.update(raw, mids: midPower, shared: sharedPower, floor: rawFloor, rms: rms))
    }

    /// Shows each band against its own last couple of seconds: hits stand out
    /// wherever they land in the spectrum, and a band that's simply always loud
    /// settles mid-way. A share of absolute energy keeps quiet bands low, and
    /// silence stays flat.
    private func adapt() {
        adapted += 1
        let rate = max(0.02, 1 / Float(adapted)) // learn quickly after a reset
        for i in 0..<Self.bandCount {
            let value = smoothed[i]
            average[i] += (value - average[i]) * rate
            spread[i] += (abs(value - average[i]) - spread[i]) * rate
            let relative = 0.5 + (value - average[i]) / max(spread[i], 0.03) * 0.22
            let presence = min(1, max(0, (value - 0.12) / 0.3))
            levels[i] = min(1, max(0, 0.75 * relative + 0.25 * value)) * presence
        }
    }

    /// A band center in Hz, useful for deterministic frequency-response tests.
    static func frequency(forBand index: Int) -> Float {
        40 * powf(400, (Float(index) + 0.5) / Float(bandCount))
    }

    private func append(_ input: [Float], count: Int, to buffer: inout [Float]) {
        buffer.withUnsafeMutableBufferPointer { dest in
            if count < Self.size {
                memmove(dest.baseAddress!, dest.baseAddress!.advanced(by: count), (Self.size - count) * MemoryLayout<Float>.size)
            }
            input.withUnsafeBufferPointer { source in
                _ = memcpy(dest.baseAddress!.advanced(by: Self.size - count), source.baseAddress!, count * MemoryLayout<Float>.size)
            }
        }
    }

    private func transform(_ samples: [Float], into power: inout [Float]) {
        vDSP_vmul(samples, 1, window, 1, &weighted, 1, vDSP_Length(Self.size))
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                weighted.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                // Packed real FFT puts Nyquist in imag[0]; it isn't a complex DC bin.
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.size / 2))
            }
        }
    }
}

/// Follows each layer's loudness, finds the hits in it and tracks the tempo
/// from them. Runs once per analysis frame on the analysis queue, so every
/// frame is seen exactly once, however the renderer happens to be timed.
struct LayerAnalyzer {
    private static let ranges = [MusicLayers.bassBands, MusicLayers.lowMidBands, MusicLayers.midBands, MusicLayers.highBands]
    /// Each envelope's attack and release per frame: the bass and highs jump and
    /// let go quickly so kicks and hats stay distinct; the mids swell over a
    /// few frames, so they follow voices and leads rather than a kick's click.
    private static let attack = SIMD4<Float>(1, 0.6, 0.35, 1)
    private static let release = SIMD4<Float>(0.24, 0.28, 0.16, 0.34)
    private var previous = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    /// The bass bands two frames back.
    private var older = [Float](repeating: 0, count: MusicLayers.bassBands.count)
    private var envelope = SIMD4<Float>.zero
    private var average = SIMD4<Float>.zero
    private var spread = SIMD4<Float>.zero
    private var frames: Float = 0
    private var loudness = SIMD2<Float>.zero
    /// The mids' power over the last frames, all of it and the shared part,
    /// band by band with the newest frame at `leadWrite - 1`.
    private var midHistory = [Float](repeating: 0, count: MusicLayers.midBands.count * LayerAnalyzer.held)
    private var sharedHistory = [Float](repeating: 0, count: MusicLayers.midBands.count * LayerAnalyzer.held)
    private var leadWrite = 0
    private var leadPeak: Float = -65
    private var leadEnvelope: Float = 0
    /// Frames a sound has to last, more than half of these, to count as held:
    /// seven frames are 233 ms, so a snare's crack and its ring (three frames,
    /// four at most) fall out and a sung note is in after 133 ms.
    private static let held = 7
    private var previousFloor = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount - MusicLayers.midBands.lowerBound)
    private var kick = OnsetFollower(refractory: 4)
    private var snare = OnsetFollower(refractory: 3)
    private var hat = OnsetFollower(refractory: 2)
    private var tempo = TempoTracker()

    /// `raw` is each band's unsmoothed level, 0…1 across 65 dB; `mids` and
    /// `shared` the mid bands' power and the part of it both channels have;
    /// `floor` the level between the peaks from the mids up; `rms` the window's.
    mutating func update(_ raw: [Float], mids: [Float], shared: [Float], floor: [Float], rms: Float) -> MusicLayers {
        frames += 1
        // A kick is the loudest thing in most mixes, so a jump in overall
        // loudness confirms one even over a bassline that's already loud.
        let level = min(1, max(0, (20 * log10f(max(rms, 1e-6)) + 65) / 65))
        let jump = max(0, level - loudness.max())
        loudness = SIMD2(level, loudness.x)
        var value = SIMD4<Float>.zero, flux = SIMD4<Float>.zero, loudest = SIMD4<Float>.zero
        let count = min(raw.count, previous.count)
        for (j, range) in Self.ranges.enumerated() {
            var sum: Float = 0, rise: Float = 0
            for i in range where i < count {
                sum += raw[i]
                loudest[j] = max(loudest[j], raw[i])
                // Rises against the neighbours' last level too, so a vocal's
                // vibrato sliding between bands doesn't read as a hit.
                var before = max(previous[i], previous[max(0, i - 1)], previous[min(count - 1, i + 1)])
                // The bass must also beat its level two frames back: a kick tail
                // beating against the bassline dips and recovers, a kick doesn't.
                if j == 0 { before = max(before, older[i]) }
                rise += max(0, raw[i] - before)
            }
            // Half the loudest band: a voice or a lead fills only a few bands of
            // its layer, and shouldn't read as quiet for it.
            value[j] = 0.5 * sum / Float(range.count) + 0.5 * loudest[j]
            flux[j] = rise / Float(range.count)
        }
        for i in MusicLayers.bassBands where i < count { older[i] = previous[i] }
        for i in 0..<count { previous[i] = raw[i] }
        // What rose between the peaks, in the mids and the highs: drums, and
        // nothing a held note does. Added to the rise of the peaks, so a hit
        // that a loud chord hides from the one still shows in the other. On
        // real drum loops mixed with their songs' other parts
        // (`scripts/score-layers.sh`, 14 songs), the snares missed fell from
        // 191 of 678 to 89 of 704 and the hats from 308 of 1063 to 256 of 1094.
        let firstMid = MusicLayers.midBands.lowerBound
        if floor.count == previousFloor.count {
            var percussive = SIMD4<Float>.zero
            for i in floor.indices {
                percussive[i + firstMid < MusicLayers.highBands.lowerBound ? 2 : 3] += max(0, floor[i] - previousFloor[i])
                previousFloor[i] = floor[i]
            }
            flux[2] += percussive[2] / Float(MusicLayers.midBands.count)
            flux[3] += percussive[3] / Float(MusicLayers.highBands.count)
        }
        // Like `levels`: each layer against its own last few seconds, so a mix's
        // tilt doesn't decide which layer leads, gated by its absolute level.
        let learn = max(1 / Float(90), 1 / frames)
        average += (value - average) * learn
        spread += (abs(value - average) - spread) * learn
        let relative = 0.5 + (value - average) / simd_max(spread, SIMD4(repeating: 0.03)) * 0.25
        let presence = simd_clamp((value - 0.12) / 0.25, .zero, .one)
        let target = simd_clamp(0.7 * relative + 0.3 * value, .zero, .one) * presence
        envelope.replace(with: envelope + (target - envelope) * Self.release, where: target .<= envelope)
        envelope.replace(with: envelope + (target - envelope) * Self.attack, where: target .> envelope)

        // A hit counts in a layer only if that layer is really sounding, not just
        // catching what leaks from a louder one: its loudest band within about
        // 13 dB of the frame's loudest for the bass, 29 dB for the mids and 33 dB
        // for the highs, which sit lower in any mix. A hit at the edge of the
        // window smears across the whole spectrum, so a kick also has to stand
        // well clear of the highs (a snare's smear doesn't), and a snare has to
        // crack in the highs too (a kick's click doesn't). The loudness jump only
        // confirms a rise in the bass, since a snare jumps too.
        let top = loudest.max()
        let kickPresent = loudest[0] > max(0.12, top - 0.2) && loudest[0] > loudest[3] + 0.15 && flux[0] > 0.03
        let k = kick.update(flux: flux[0] + min(jump, flux[0]), present: kickPresent)
        let s = snare.update(flux: flux[2], present: loudest[2] > max(0.1, top - 0.45) && flux[3] > 0.04)
        let h = hat.update(flux: flux[3], present: loudest[3] > max(0.1, top - 0.5))
        // Kicks carry the pulse; snares and hats sharpen it.
        tempo.update(k.novelty + 0.5 * s.novelty + 0.25 * h.novelty)
        // The lead is the mids as far as they're centred and held. What isn't
        // still counts for a third: on a record with the singer panned to one
        // side (early stereo), or with none at all, the layer follows the mids
        // faintly rather than going dead.
        let led = envelope[2] * max(centred(shared, of: mids), 0.35)
        return MusicLayers(bass: envelope[0], lowMid: envelope[1], mid: envelope[2], high: envelope[3], lead: led,
                           kick: k.onset, snare: s.onset, hat: h.onset,
                           beats: tempo.beats, tempo: tempo.tempo, confidence: tempo.confidence)
    }
}

extension LayerAnalyzer {
    /// How much of what holds in the mids is in the centre, 0…1. Each band's
    /// median over the last `held` frames keeps what holds and drops what only
    /// flashes by; of that, the shared power against all of it. A voice alone
    /// is all shared, and with a band spread around it it's still within a few
    /// dB of the whole; what a chord spread wide leaves in the centre is 10 dB
    /// or more down, and counts for nothing.
    ///
    /// Measured on real parts (`scripts/score-layers.sh`: 14 songs from
    /// GarageBand's loops, the lead folded to the centre as a singer is): with
    /// only the lead playing over drums and bass the layer averages 0.40, with
    /// only the backing 0.31, with neither 0.11. The mids layer, which fed the
    /// haze before, gave 0.45, 0.50 and 0.24: it couldn't tell them apart.
    /// Backings that are themselves mixed near the centre still pass as leads.
    fileprivate mutating func centred(_ shared: [Float], of mids: [Float]) -> Float {
        let bands = MusicLayers.midBands.count
        guard shared.count == bands, mids.count == bands else { return 0 }
        for i in 0..<bands {
            midHistory[leadWrite * bands + i] = mids[i]
            sharedHistory[leadWrite * bands + i] = shared[i]
        }
        leadWrite = (leadWrite + 1) % Self.held
        var all: Float = 0, centre: Float = 0
        for i in 0..<bands {
            all += Self.median(of: midHistory, band: i, bands: bands)
            centre += Self.median(of: sharedHistory, band: i, bands: bands)
        }
        // It also has to be about as loud as the mids have lately been at
        // their loudest: what drums and a bass leave held in the centre of the
        // mids (a ring, an overtone) is all shared too, but 20 dB under a
        // singer. The mark it's held to falls 1 dB a second, so a quiet verse
        // after a loud chorus finds its own level.
        let centreLevel = 10 * log10f(max(centre, 1e-12)), allLevel = 10 * log10f(max(all, 1e-12))
        leadPeak = max(leadPeak - 1.0 / 30, allLevel, -65)
        let presence = min(1, max(0, (centreLevel - leadPeak + 22) / 12)) * (centreLevel > -57 ? 1 : 0)
        // From 10 dB under the whole (nothing) to 3 dB under (all of it).
        let near = min(1, max(0, (centreLevel - allLevel + 10) / 7))
        let target = near * near * (3 - 2 * near) * presence
        leadEnvelope += (target - leadEnvelope) * (target > leadEnvelope ? 0.35 : 0.16)
        return leadEnvelope
    }

    /// One band's median over the `held` frames kept in `history`.
    private static func median(of history: [Float], band i: Int, bands: Int) -> Float {
        // Seven values: an insertion sort in registers is all a median takes.
        var v = (history[i], history[bands + i], history[2 * bands + i], history[3 * bands + i],
                 history[4 * bands + i], history[5 * bands + i], history[6 * bands + i])
        withUnsafeMutableBytes(of: &v) { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for a in 1..<held {
                let x = values[a]
                var b = a - 1
                while b >= 0, values[b] > x { values[b + 1] = values[b]; b -= 1 }
                values[b + 1] = x
            }
        }
        return v.3
    }
}

/// Finds hits in one layer's spectral flux, measured against that layer's own
/// recent floor and peaks: quiet songs still register hits, dense hats don't
/// raise the bar so far that they vanish, and loud masters don't fire on
/// everything.
struct OnsetFollower {
    /// Frames before another hit can land.
    let refractory: Int
    private var floor: Float = 0
    private var peak: Float = 0.05
    private var last: Float = 0
    private var since = 99

    /// Written out because Swift before 6.4 makes the synthesized initializer private
    /// when any stored property is.
    init(refractory: Int) {
        self.refractory = refractory
    }

    /// The hit's strength (0 when none) and how far the flux stands above the
    /// floor, which feeds the tempo whether or not it counts as a hit.
    mutating func update(flux: Float, present: Bool) -> (onset: Float, novelty: Float) {
        since += 1
        floor += (flux - floor) * (flux < floor ? 0.3 : 0.03)
        // The peak can at most double per hit, so a song starting out of silence
        // doesn't set a bar the next few seconds of hits can't reach.
        peak = max(peak * 0.975, min(flux, peak * 2 + 0.05))
        let range = max(peak - floor, 0.02)
        let novelty = min(1.5, max(0, flux - floor) / range)
        // A hit is sudden: a level that swells over several frames (a bass
        // pumping back after a sidechained kick, two tones beating) isn't one.
        let sudden = flux > last * 1.4
        last = flux
        guard present, sudden, flux > floor + 0.3 * range + 0.015, since >= refractory else { return (0, novelty) }
        since = 0
        return (min(1, max(0.25, (flux - floor) / range)), novelty)
    }
}

/// Estimates the tempo from the autocorrelation of the last 8.5 s of hits and
/// keeps a beat clock in phase with them. One estimate every eight frames.
struct TempoTracker {
    private static let history = 256
    private static let maximumLag = 106
    private static let frameRate: Float = 30
    private var novelty = [Float](repeating: 0, count: history)
    private var ordered = [Float](repeating: 0, count: history)
    private var correlation = [Float](repeating: 0, count: maximumLag + 2)
    private var write = 0
    private var filled = 0
    private var countdown = 8
    private var challenger: Float = 0
    private var votes = 0
    private(set) var tempo: Float = 0
    private(set) var confidence: Float = 0
    private(set) var beats: Float = 0

    mutating func update(_ value: Float) {
        novelty[write] = value
        write = (write + 1) % Self.history
        filled = min(Self.history, filled + 1)
        if tempo > 0 { beats += tempo / 60 / Self.frameRate }
        countdown -= 1
        if countdown <= 0, filled >= 120 {
            countdown = 8
            estimate()
        }
    }

    private mutating func estimate() {
        let n = filled
        var mean: Float = 0
        for i in 0..<n {
            ordered[i] = novelty[(write - n + i + Self.history) % Self.history]
            mean += ordered[i]
        }
        mean /= Float(n)
        // Hits in the last two seconds, against the whole window: when the drums
        // stop, the pulse fades with them instead of living on in the history.
        var recent: Float = 0
        for i in (n - 60)..<n { recent += ordered[i] }
        let activity = min(1, recent / 60 / max(0.35 * mean, 0.001))
        var energy: Float = 0
        for i in 0..<n {
            ordered[i] -= mean
            energy += ordered[i] * ordered[i]
        }
        // No pulse to follow (a pad, a breakdown, silence): let confidence fade.
        guard energy > 0.002 * Float(n) else { confidence *= 0.7; return }
        for lag in 0...Self.maximumLag {
            var sum: Float = 0
            for i in lag..<n { sum += ordered[i] * ordered[i - lag] }
            correlation[lag] = sum / Float(n - lag) / (energy / Float(n))
        }
        // A comb over each candidate's first four multiples, leaning toward ~120 BPM
        // so a steady kick doesn't read as half or double time.
        var best: Float = 0, bestScore = -Float.infinity
        var bpm: Float = 70
        while bpm <= 175 {
            let lag = 60 * Self.frameRate / bpm
            let octave = log2f(bpm / 120)
            let score = correlation(at: lag) + 0.6 * correlation(at: 2 * lag) + 0.4 * correlation(at: 3 * lag)
                + 0.25 * correlation(at: 4 * lag) + 0.3 * expf(-octave * octave / 0.5)
            if score > bestScore { bestScore = score; best = bpm }
            bpm += 0.5
        }
        let periodicity = correlation(at: 60 * Self.frameRate / best)
        let target = min(1, max(0, (periodicity - 0.12) / 0.4)) * activity
        confidence += (target - confidence) * 0.35
        if tempo == 0 {
            guard target > 0.25 else { return }
            tempo = best
        } else if abs(best - tempo) / tempo < 0.04 {
            tempo += (best - tempo) * 0.25
            votes = 0
        } else if challenger > 0, abs(best - challenger) / challenger < 0.04 {
            votes += 1
            // A new tempo has to win for about a second before the clock follows it.
            if votes >= 4 { tempo = best; votes = 0 }
        } else {
            challenger = best
            votes = 1
        }
        // The phase that lines a beat grid up with the most recent hits.
        let period = 60 * Self.frameRate / tempo
        var phase: Float = 0, phaseScore = -Float.infinity
        var offset: Float = 0
        while offset < period {
            var score: Float = 0, weight: Float = 1
            for k in 0..<8 {
                let position = Float(n - 1) - offset - Float(k) * period
                if position < 0 { break }
                score += weight * sample(position)
                weight *= 0.85
            }
            if score > phaseScore { phaseScore = score; phase = offset / period }
            offset += 0.5
        }
        if beats == 0 {
            beats = phase
        } else {
            var error = phase - (beats - beats.rounded(.down))
            error -= error.rounded()
            beats += error * 0.35
        }
    }

    private func correlation(at lag: Float) -> Float {
        let i = min(Int(lag), Self.maximumLag)
        let t = min(1, lag - Float(i))
        return correlation[i] + (correlation[min(i + 1, Self.maximumLag)] - correlation[i]) * t
    }

    private func sample(_ position: Float) -> Float {
        let i = Int(position)
        let t = position - Float(i)
        return ordered[i] + (ordered[min(i + 1, filled - 1)] - ordered[i]) * t
    }
}
