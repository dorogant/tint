import Foundation

/// The analyzer's musical features (harmony, brightness, builds and drops) on
/// synthetic audio generated here, so every run hears exactly the same thing.
extension BackgroundTests {
    /// One layer frame per 30 Hz tick for `seconds` of mono audio from `sample(t)`.
    static func analyze(_ seconds: Float, _ sample: (Float) -> Float) -> [MusicLayers] {
        analyzedFrames(seconds, sample).map(\.layers)
    }

    /// One analysis frame per 30 Hz tick for `seconds` of mono audio from `sample(t)`.
    static func analyzedFrames(_ seconds: Float, _ sample: (Float) -> Float) -> [SpectrumFrame] {
        let analyzer = SpectrumAnalyzer()!
        let block = Int(SpectrumAnalyzer.sampleRate / 30)
        var samples = [Float](repeating: 0, count: block)
        return (0..<Int(seconds * 30)).map { frame in
            for i in 0..<block { samples[i] = sample(Float(frame * block + i) / SpectrumAnalyzer.sampleRate) }
            return analyzer.process(left: samples, right: samples, count: block)
        }
    }

    /// A note with its first six harmonics falling off as 1/n, like a bowed or blown instrument.
    static func note(_ frequency: Float, at t: Float) -> Float {
        (1...6).reduce(Float(0)) { $0 + sinf(2 * .pi * frequency * Float($1) * t) / Float($1) } / 2.45
    }

    /// The shorter way round the pitch circle from `a` to `b`, in semitones.
    static func circular(_ a: Float, _ b: Float) -> Float {
        let d = b - a
        return d - 12 * (d / 12).rounded()
    }

