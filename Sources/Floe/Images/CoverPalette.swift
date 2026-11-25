import CoreGraphics
import Foundation

struct RGB: Hashable, Sendable {
    var r, g, b: Double
    /// Tint's own colour when there's no cover to take one from: the calm blue
    /// of the Blue accent, so nothing borrows a streaming service's green.
    static let fallback = RGB(r: 0.32, g: 0.65, b: 1)
    var luminance: Double {
        0.2126 * OKLab.linear(r) + 0.7152 * OKLab.linear(g) + 0.0722 * OKLab.linear(b)
    }
    /// Black text has more contrast than white above this luminance (WCAG).
    var usesDarkText: Bool { luminance > 0.179 }
    func distance(to other: RGB) -> Double {
        ((r - other.r) * (r - other.r) + (g - other.g) * (g - other.g) + (b - other.b) * (b - other.b)).squareRoot()
    }
}

/// OKLab (Björn Ottosson): perceptual lightness and two opponent axes, so a
/// colour's lightness and chroma can change without its hue drifting the way
/// it does in HSV (blue turning violet as it lightens, yellow going olive).
struct OKLab: Equatable, Sendable {
    var l, a, b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l; self.a = a; self.b = b
    }

    init(l: Double, chroma: Double, hue: Double) {
        self.init(l: l, a: chroma * cos(hue), b: chroma * sin(hue))
    }

    init(_ c: RGB) {
        self.init(linear: (Self.linear(c.r), Self.linear(c.g), Self.linear(c.b)))
    }

    init(linear c: (Double, Double, Double)) {
        let l = cbrt(0.4122214708 * c.0 + 0.5363325363 * c.1 + 0.0514459929 * c.2)
        let m = cbrt(0.2119034982 * c.0 + 0.6806995451 * c.1 + 0.1073969566 * c.2)
        let s = cbrt(0.0883024619 * c.0 + 0.2817188376 * c.1 + 0.6299787005 * c.2)
        self.init(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                  a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                  b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    var chroma: Double { (a * a + b * b).squareRoot() }
    /// Radians; meaningless for greys.
    var hue: Double { atan2(b, a) }

    /// Linear-light sRGB, unclamped: out-of-gamut colours fall outside 0…1.
    var linear: (Double, Double, Double) {
        let cl = l + 0.3963377774 * a + 0.2158037573 * b
        let cm = l - 0.1055613458 * a - 0.0638541728 * b
        let cs = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = cl * cl * cl, m3 = cm * cm * cm, s3 = cs * cs * cs
        return (4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }

    var isInGamut: Bool {
        let c = linear, e = 0.0001
        return min(c.0, c.1, c.2) >= -e && max(c.0, c.1, c.2) <= 1 + e
    }

    /// The same lightness and hue with only as much chroma as sRGB can show.
    var inGamut: OKLab {
        guard !isInGamut else { return self }
        var low = 0.0, high = chroma
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if OKLab(l: l, chroma: mid, hue: hue).isInGamut { low = mid } else { high = mid }
        }
        return OKLab(l: l, chroma: low, hue: hue)
    }

    var rgb: RGB {
        let c = OKLab(l: min(max(l, 0), 1), a: a, b: b).inGamut.linear
        func encode(_ x: Double) -> Double {
            let x = min(max(x, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return RGB(r: encode(c.0), g: encode(c.1), b: encode(c.2))
    }

    func distance(to other: OKLab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// A new lightness and chroma, same hue.
    func with(l: Double, chroma: Double) -> OKLab {
        OKLab(l: l, chroma: max(0, chroma), hue: hue).inGamut
    }

    static func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
}

/// Reads a cover's colours once, off the main thread, from a 32×32 thumbnail.
///
/// Pixels are weighed in OKLab by how much they catch the eye (area, chroma,
/// lightness, a little centre bias), so a small neon mark on black can lead
/// but a speck can't, and deep reds or navies on black still count. A cover
/// whose only colour is one consistent tint (sepia, a violet haze) leads with
/// that tint, as quietly as it is. A cover with no colour at all is neutral:
/// its colours become its own tones (silver, white, greys) with whatever faint
/// warm or cool cast it has. No hue is ever invented, and nothing falls back
/// to a fixed colour while a cover exists.
enum CoverColorExtractor {
    /// Live backgrounds always get this many colours, so their shaders have fixed slots.
    static let paletteSize = 5

    struct Colors: Equatable, Sendable {
        /// The interface accent, at a lightness that reads on the dark glass:
        /// the cover's leading colour, or a light silver for a neutral cover.
        var accent: RGB
        /// `paletteSize` distinct colours for the live background, accent first,
        /// each bright enough to glow.
        var colors: [RGB]
        /// The cover is black, white or grey (or nearly): the colours are tones.
        var isNeutral: Bool
        /// The leading colour as it appears on the cover; nil when neutral.
        var source: RGB?
    }

    static func colors(of image: CGImage) -> Colors? {
        guard let samples = samples(of: image) else { return nil }
        let reading = Reading(samples)
        guard let lead = reading.lead ?? reading.tint else {
            let accent = neutralAccent(cast: reading.cast)
            return Colors(accent: accent.rgb, colors: neutralColors(reading, accent: accent).map(\.rgb),
                          isNeutral: true, source: nil)
        }
        return Colors(accent: accent(for: lead.color).rgb, colors: chromaticColors(reading, lead: lead).map(\.rgb),
                      isNeutral: false, source: lead.color.rgb)
    }

    /// The cover's leading colour as it appears there, or nil for a neutral cover.
    static func extract(of image: CGImage) -> RGB? {
        colors(of: image)?.source
    }

    /// The live background's colours for a cover; `accent`'s shades stand in
    /// only when the image can't be read.
    static func palette(of image: CGImage, accent: RGB) -> [RGB] {
        colors(of: image)?.colors ?? shades(of: accent)
    }

    /// Five shades of one colour, itself first: darker, lighter and paler
    /// neighbours a few degrees of hue apart, so a fixed accent still fills
    /// every slot without borrowing hues it doesn't have.
    static func shades(of base: RGB) -> [RGB] {
        fill([], from: glow(OKLab(base))).map(\.rgb)
    }

    /// Text, icons and the visualizer on the dark glass: lifted to where the
    /// system's dark-mode colours sit (reds and blues stay vivid lower down,
    /// about L 0.62; others need 0.72), saturation and hue kept.
    static func highlight(of accent: RGB) -> RGB {
        let c = OKLab(accent)
        let lowest = c.chroma < 0.03 ? 0.72 : max(0.62, min(cuspLightness(c.hue), 0.72))
        guard c.l < lowest else { return accent }
        return lifted(c, to: lowest...1).rgb
    }

    // MARK: - Reading the cover

    private struct Sample {
        var color: OKLab
        /// Centre bias: the subject usually sits mid-frame, titles at the edges.
        var weight: Double
    }

    private struct Cluster {
        var color: OKLab
        /// Share of the cover's attention, roughly a fraction of its area.
        var salience: Double
    }

    /// Chromatic hue clusters by salience, plus the neutral tones and their cast.
    private struct Reading {
        var clusters: [Cluster] = []
        /// Neutral tones lightest first, with the share of the cover each covers.
        var tones: [Cluster] = []
        /// The neutral pixels' average a/b, weighted toward the light ones.
        var cast = OKLab(l: 0, a: 0, b: 0)

        /// The colour that leads, if any colour is salient enough to.
        var lead: Cluster? {
            clusters.first.flatMap { $0.salience >= 0.02 && colourfulness($0.color) >= 0.3 ? $0 : nil }
        }

        /// A cover with no colour that stands out but one consistent tint
        /// (sepia, a violet haze, a blue-black night sky): the tint leads, at
        /// the cover's own lightness. True black and white casts stay far below.
        var tint: Cluster? {
            guard cast.chroma >= 0.02 else { return nil }
            let lit = tones.filter { $0.color.l > 0.25 }
            let weight = lit.reduce(0) { $0 + $1.salience }
            let l = weight > 0 ? lit.reduce(0) { $0 + $1.color.l * $1.salience } / weight : 0.3
            // Averaging over every tone dilutes the tint a little; give it back.
            return Cluster(color: OKLab(l: l, chroma: cast.chroma * 1.25, hue: cast.hue), salience: weight)
        }

        init(_ samples: [Sample]) {
            let bins = 36, toneBins = 10
            var hue = [Double](repeating: 0, count: bins), hueSum = [OKLab](repeating: OKLab(l: 0, a: 0, b: 0), count: bins)
            var hueSumWeight = [Double](repeating: 0, count: bins)
            var tone = [Double](repeating: 0, count: toneBins), toneSum = [OKLab](repeating: OKLab(l: 0, a: 0, b: 0), count: toneBins)
            var total = 0.0, castWeight = 0.0
            for sample in samples {
                let c = sample.color, chroma = c.chroma
                total += sample.weight
                let colourful = colourfulness(c)
                if colourful > 0 {
                    // Vivid colours pop beyond their area; dark ones count, but less.
                    let w = colourful * min(1.6, 0.6 + chroma / 0.2) * (0.3 + 0.7 * smoothstep(0.12, 0.55, c.l)) * sample.weight
                    let angle = c.hue / (2 * .pi)
                    let bin = Int((angle - angle.rounded(.down)) * Double(bins)) % bins
                    hue[bin] += w
                    // The cluster's colour leans to its clearest pixels, so a
                    // yellow title isn't averaged into the khaki around it.
                    hueSum[bin].add(c, w * chroma)
                    hueSumWeight[bin] += w * chroma
                }
                let neutral = (1 - colourful) * sample.weight
                if neutral > 0, c.l > 0.06 {
                    let bin = min(toneBins - 1, Int(c.l * Double(toneBins)))
                    tone[bin] += neutral
                    toneSum[bin].add(c, neutral)
                    // A cast shows in the light tones; near-black only carries noise.
                    let w = neutral * c.l * c.l
                    cast.a += c.a * w; cast.b += c.b * w; castWeight += w
                }
            }
            guard total > 0 else { return }
            if castWeight > 0 { cast.a /= castWeight; cast.b /= castWeight }

            // Greedy peaks: take the strongest hue, claim ±15° around it, repeat.
            // A wider window averaged a golden title and green foliage into olive.
            var remaining = hue
            while clusters.count < 8 {
                let smoothed = (0..<bins).map { remaining[($0 + bins - 1) % bins] + 2 * remaining[$0] + remaining[($0 + 1) % bins] }
                guard let peak = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }), remaining[peak] > 0 || smoothed[peak] > 0
                else { break }
                var weight = 0.0, sumWeight = 0.0, sum = OKLab(l: 0, a: 0, b: 0)
                for offset in -1...1 {
                    let i = (peak + offset + bins) % bins
                    guard remaining[i] > 0 else { continue }
                    weight += remaining[i]
                    sum.add(hueSum[i], 1)
                    sumWeight += hueSumWeight[i]
                    remaining[i] = 0
                }
                guard weight > 0, sumWeight > 0 else { break }
                let salience = weight / total
                if salience < 0.002 { break }
                clusters.append(Cluster(color: OKLab(l: sum.l / sumWeight, a: sum.a / sumWeight, b: sum.b / sumWeight),
                                        salience: salience))
            }
            clusters.sort { $0.salience > $1.salience }

            tones = (0..<toneBins).reversed().compactMap { i in
                guard tone[i] > 0 else { return nil }
                return Cluster(color: OKLab(l: toneSum[i].l / tone[i], a: toneSum[i].a / tone[i], b: toneSum[i].b / tone[i]),
                               salience: tone[i] / total)
            }
        }
    }

    // MARK: - Turning the reading into colours

    /// The interface accent from the cover's colour. Saturated colours may
    /// stay deep, down to where their hue is most vivid (a deep red or royal
    /// blue pill with white text still reads as the cover); dusty ones are
    /// lifted further, or they'd read as mud. Yellows and greens only look
    /// like themselves when light; lower down they turn olive.
    private static func accent(for source: OKLab) -> OKLab {
        let cusp = cuspLightness(source.hue)
        let lowest = max(min(0.5, cusp), cusp - 0.12) + 0.2 * (1 - smoothstep(0.25, 0.6, saturation(source)))
        return lifted(source, to: min(lowest, 0.88)...0.9)
    }

    /// A colour as a background light: bright enough to glow, as vivid as
    /// it is on the cover.
    private static func glow(_ c: OKLab) -> OKLab {
        guard c.chroma >= 0.03 else { return c.with(l: min(max(c.l, 0.55), 0.95), chroma: c.chroma) }
        let cusp = cuspLightness(c.hue)
        let lowest = max(min(0.6, cusp + 0.05), cusp - 0.12) + 0.1 * (1 - smoothstep(0.25, 0.6, saturation(c)))
        return lifted(c, to: min(lowest, 0.88)...0.9)
    }

    /// Moves a colour into a lightness range keeping its saturation: its
    /// chroma as a share of the most sRGB can show at that lightness and hue,
    /// so a deep navy lifts to a clear blue rather than a grey-blue.
    private static func lifted(_ c: OKLab, to range: ClosedRange<Double>) -> OKLab {
        let l = min(max(c.l, range.lowerBound), range.upperBound)
        guard abs(l - c.l) > 0.001 else { return c.inGamut }
        let chroma = min(saturation(c) * maxChroma(l: l, hue: c.hue), c.chroma * 1.8, 0.26)
        return c.with(l: l, chroma: chroma)
    }

    /// Chroma as a share of the most sRGB can show at this lightness and hue.
    private static func saturation(_ c: OKLab) -> Double {
        min(1, c.chroma / max(maxChroma(l: c.l, hue: c.hue), 0.001))
    }

    private static func maxChroma(l: Double, hue: Double) -> Double {
        OKLab(l: l, chroma: 0.4, hue: hue).inGamut.chroma
    }

    /// The lightness where a hue is most vivid in sRGB: about 0.45 for blue,
    /// 0.63 for red, 0.87 for green, 0.97 for yellow.
    private static func cuspLightness(_ hue: Double) -> Double {
        var best = (l: 0.5, chroma: 0.0)
        for step in 0...28 {
            let l = 0.3 + Double(step) * 0.025, chroma = maxChroma(l: l, hue: hue)
            if chroma > best.chroma { best = (l, chroma) }
        }
        return best.l
    }

    /// A neutral cover's accent: a light silver carrying the cover's cast,
    /// barely warm or cool, never a colour of its own.
    private static func neutralAccent(cast: OKLab) -> OKLab {
        let chroma = cast.chroma
        return OKLab(l: 0.9, chroma: chroma < 0.004 ? 0 : min(chroma, 0.02), hue: cast.hue).inGamut
    }

    /// The leading colour, then the cover's other colours by salience, then
    /// one of its light neutral tones if it has plenty, then shades of the lead.
    private static func chromaticColors(_ reading: Reading, lead: Cluster) -> [OKLab] {
        var chosen = [glow(lead.color)]
        let floor = max(0.006, lead.salience * 0.06)
        for cluster in reading.clusters.dropFirst() where chosen.count < paletteSize {
            guard cluster.salience >= floor, colourfulness(cluster.color) >= 0.3 else { continue }
            let color = glow(cluster.color)
            if chosen.allSatisfy({ $0.distance(to: color) > 0.05 }) { chosen.append(color) }
        }
        // A white or silver ground is part of the cover's look; black isn't a light.
        let lights = reading.tones.filter { $0.color.l > 0.65 && $0.color.chroma < 0.03 }
        let lightShare = lights.reduce(0) { $0 + $1.salience }
        if chosen.count < paletteSize, lightShare >= 0.25, let light = lights.max(by: { $0.salience < $1.salience }) {
            let tone = neutral(light.color)
            if chosen.allSatisfy({ $0.distance(to: tone) > 0.06 }) { chosen.append(tone) }
        }
        return fill(chosen, from: glow(lead.color))
    }

    /// The accent's silver, then the cover's own tones lightest first, then
    /// lighter and darker silvers. Each keeps its own faint cast.
    private static func neutralColors(_ reading: Reading, accent: OKLab) -> [OKLab] {
        var chosen = [accent]
        for tone in reading.tones where chosen.count < paletteSize && tone.salience >= 0.03 && tone.color.l > 0.25 {
            // Map the cover's tones into lights; black is the dark around them, not a light.
            let color = neutral(tone.color).with(l: 0.5 + 0.45 * tone.color.l, chroma: min(tone.color.chroma, 0.025))
            if chosen.allSatisfy({ $0.distance(to: color) > 0.06 }) { chosen.append(color) }
        }
        return fill(chosen, from: accent)
    }

    /// A tone kept neutral: its own faint cast, no more.
    private static func neutral(_ c: OKLab) -> OKLab {
        c.with(l: min(max(c.l, 0.55), 0.95), chroma: min(c.chroma, 0.025))
    }

    /// Tops `chosen` up to `paletteSize` from `base` and its neighbours: in
    /// their designed order while they stand apart, then whichever is least
    /// like the colours already chosen, so no slot repeats another.
    private static func fill(_ chosen: [OKLab], from base: OKLab) -> [OKLab] {
        var chosen = chosen
        var pool = [base] + neighbours(of: base)
        func gap(_ c: OKLab) -> Double { chosen.map { $0.distance(to: c) }.min() ?? 1 }
        while chosen.count < paletteSize, !pool.isEmpty {
            let pick = pool.firstIndex { gap($0) > 0.045 } ?? pool.indices.max { gap(pool[$0]) < gap(pool[$1]) }!
            chosen.append(pool.remove(at: pick))
        }
        while chosen.count < paletteSize { chosen.append(base) }
        return chosen
    }

    /// Darker, lighter, paler and richer versions of `base`, with at most 6°
    /// of hue drift so they stay the same colour. A step that would leave the
    /// range a background light can use goes the other way instead, so a deep
    /// blue near the bottom of the range still gets four neighbours.
    private static func neighbours(of base: OKLab) -> [OKLab] {
        let degree = Double.pi / 180, range = 0.45...0.96
        let steps: [(l: Double, chroma: Double, hue: Double)] = [
            (-0.12, 1.08, -4), (0.1, 0.75, 5), (-0.06, 0.78, 6), (0.17, 0.5, -5), (-0.22, 1.1, -3), (-0.3, 1, 4), (0.06, 0.55, -6),
        ]
        return steps.compactMap { step in
            guard let l = [base.l + step.l, base.l - step.l].first(where: range.contains) else { return nil }
            return OKLab(l: l, chroma: base.chroma * step.chroma, hue: base.hue + step.hue * degree).inGamut
        }
    }

    private static func samples(of image: CGImage) -> [Sample]? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let linear = (0..<256).map { OKLab.linear(Double($0) / 255) }
        let centre = Double(side - 1) / 2
        return (0..<side * side).map { i in
            let p = i * 4
            let dx = (Double(i % side) - centre) / centre, dy = (Double(i / side) - centre) / centre
            return Sample(color: OKLab(linear: (linear[Int(pixels[p])], linear[Int(pixels[p + 1])], linear[Int(pixels[p + 2])])),
                          weight: 1 - 0.35 * min(1, (dx * dx + dy * dy) / 2))
        }
    }

    /// 0 for a grey, 1 for a clear colour. Light colours show their chroma
    /// sooner (a pastel at 0.04 is plainly tinted; a near-black at 0.04 is noise).
    private static func colourfulness(_ c: OKLab) -> Double {
        let light = smoothstep(0.55, 0.95, c.l)
        return smoothstep(0.03 - 0.005 * light, 0.09 - 0.025 * light, c.chroma)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func hsv(_ c: RGB) -> (Double, Double, Double) {
        let maxV = max(c.r, c.g, c.b), minV = min(c.r, c.g, c.b), d = maxV - minV
        var h = 0.0
        if d > 0 {
            if maxV == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
            else if maxV == c.g { h = (c.b - c.r) / d + 2 }
            else { h = (c.r - c.g) / d + 4 }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, maxV == 0 ? 0 : d / maxV, maxV)
    }
}

private extension OKLab {
    mutating func add(_ c: OKLab, _ weight: Double) {
        l += c.l * weight; a += c.a * weight; b += c.b * weight
    }
}
