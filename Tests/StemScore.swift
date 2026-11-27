import AVFoundation
import Accelerate
import Foundation

/// How well the analyzer's layers follow real instruments, measured on songs
/// whose parts are known: GarageBand's Apple Loops come in families (a beat, a
/// bass, a lead, a pad…) recorded to play together, so a family mixed here is
/// a real production with its stems to hand. Nothing synthetic: the drums are
/// sampled kits, the leads are played, the mixes are panned by Apple's engineers.
///
/// For each family the mix runs four sections, drums and bass throughout:
/// lead and backing together, the lead alone, the backing alone, neither.
/// The lead is folded to mono and placed in the centre, as a singer is mixed
/// (the loops' own leads are synths with stereo effects, and the library has
/// no singers); everything else keeps the panning it was made with.
///
/// - **Hits**: the kicks, snares and hats found in the mix against those found
///   in the drum loop played alone. A hit in the mix that the drums alone don't
///   have was set off by another instrument; one missing was drowned by it.
/// - **Lead**: the lead layer's level with only the lead playing against only
///   the backing. This is what fills Beams' haze and Fluid's ink, and it should
///   follow the singer or the solo, not the chords behind them.
///
/// Needs GarageBand's loops (/Library/Audio/Apple Loops); without them it says so and passes.
@main
struct StemScore {
    static let root = URL(fileURLWithPath: "/Library/Audio/Apple Loops/Apple")
    static let rate = Double(SpectrumAnalyzer.sampleRate)
    static let block = Int(SpectrumAnalyzer.sampleRate / 30)
    static let sectionSeconds = 6.0

    struct Stereo {
        var left: [Float], right: [Float]
        var count: Int { left.count }

        /// The share of the power that is common to both channels: 1 for a part
        /// mixed dead centre, 0 for one hard to a side or spread wide.
        var centred: Float {
            var mid: Float = 0, side: Float = 0
            for i in 0..<count {
                let m = (left[i] + right[i]) / 2, s = (left[i] - right[i]) / 2
                mid += m * m
                side += s * s
            }
            return (mid - side) / max(mid + side, 1e-12)
        }

        var rms: Float {
            var l: Float = 0, r: Float = 0
            vDSP_measqv(left, 1, &l, vDSP_Length(count))
            vDSP_measqv(right, 1, &r, vDSP_Length(count))
            return ((l + r) / 2).squareRoot()
        }
    }

