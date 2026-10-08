import Accelerate
import Foundation

struct SpectrumFrame: Equatable, Sendable {
    /// Absolute band energy, 0…1 across a 65 dB range.
    var bands: [Float]
    /// What the visuals draw: each band relative to its own recent range, so a
    /// song's fixed tilt (bass always louder) doesn't decide the shape.
    var levels: [Float]
    var rms: Float
    static let quiet = SpectrumFrame(bands: Array(repeating: 0, count: 48),
                                     levels: Array(repeating: 0, count: 48), rms: 0)
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
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private var average = [Float](repeating: 0, count: bandCount)
    private var spread = [Float](repeating: 0, count: bandCount)
    private var levels = [Float](repeating: 0, count: bandCount)
    private var adapted = 0
    private var level: Float = 0
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
    }

    /// Append the newest block to a rolling 46 ms window; input buffers are reusable.
    func process(left inputLeft: [Float], right inputRight: [Float], count: Int) -> SpectrumFrame {
        let count = min(max(0, count), Self.size, inputLeft.count, inputRight.count)
        if count == 0 {
            for i in smoothed.indices { smoothed[i] *= 0.78 }
            level *= 0.78
            adapt()
            return SpectrumFrame(bands: smoothed, levels: levels, rms: level)
        }
        append(inputLeft, count: count, to: &left)
        append(inputRight, count: count, to: &right)
        var leftMean: Float = 0, rightMean: Float = 0
        vDSP_measqv(left, 1, &leftMean, vDSP_Length(Self.size))
        vDSP_measqv(right, 1, &rightMean, vDSP_Length(Self.size))
        let rms = sqrtf((leftMean + rightMean) * 0.5)
        level += (rms - level) * (rms > level ? 0.8 : 0.18)
        transform(left)
        stereoPower = power
        transform(right)
        let scale = powf(2 / Float(Self.size), 2) * 0.5
        for i in power.indices { stereoPower[i] = (stereoPower[i] + power[i]) * scale }
        for (i, range) in ranges.enumerated() {
            let maximum = range.reduce(Float(0)) { max($0, stereoPower[$1]) }
            let db = 10 * log10f(max(maximum, 1e-12))
            let target = min(1, max(0, (db + 65) / 65))
            smoothed[i] += (target - smoothed[i]) * (target > smoothed[i] ? 0.82 : 0.18)
        }
        adapt()
        return SpectrumFrame(bands: smoothed, levels: levels, rms: level)
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

    private func transform(_ samples: [Float]) {
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