    static func musicFeatureChecks() {
        // Chords: C major (C4 E4 G4) and A minor (A3 C4 E4) with overtones.
        let cMajor = analyze(4) { t in 0.12 * (note(261.63, at: t) + note(329.63, at: t) + note(392.0, at: t)) }
        let aMinor = analyze(4) { t in 0.12 * (note(220.0, at: t) + note(261.63, at: t) + note(329.63, at: t)) }
        // Bare sines: three equal classes and no overtones to tell a root by.
        let bare = analyze(4) { t in 0.12 * (sinf(2 * .pi * 261.63 * t) + sinf(2 * .pi * 329.63 * t) + sinf(2 * .pi * 392 * t)) }
        let settled = { (layers: [MusicLayers]) in layers.dropFirst(45) }
        let cOff = settled(cMajor).map { abs(circular(0, $0.pitchClass)) }.max()!
        let aOff = settled(aMinor).map { abs(circular(9, $0.pitchClass)) }.max()!
        print(String(format: "Harmony: C major reads %.2f (tonality %.2f), A minor %.2f (%.2f), bare C-E-G sines %.2f (%.2f)",
                     cMajor.last!.pitchClass, mean(cMajor, \.tonality, after: 1.5), aMinor.last!.pitchClass,
                     mean(aMinor, \.tonality, after: 1.5), bare.last!.pitchClass, mean(bare, \.tonality, after: 1.5)))
        check(cOff < 0.5, "a C major chord must read as C, its root, not its loud fifth (off by up to \(cOff))")
        check(aOff < 0.5, "an A minor chord must read as A (off by up to \(aOff))")
        check(settled(cMajor).allSatisfy { $0.tonality > 0.5 }, "a sustained chord must be clearly tonal")

        // C, F, G, C, two seconds each: the root follows each change within a second.
        let progression: [[Float]] = [[261.63, 329.63, 392.0], [349.23, 440.0, 523.25], [392.0, 493.88, 587.33], [261.63, 329.63, 392.0]]
        let changes = analyze(8) { t in
            0.12 * progression[min(3, Int(t / 2))].reduce(Float(0)) { $0 + note($1, at: t) }
        }
        let roots = (1...4).map { changes[$0 * 60 - 1].pitchClass }
        let lag = (1...3).map { change in (change * 60..<change * 60 + 60).first { abs(circular(roots[change], changes[$0].pitchClass)) < 0.5 } ?? 999 }
        print(String(format: "Harmony: C F G C reads %@, each change within %d ms",
                     roots.map { String(format: "%.1f", $0) }.joined(separator: " "), lag.enumerated().map { ($1 - ($0 + 1) * 60) * 1000 / 30 }.max()!))
        check(zip(roots, [0, 5, 7, 0] as [Float]).allSatisfy { abs(circular($1, $0)) < 0.3 }, "a C F G C progression must read as its roots (\(roots))")
        check(lag.enumerated().allSatisfy { $1 - ($0 + 1) * 60 < 30 }, "each chord change must show within a second")

        // A sine sweeping 300→1200 Hz (D4 to D6) over 12 s, two semitones a second.
        let sweep = analyze(12) { t in
            0.3 * sinf(2 * .pi * 300 * 12 / logf(4) * (powf(4, t / 12) - 1))
        }
        var path: [Float] = []
        for layers in sweep.dropFirst(15) {
            path.append(path.isEmpty ? layers.pitchClass : path.last! + circular(path.last!, layers.pitchClass))
        }
        let backward = zip(path, path.dropFirst()).map { $0 - $1 }.max()!
        let travel = path.last! - path.first!
        print(String(format: "Harmony: the 300→1200 Hz sweep starts at %.2f and walks %.1f semitones, at most %.2f backwards",
                     path.first!, travel, max(0, backward)))
        check(abs(circular(2, path.first!)) < 1, "the sweep must start at D (\(path.first!))")
        check(backward < 0.05, "the sweep must walk the classes in order (\(backward) back)")
        check((20...25).contains(travel), "a two-octave sweep must walk about 24 semitones (\(travel))")

        // White noise isn't tonal; a low-passed noise is darker than a bright one.
        var random = SeededRandom(seed: 5)
        let white = analyze(4) { _ in 0.3 * (random.next() * 2 - 1) }
        var dull = SIMD3<Float>.zero
        let lowPassed = analyze(4) { _ in
            // Three one-pole low-passes at about 290 Hz: 18 dB an octave above it.
            dull[0] += (random.next() * 2 - 1 - dull[0]) * 0.04
            dull[1] += (dull[0] - dull[1]) * 0.04
            dull[2] += (dull[1] - dull[2]) * 0.04
            return 2 * dull[2]
        }
        var previous: Float = 0
        let bright = analyze(4) { _ in
            let x = random.next() * 2 - 1
            defer { previous = x }
            return 0.3 * (x - previous) // tilted up 6 dB an octave
        }
        let noiseTonality = white.dropFirst(15).map(\.tonality).max()!
        print(String(format: "Brightness: low-passed noise %.2f, white noise %.2f, bright noise %.2f; white noise tonality at most %.2f",
                     mean(lowPassed, \.brightness), mean(white, \.brightness), mean(bright, \.brightness), noiseTonality))
        check(noiseTonality < 0.2, "white noise must not read as tonal (\(noiseTonality))")
        check(mean(lowPassed, \.brightness) + 0.3 < mean(white, \.brightness) && mean(white, \.brightness) < mean(bright, \.brightness),
              "brightness must order low-passed, white and bright noise")
        check(white.allSatisfy { $0.pitchClass == 0 }, "noise must never lock a pitch class")

        // On instruments: the kick and bass are dark, hats bright, a full groove between.
        let kicks = layers([(SyntheticTrack(kick: 0.9, bass: 0.2), 4)])
        let hats = layers([(SyntheticTrack(hats: 0.12), 4)])
        let vocal = layers([(SyntheticTrack(vocal: 0.3), 4)])
        let groove = layers([(SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.12, snare: 0.3, vocal: 0.12), 4)])
        print(String(format: "Brightness: kick and bass %.2f, sung vowel %.2f, full groove %.2f, hats %.2f; the vowel reads %.2f (A = 9), tonality %.2f",
                     mean(kicks, \.brightness), mean(vocal, \.brightness), mean(groove, \.brightness), mean(hats, \.brightness),
                     vocal.last!.pitchClass, mean(vocal, \.tonality, after: 1.5)))
        check(mean(kicks, \.brightness) < 0.25 && mean(hats, \.brightness) > 0.75, "kicks must read dark and hats bright")
        check(mean(kicks, \.brightness) < mean(groove, \.brightness) && mean(groove, \.brightness) < mean(hats, \.brightness),
              "a full groove must sit between its kick and its hats")
        check(abs(circular(9, vocal.last!.pitchClass)) < 0.5, "a vowel sung on A must read as A")
        // The groove's pad is an A major chord under the drums: it holds A without jitter.
        let grooveDrift = groove.dropFirst(45).map { abs(circular(9, $0.pitchClass)) }.max()!
        print(String(format: "Harmony: the full groove (A major pad, drums) reads A within %.2f, tonality %.2f",
                     grooveDrift, mean(groove, \.tonality, after: 1.5)))
        check(grooveDrift < 0.3, "drums over an A major pad must hold A steadily (off by up to \(grooveDrift))")

