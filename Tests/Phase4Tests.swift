import Foundation
import Metal

@main
struct Phase4Tests {
    static func main() {
        let silence = SpectrumAnalyzer()!
        let zero = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        let quiet = silence.process(left: zero, right: zero, count: zero.count)
        precondition(quiet.rms == 0 && quiet.bands.allSatisfy { $0 == 0 } && quiet.levels.allSatisfy { $0 == 0 })

        for frequency: Float in [220, 1000, 8000] {
            let analyzer = SpectrumAnalyzer()!
            let input = tone(frequency)
            let frame = analyzer.process(left: input, right: input, count: input.count)
            let peak = frame.bands.indices.max { frame.bands[$0] < frame.bands[$1] }!
            let center = SpectrumAnalyzer.frequency(forBand: peak)
            precondition(abs(log2f(center / frequency)) < 0.35, "frequency band is wrong")
            precondition(frame.rms > 0.3 && frame.bands[peak] > 0.6)
            precondition(frame.bands.allSatisfy { $0.isFinite && (0...1).contains($0) })
        }

        let stereo = SpectrumAnalyzer()!
        let input = tone(1000)
        let inverted = input.map { -$0 }
        let antiPhase = stereo.process(left: input, right: inverted, count: input.count)
        precondition(antiPhase.rms > 0.3 && antiPhase.bands.max()! > 0.4, "stereo must not cancel")
        let rightOnly = SpectrumAnalyzer()!.process(left: zero, right: input, count: input.count)
        precondition(rightOnly.rms > 0.2 && rightOnly.bands.max()! > 0.4, "right channel must be analyzed")

        let rolling = SpectrumAnalyzer()!
        var frame = SpectrumFrame.quiet
        for block in 0..<8 {
            let part = Array(input[(block * 256)..<((block + 1) * 256)])
            frame = rolling.process(left: part, right: part, count: part.count)
        }
        precondition(frame.rms > 0.3 && frame.bands.max()! > 0.5)
        rolling.reset()
        let reset = rolling.process(left: zero, right: zero, count: zero.count)
        precondition(reset == SpectrumFrame.quiet, "reset must erase the previous track")

        // Fine-tuned per song, not scripted: a steady band settles below the top,
        // and a new sound elsewhere in the spectrum stands out above it.
        let adaptive = SpectrumAnalyzer()!
        let low = tone(220)
        var settled = SpectrumFrame.quiet
        for _ in 0..<150 { settled = adaptive.process(left: low, right: low, count: low.count) }
        let lowBand = settled.bands.indices.max { settled.bands[$0] < settled.bands[$1] }!
        precondition(settled.levels[lowBand] < 0.75, "a steady band must settle, not stay pinned")
        let mixed = zip(low, tone(4000)).map { $0 + $1 }
        let hit = adaptive.process(left: mixed, right: mixed, count: mixed.count)
        let highBand = (lowBand + 1..<SpectrumAnalyzer.bandCount).max { hit.bands[$0] < hit.bands[$1] }!
        precondition(hit.levels[highBand] > settled.levels[lowBand] + 0.1, "a new sound must stand out")
        precondition(hit.levels.allSatisfy { $0.isFinite && (0...1).contains($0) })

        let decay = SpectrumAnalyzer()!
        let loud = decay.process(left: input, right: input, count: input.count)
        var drained = loud
        for _ in 0..<30 { drained = decay.process(left: [], right: [], count: 0) }
        precondition(drained.rms < 0.001 && drained.bands.max()! < 0.001 && drained.levels.max()! < 0.001)
        if let device = MTLCreateSystemDefaultDevice() {
            let library = try! device.makeLibrary(source: ReactiveShader.source, options: nil)
            precondition(["floeBackgroundVertex", "floeFluidFragment", "floeBeamsFragment"].allSatisfy(library.functionNames.contains))
            print("PASS: Metal background shaders compile")
        } else { print("SKIP: Metal device unavailable") }
        print("PASS: 10 synthetic FFT checks (silence, frequency bands, stereo, rolling input, reset, adaptive levels, decay)")
    }

    private static func tone(_ frequency: Float) -> [Float] {
        (0..<SpectrumAnalyzer.size).map { 0.7 * sinf(2 * .pi * frequency * Float($0) / SpectrumAnalyzer.sampleRate) }
    }
}