    static func load(_ url: URL) -> Stereo? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData, buffer.frameLength > 4096,
              file.processingFormat.sampleRate == rate else { return nil }
        let n = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: data[0], count: n))
        let right = file.processingFormat.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : left
        return Stereo(left: left, right: right)
    }

    /// `stem` looped to `length` samples, silent outside `sections` (with 20 ms fades).
    static func arrange(_ stem: Stereo, length: Int, sections: [Bool]) -> Stereo {
        var out = Stereo(left: [Float](repeating: 0, count: length), right: [Float](repeating: 0, count: length))
        let per = Int(sectionSeconds * rate), fade = Int(0.02 * rate)
        for i in 0..<length {
            let section = min(sections.count - 1, i / per)
            guard sections[section] else { continue }
            let into = i - section * per
            let gain = min(1, Float(min(into, per - into)) / Float(fade))
            out.left[i] = stem.left[i % stem.count] * gain
            out.right[i] = stem.right[i % stem.count] * gain
        }
        return out
    }

    static func layers(_ audio: Stereo) -> [MusicLayers] {
        let analyzer = SpectrumAnalyzer()!
        var result: [MusicLayers] = []
        var start = 0
        while start + block <= audio.count {
            let frame = analyzer.process(left: Array(audio.left[start..<start + block]), right: Array(audio.right[start..<start + block]), count: block)
            result.append(frame.layers)
            start += block
        }
        return result
    }

    static func leadLevel(_ layers: MusicLayers) -> Float {
        #if LEAD_LAYER
        layers.lead
        #else
        layers.mid
        #endif
    }

    /// Hits in `found` that have one in `truth` within a frame, and the reverse.
    static func match(_ found: [Int], _ truth: [Int]) -> (hits: Int, extra: Int, missed: Int) {
        let hits = found.filter { f in truth.contains { abs($0 - f) <= 1 } }.count
        let caught = truth.filter { t in found.contains { abs($0 - t) <= 1 } }.count
        return (hits, found.count - hits, truth.count - caught)
    }

    struct Family { var name: String; var drums, bass, lead, backing: URL }

    static func families() -> [Family] {
        let leads = ["Synth Lead", "Trumpet Lead", "Violin Lead", "Lead", "Vox Synth", "Choir", "Flute", "Brass 01", "Brass", "Synth Arp", "Arp 01", "Synth 01"]
        let backings = ["Synth Pad", "Pad", "Piano", "Keys 01", "Guitar 01", "Guitar", "Strings 01", "Strings", "Organ", "Synth Chords 01", "Synth 02", "Synth"]
        var result: [Family] = []
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "caf" }
            var parts: [String: [String: URL]] = [:]
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                for role in ["Beat 01", "Beat", "Sub Bass", "Synth Bass 01", "Synth Bass", "Bass 01", "Bass"] + leads + backings where name.hasSuffix(" " + role) {
                    parts[String(name.dropLast(role.count + 1)), default: [:]][role] = file
                    break
                }
            }
            for (name, roles) in parts.sorted(by: { $0.key < $1.key }) {
                guard let drums = roles["Beat"] ?? roles["Beat 01"],
                      let bass = ["Sub Bass", "Bass", "Bass 01", "Synth Bass", "Synth Bass 01"].compactMap({ roles[$0] }).first,
                      let lead = leads.compactMap({ roles[$0] }).first,
                      let backing = backings.compactMap({ roles[$0] }).first(where: { $0 != lead }) else { continue }
                result.append(Family(name: name, drums: drums, bass: bass, lead: lead, backing: backing))
            }
        }
        return result
    }

    static func main() {
        let families = families()
        guard !families.isEmpty else {
            print("PASS: no Apple Loops here (GarageBand installs them), so there are no real stems to score")
            return
        }
        let only = ProcessInfo.processInfo.environment["FLOE_STEMS_ONLY"]
        let length = Int(sectionSeconds * rate) * 4
        let per = Int(sectionSeconds * 30)
        var totals = (kick: (0, 0, 0), snare: (0, 0, 0), hat: (0, 0, 0))
        var alone: [Float] = [], behind: [Float] = [], neither: [Float] = [], both: [Float] = []
        var micros = 0.0, frames = 0
        print("family                  lead part     backing      centred: lead backing |  kicks ok/extra/missed  snares        hats     | lead layer: alone  backing  neither   ratio")
        for family in families where only == nil || family.name.localizedCaseInsensitiveContains(only!) {
            guard let drums = load(family.drums), let bass = load(family.bass), var lead = load(family.lead), let backing = load(family.backing) else { continue }
            for i in 0..<lead.count {
                let mono = (lead.left[i] + lead.right[i]) / 2
                lead.left[i] = mono
                lead.right[i] = mono
            }
            let always = [true, true, true, true]
            let d = arrange(drums, length: length, sections: always), b = arrange(bass, length: length, sections: always)
            let l = arrange(lead, length: length, sections: [true, true, false, false])
            let k = arrange(backing, length: length, sections: [true, false, true, false])
            var mix = Stereo(left: [Float](repeating: 0, count: length), right: [Float](repeating: 0, count: length))
            for i in 0..<length {
                mix.left[i] = d.left[i] + b.left[i] + l.left[i] + k.left[i]
                mix.right[i] = d.right[i] + b.right[i] + l.right[i] + k.right[i]
            }
            // As loud as a mastered song: the loops alone peak well under full scale.
            var peak: Float = 0
            vDSP_maxmgv(mix.left, 1, &peak, vDSP_Length(length))
            let gain = 0.9 / max(peak, 0.01)
            func scaled(_ audio: Stereo) -> Stereo {
                var out = audio
                vDSP_vsmul(audio.left, 1, [gain], &out.left, 1, vDSP_Length(length))
                vDSP_vsmul(audio.right, 1, [gain], &out.right, 1, vDSP_Length(length))
                return out
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let heard = layers(scaled(mix))
            micros += Double(DispatchTime.now().uptimeNanoseconds - started) / 1000
            frames += heard.count
            let truth = layers(scaled(d))
            func hits(_ layers: [MusicLayers], _ pick: (MusicLayers) -> Float) -> [Int] { layers.indices.filter { $0 > 30 && pick(layers[$0]) > 0 } }
            let kicks = match(hits(heard) { $0.kick }, hits(truth) { $0.kick })
            let snares = match(hits(heard) { $0.snare }, hits(truth) { $0.snare })
            let hats = match(hits(heard) { $0.hat }, hits(truth) { $0.hat })
            totals.kick = (totals.kick.0 + kicks.hits, totals.kick.1 + kicks.extra, totals.kick.2 + kicks.missed)
            totals.snare = (totals.snare.0 + snares.hits, totals.snare.1 + snares.extra, totals.snare.2 + snares.missed)
            totals.hat = (totals.hat.0 + hats.hits, totals.hat.1 + hats.extra, totals.hat.2 + hats.missed)
            // Each section's last four seconds, once the envelopes have settled into it.
            func mean(_ section: Int) -> Float {
                let range = (section * per + 60)..<min(heard.count, (section + 1) * per)
                return range.reduce(Float(0)) { $0 + leadLevel(heard[$1]) } / Float(max(1, range.count))
            }
            both.append(mean(0)); alone.append(mean(1)); behind.append(mean(2)); neither.append(mean(3))
            func triple(_ m: (hits: Int, extra: Int, missed: Int)) -> String { String(format: "%3d/%2d/%2d", m.hits, m.extra, m.missed) }
            print(family.name.padding(toLength: 23, withPad: " ", startingAt: 0),
                  String(family.lead.deletingPathExtension().lastPathComponent.dropFirst(family.name.count + 1)).padding(toLength: 13, withPad: " ", startingAt: 0),
                  String(family.backing.deletingPathExtension().lastPathComponent.dropFirst(family.name.count + 1)).padding(toLength: 13, withPad: " ", startingAt: 0),
                  String(format: "%5.2f %5.2f   |  ", lead.centred, backing.centred),
                  triple(kicks), "     ", triple(snares), "  ", triple(hats),
                  String(format: "  |        %5.2f   %5.2f   %5.2f   %5.1f", mean(1), mean(2), mean(3), mean(1) / max(mean(2), 0.01)))
        }
        func average(_ values: [Float]) -> Float { values.reduce(0, +) / Float(max(1, values.count)) }
        func f1(_ t: (Int, Int, Int)) -> Float { 2 * Float(t.0) / max(1, Float(2 * t.0 + t.1 + t.2)) }
        // How many families the lead layer answers the lead in more than the backing.
        let wins = zip(alone, behind).filter { $0 > $1 * 1.25 }.count
        print(String(format: "Hits in the mix against the drums alone (%d families): kicks %d right, %d extra, %d missed (F1 %.3f); snares %d/%d/%d (F1 %.3f); hats %d/%d/%d (F1 %.3f)",
                     alone.count, totals.kick.0, totals.kick.1, totals.kick.2, f1(totals.kick), totals.snare.0, totals.snare.1, totals.snare.2, f1(totals.snare),
                     totals.hat.0, totals.hat.1, totals.hat.2, f1(totals.hat)))
        print(String(format: "Lead layer, mean over families: lead alone %.3f, backing alone %.3f, neither %.3f, both %.3f; the lead wins by a quarter or more in %d of %d",
                     average(alone), average(behind), average(neither), average(both), wins, alone.count))
        print(String(format: "Analysis: %.1f µs a frame", micros / Double(max(1, frames))))
        print("PASS: scored \(alone.count) families of real stems")
    }
}
