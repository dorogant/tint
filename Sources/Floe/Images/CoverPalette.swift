import CoreGraphics
import Foundation

struct RGB: Equatable, Sendable {
    var r, g, b: Double
    static let fallback = RGB(r: 0.12, g: 0.84, b: 0.38)
    var luminance: Double {
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    var usesDarkText: Bool { luminance > 0.179 }
    func distance(to other: RGB) -> Double {
        ((r - other.r) * (r - other.r) + (g - other.g) * (g - other.g) + (b - other.b) * (b - other.b)).squareRoot()
    }
}

enum CoverColorExtractor {
    /// Live backgrounds always get this many colours, so their shaders have fixed slots.
    static let paletteSize = 5

    /// Picks a vivid accent from cover art: hue buckets weighted by saturation × brightness
    /// over a 24×24 thumbnail. Contrast is chosen separately from luminance.
    /// Returns nil for (near-)greyscale covers, so the caller keeps its default.
    static func extract(of image: CGImage) -> RGB? {
        guard let pixels = thumbnail(of: image) else { return nil }
        var weight = [Double](repeating: 0, count: 12)
        var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: 12)
        for c in pixels {
            let (h, s, v) = hsv(c)
            let w = s * s * v // favour saturated, bright pixels
            guard s > 0.2, v > 0.2 else { continue }
            let bucket = min(Int(h * 12), 11)
            weight[bucket] += w
            sums[bucket].r += c.r * w; sums[bucket].g += c.g * w; sums[bucket].b += c.b * w
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 1.5 else { return nil }
        let avg = RGB(r: sums[best].r / weight[best], g: sums[best].g / weight[best], b: sums[best].b / weight[best])
        return avg
    }

    /// A few distinct colours for the live background, accent first, from the same
    /// thumbnail. Finer hue buckets find the cover's other colours; a cover with
    /// fewer than five gets neighbouring shades of its accent instead of greys.
    static func palette(of image: CGImage, accent: RGB) -> [RGB] {
        guard let pixels = thumbnail(of: image) else { return shades(of: accent) }
        let bucketCount = 18
        var weight = [Double](repeating: 0, count: bucketCount)
        var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: bucketCount)
        for c in pixels {
            let (h, s, v) = hsv(c)
            guard s > 0.2, v > 0.2 else { continue }
            let w = s * v
            let bucket = min(Int(h * Double(bucketCount)), bucketCount - 1)
            weight[bucket] += w
            sums[bucket].r += c.r * w; sums[bucket].g += c.g * w; sums[bucket].b += c.b * w
        }
        // A colour needs a few pixels' worth of weight, so specks don't count.
        let candidates = weight.indices.filter { weight[$0] > 2 }.sorted { weight[$0] > weight[$1] }
            .map { RGB(r: sums[$0].r / weight[$0], g: sums[$0].g / weight[$0], b: sums[$0].b / weight[$0]) }
        var chosen = [polish(accent)]
        for color in candidates.map(polish) where chosen.count < paletteSize {
            if chosen.allSatisfy({ $0.distance(to: color) > 0.22 }) { chosen.append(color) }
        }
        let shades = shades(of: accent)
        if chosen.count == 1 { return shades }
        for shade in shades where chosen.count < paletteSize {
            if chosen.allSatisfy({ $0.distance(to: shade) > 0.12 }) { chosen.append(shade) }
        }
        for shade in shades where chosen.count < paletteSize { chosen.append(shade) }
        return chosen
    }

    /// Five neighbouring shades of one colour: the colour itself, darker and
    /// lighter neighbours and two hue-shifted ones, all kept chromatic.
    static func shades(of base: RGB) -> [RGB] {
        let (h, s, v) = hsv(polish(base))
        let s0 = max(s, 0.35)
        return [(0, s0, v), (-0.06, s0, v * 0.72), (0.07, s0 * 0.85, 1), (-0.13, s0 * 0.9, v * 0.9), (0.14, s0 * 0.55, 1)]
            .map { rgb(h: h + $0.0, s: min(1, $0.1), v: min(1, $0.2)) }
    }

    /// Keeps the hue but lifts dull or dark picks, so every slot can glow.
    private static func polish(_ c: RGB) -> RGB {
        let (h, s, v) = hsv(c)
        return rgb(h: h, s: min(1, max(s, 0.3) * 1.08), v: 0.55 + 0.45 * v)
    }

    private static func thumbnail(of image: CGImage) -> [RGB]? {
        let side = 24
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
        return stride(from: 0, to: pixels.count, by: 4).map {
            RGB(r: Double(pixels[$0]) / 255, g: Double(pixels[$0 + 1]) / 255, b: Double(pixels[$0 + 2]) / 255)
        }
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

    static func rgb(h: Double, s: Double, v: Double) -> RGB {
        let h = (h - h.rounded(.down)) * 6
        let i = Int(h) % 6, f = h - h.rounded(.down)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }
}
