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
}

enum CoverColorExtractor {
    /// Picks a vivid accent from cover art: hue buckets weighted by saturation × brightness
    /// over a 24×24 thumbnail. Contrast is chosen separately from luminance.
    /// Returns nil for (near-)greyscale covers, so the caller keeps its default.
    static func extract(of image: CGImage) -> RGB? {
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

        var weight = [Double](repeating: 0, count: 12)
        var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: 12)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let c = RGB(r: Double(pixels[i]) / 255, g: Double(pixels[i + 1]) / 255, b: Double(pixels[i + 2]) / 255)
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

    private static func hsv(_ c: RGB) -> (Double, Double, Double) {
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