        buildChecks()
    }


    /// An 8 s riser (noise behind an opening low-pass, with snare clicks
    /// speeding up from two a second to sixteen), `gap` seconds of silence,
    /// then a loud section with the kick and bass back.
    static func riser(gap: Float = 0, seconds: Float = 14) -> [MusicLayers] {
        var random = SeededRandom(seed: 9)
        var noise = DrumNoise()
        var filtered: Float = 0
        var clicks: [Float] = []
        var interval: Float = 0.5, time: Float = 0.5
        while time < 8 {
            clicks.append(time)
            time += interval
            interval = max(0.06, interval * 0.85)
        }
        var next = 0
        let drop = SyntheticTrack(kick: 0.95, bass: 0.3, pad: 0.25, hats: 0.12, snare: 0.3, kickOffset: 8 + gap)
        return analyze(seconds) { t in
            if t >= 8 + gap { return drop.sample(at: t, noise: &noise) }
            guard t < 8 else { return 0 }
            // A one-pole low-pass opening from 200 Hz to 10 kHz, getting louder as it goes.
            let cutoff = 200 * powf(50, t / 8)
            filtered += (random.next() * 2 - 1 - filtered) * (1 - expf(-2 * .pi * cutoff / SpectrumAnalyzer.sampleRate))
            var value = (0.1 + 0.25 * t / 8) * filtered
            while next + 1 < clicks.count, clicks[next + 1] <= t { next += 1 }
            if t >= clicks[next] {
                let since = t - clicks[next]
                value += (0.15 + 0.25 * t / 8) * min(1, since / 0.002) * noise.rattle() * expf(-since / 0.025)
            }
            return value
        }
    }

    /// Builds rise through a riser and fire one drop when the kick returns;
    /// steady music and a breakdown without a riser don't.
    static func buildChecks() {
        let song = riser()
        let drops = hits(song, \.drop)
        let peak = song.prefix(240).map(\.build).max()!
        let after = song.suffix(60).map(\.build).max()!
        print(String(format: "Build: the riser builds to %.2f (%.2f at 4 s, %.2f at 6 s); drops at %@ s (strength %@); build %.2f two seconds later",
                     peak, song[120].build, song[180].build, drops.map { String(format: "%.2f", Float($0) / 30) }.joined(separator: ", "),
                     drops.map { String(format: "%.2f", song[$0].drop) }.joined(separator: ", "), after))
        check(peak > 0.6, "an 8 s riser must build above 0.6 (\(peak))")
        check(drops.count == 1, "exactly one drop must fire (\(drops))")
        check(drops.allSatisfy { (240...243).contains($0) }, "the drop must land within 100 ms of the section change (frame \(drops))")
        check(after < 0.2, "the build must reset after the drop (\(after))")

        // A beat of silence before the drop, as many tracks leave: the build holds over it.
        let paused = riser(gap: 0.5, seconds: 12)
        let pausedDrops = hits(paused, \.drop)
        print(String(format: "Build: with half a second of silence before it, the drop lands at %@ s (build %.2f just before)",
                     pausedDrops.map { String(format: "%.2f", Float($0) / 30) }.joined(separator: ", "), paused[254].build))
        check(pausedDrops.count == 1 && pausedDrops.allSatisfy { (255...258).contains($0) },
              "a drop after a pause must still fire once, as the music returns (\(pausedDrops))")

        let loop = layers([(SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.12, snare: 0.3, vocal: 0.12), 20)])
        let loopBuild = loop.map(\.build).max()!
        print(String(format: "Build: a steady four-on-the-floor builds to at most %.2f, %d drops", loopBuild, hits(loop, \.drop).count))
        check(loopBuild < 0.2, "a steady groove must not build (\(loopBuild))")
        check(hits(loop, \.drop).isEmpty, "a steady groove must not drop")

        // A breakdown to a pad and back, with no riser: the kick returning alone isn't a drop.
        let groove = SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.12, snare: 0.3)
        let breakdown = layers([(groove, 6), (SyntheticTrack(pad: 0.15, vocal: 0.1), 6), (groove, 6)])
        let breakdownBuild = breakdown.map(\.build).max()!
        print(String(format: "Build: a breakdown and back builds to at most %.2f, %d drops", breakdownBuild, hits(breakdown, \.drop).count))
        check(breakdownBuild < 0.3 && hits(breakdown, \.drop).isEmpty, "a breakdown without a riser must not build or drop")
        songBuildChecks()
    }

    /// Builds as songs write them: a house build that keeps its kick under the
    /// riser, and a pop pre-chorus that only gets louder and brighter. A fade-in
    /// and a verse cutting to a louder chorus aren't builds.
    static func songBuildChecks() {
        let house = houseBuild()
        let houseDrops = hits(house, \.drop)
        let housePeak = house[240..<480].map(\.build).max()!
        print(String(format: "Build: a house build over a steady kick reaches %.2f (%.2f halfway); drops at %@ s",
                     housePeak, house[360].build, houseDrops.map { String(format: "%.2f", Float($0) / 30) }.joined(separator: ", ")))
        check(housePeak > 0.5, "a riser and snare roll must build even with the kick going (\(housePeak))")
        // Over a held kick, a drop is only sure once its bass stays up between the kicks.
        check(houseDrops.count == 1 && houseDrops.allSatisfy { (480...490).contains($0) },
              "the house build's drop must fire once, within a third of a second of landing (\(houseDrops))")
        check(house.prefix(240).map(\.build).max()! < 0.2, "the groove before the build must not build")

        let pop = popSong(preChorus: 8)
        let popPeak = pop[300..<540].map(\.build).max()!
        print(String(format: "Build: a pop pre-chorus reaches %.2f; the verse at most %.2f; the chorus %.2f, %.2f, %.2f 1, 3, 5 s in; drops at %@ s",
                     popPeak, pop.prefix(300).map(\.build).max()!, pop[570].build, pop[630].build, pop[690].build,
                     hits(pop, \.drop).map { String(format: "%.2f", Float($0) / 30) }.joined(separator: ", ")))
        check(popPeak > 0.35, "a pre-chorus getting louder and brighter must build (\(popPeak))")
        check(pop.prefix(300).map(\.build).max()! < 0.2, "a steady verse must not build")
        let popDrops = hits(pop, \.drop)
        check(popDrops.count == 1 && popDrops.allSatisfy { (540...552).contains($0) } && pop[630].build < 0.2,
              "the chorus must release the pre-chorus's build once, as it lands (\(popDrops), \(pop[630].build) 3 s in)")

        let cut = popSong(preChorus: 0)
        let cutBuild = cut.map(\.build).max()!
        print(String(format: "Build: a verse cutting to a louder chorus builds to at most %.2f, %d drops", cutBuild, hits(cut, \.drop).count))
        check(cutBuild < 0.2 && hits(cut, \.drop).isEmpty, "a verse cutting to a louder chorus isn't a build (\(cutBuild))")

        let groove = SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.12, snare: 0.3, vocal: 0.12)
        var noise = DrumNoise()
        let fade = analyze(16) { t in min(1, t / 8) * groove.sample(at: t, noise: &noise) }
        let fadeBuild = fade.map(\.build).max()!
        print(String(format: "Build: an 8 s fade-in builds to at most %.2f, %d drops", fadeBuild, hits(fade, \.drop).count))
        check(fadeBuild < 0.2 && hits(fade, \.drop).isEmpty, "a fade-in isn't a build (\(fadeBuild))")
    }

    /// 8 s of groove; an 8 s build where the kick keeps going, the bass thins
    /// out, a riser opens on top and the snares roll in steps (four a second,
    /// then eight); then the drop, louder.
    static func houseBuild() -> [MusicLayers] {
        var random = SeededRandom(seed: 5)
        var noise = DrumNoise()
        var filtered: Float = 0
        let groove = SyntheticTrack(kick: 0.9, bass: 0.2, pad: 0.15, hats: 0.12, snare: 0.3)
        let drop = SyntheticTrack(kick: 0.95, bass: 0.35, pad: 0.25, hats: 0.14, snare: 0.35)
        return analyze(22) { t in
            if t < 8 { return groove.sample(at: t, noise: &noise) }
            if t >= 16 { return drop.sample(at: t, noise: &noise) }
            let into = (t - 8) / 8
            var track = groove
            track.bass = 0.2 * (1 - into)
            track.snare = into < 0.25 ? 0.3 : 0
            var value = track.sample(at: t, noise: &noise)
            let cutoff = 300 * powf(27, into)
            filtered += (random.next() * 2 - 1 - filtered) * (1 - expf(-2 * .pi * cutoff / SpectrumAnalyzer.sampleRate))
            value += (0.05 + 0.2 * into) * filtered
            if into >= 0.25 {
                let interval: Float = into < 0.75 ? 0.25 : 0.125
                let since = (t - 8).truncatingRemainder(dividingBy: interval)
                value += (0.2 + 0.15 * into) * min(1, since / 0.002) * noise.rattle() * expf(-since / 0.04)
            }
            return value
        }
    }

    /// A 10 s verse; a pre-chorus of `preChorus` seconds where hats come in, a
    /// bright pad swells and the mix gets about 3 dB louder, with the beat
    /// unchanged; then 6 s of a louder chorus.
    static func popSong(preChorus: Float) -> [MusicLayers] {
        var noise = DrumNoise()
        let verse = SyntheticTrack(kick: 0.6, bass: 0.12, pad: 0.12, snare: 0.25, vocal: 0.12)
        let chorus = SyntheticTrack(kick: 0.8, bass: 0.25, pad: 0.2, hats: 0.12, snare: 0.3, vocal: 0.18, gain: 1.4)
        let bright = { (t: Float) in (1...12).reduce(Float(0)) { $0 + sinf(2 * .pi * 330 * Float($1) * t) / Float($1) } / 3 }
        return analyze(16 + preChorus) { t in
            if t < 10 { return verse.sample(at: t, noise: &noise) }
            if t >= 10 + preChorus { return chorus.sample(at: t, noise: &noise) + 0.06 * bright(t) }
            let into = (t - 10) / preChorus
            var track = verse
            track.hats = 0.12 * into
            track.gain = 1 + 0.4 * into
            return track.sample(at: t, noise: &noise) + 0.06 * into * bright(t)
        }
    }
}
