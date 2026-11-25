// Tint's icon: sound as bands of indigo, navy at the edges and ice along the middle
// line, seen through the app's scalloped cover shape on a pale body. No green and no
// sound arcs, so it never reads as Spotify's mark.
//
// The whole picture is one function of the pixel over signed distances (negative
// inside a shape), so every edge, shadow and glass rim comes from the same outline.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

typealias RGB = (r: Double, g: Double, b: Double)
typealias Shape = (Double, Double) -> Double

func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t) }
func scale(_ a: RGB, _ k: Double) -> RGB { (a.r * k, a.g * k, a.b * k) }
func smooth(_ t: Double) -> Double { let x = clamp01(t); return x * x * (3 - 2 * x) }
/// How much of a pixel at signed distance `d` the shape covers.
func cover(_ d: Double) -> Double { clamp01(0.5 - d) }
let white: RGB = (1, 1, 1)
let center = 512.0

// MARK: Shapes

func roundedSquare(half: Double, radius: Double) -> Shape {
    { x, y in
        let qx = abs(x - center) - half + radius, qy = abs(y - center) - half + radius
        return (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0) - radius
    }
}
/// The scalloped cover mask. The app's own has 22 shallow petals; twelve deeper ones
/// are still petals at 32 px, where 22 turn into a plain circle.
func scallop(tip: Double, petals: Double = 12, depth: Double = 0.1) -> Shape {
    let soft = 0.16, peak = (1 + soft * soft).squareRoot() - soft, base = tip / (1 + depth)
    func radius(_ a: Double) -> Double {
        let wave = cos(petals / 2 * (a - .pi / 2))
        return base * (1 + depth * ((wave * wave + soft * soft).squareRoot() - soft) / peak)
    }
    return { x, y in
        let dx = x - center, dy = y - center, a = atan2(dy, dx)
        // r - R is the distance along the ray; dividing by the outline's slope makes it the distance to the outline.
        let R = radius(a), slope = (radius(a + 0.002) - R) / 0.002 / R
        return ((dx * dx + dy * dy).squareRoot() - R) / (1 + slope * slope).squareRoot()
    }
}
/// Band `index` of the sound: `half` tall either side of the middle line, with a
/// different wave on its upper and lower edge so the two halves don't mirror.
func band(_ index: Int, half: Double) -> Shape {
    let n = Double(index), amp = 12 + half * 0.13
    let k1 = 2 * .pi / ((560 - n * 30) * 0.72), p1 = 0.6 + n * 1.7
    let k2 = 2 * .pi / ((500 + n * 36) * 0.72), p2 = 3.4 + n * 1.1
    func top(_ x: Double) -> Double { center + half + amp * sin(x * k1 + p1) }
    func low(_ x: Double) -> Double { center - half - amp * sin(x * k2 + p2) }
    return { x, y in
        let st = (top(x + 1) - top(x - 1)) / 2, sl = (low(x + 1) - low(x - 1)) / 2
        return max((y - top(x)) / (1 + st * st).squareRoot(), (low(x) - y) / (1 + sl * sl).squareRoot())
    }
}

// MARK: Shading

/// Navy to ice, t in 0...1.
func indigo(_ t: Double) -> RGB {
    let stops: [RGB] = [(0.20, 0.20, 0.66), (0.33, 0.42, 0.98), (0.50, 0.68, 1.0), (0.82, 0.93, 1.0)]
    let u = clamp01(t) * Double(stops.count - 1), i = min(Int(u), stops.count - 2)
    return mix(stops[i], stops[i + 1], u - Double(i))
}
/// How much of a soft shadow `s` throws on the point, the light coming from above.
func shadow(_ s: Shape, _ x: Double, _ y: Double, drop: Double, blur: Double) -> Double {
    1 - smooth((s(x, y + drop) + blur * 0.4) / blur)
}
/// Glass edge on colour `c`: denser toward the rim, then a lit line on the upper left.
func glass(_ c: RGB, _ s: Shape, _ x: Double, _ y: Double, rim: Double, light: Double) -> RGB {
    let d = s(x, y)
    let gx = (s(x + 1, y) - s(x - 1, y)) / 2, gy = (s(x, y + 1) - s(x, y - 1)) / 2
    let lit = max(0, -0.66 * gx + 0.75 * gy)
    let dense = mix(c, scale(c, 0.8), 0.5 * smooth((d + rim * 5) / (rim * 5)))
    return mix(dense, white, light * smooth((d + rim) / rim) * (0.22 + 0.78 * lit))
}
/// Diagonal sheen over a shape `size` across, brighter toward the upper left.
func sheen(_ c: RGB, _ x: Double, _ y: Double, size: Double, _ amount: Double) -> RGB {
    mix(c, white, amount * smooth((((y - center) * 0.8 - (x - center) * 0.6) / size + 0.15) / 1.3))
}

// MARK: The icon

let body = roundedSquare(half: 412, radius: 185)
let disc = scallop(tip: 306)
let bands = [236.0, 176, 118, 64, 20].enumerated().map { band($0, half: $1) }

/// The colour at a point inside the body.
func icon(_ x: Double, _ y: Double) -> RGB {
    // Pale body with a little of the disc's blue behind it.
    var c: RGB = mix((0.89, 0.91, 0.98), (0.985, 0.985, 1.0), smooth((y - 100) / 824))
    let r2 = (x - center) * (x - center) + (y - center) * (y - center)
    c = mix(c, (0.72, 0.82, 1.0), 0.35 * exp(-r2 / (400 * 400) * 1.6))
    // The disc's shadow is blue, not grey: grey looks like dirt on a pale body.
    c = mix(c, (0.30, 0.36, 0.75), 0.42 * shadow(disc, x, y, drop: 24, blur: 56))

    let a = cover(disc(x, y))
    guard a > 0 else { return c }
    // The disc has a navy of its own under the bands, so its outline is whole where the widest band dips away from it.
    var inside = sheen((0.12, 0.12, 0.44), x, y, size: 320, 0.12)
    for (i, s) in bands.enumerated() {
        inside = mix(inside, scale(inside, 0.4), 0.5 * (1 - smooth((s(x, y + 10) + 12) / 30)))
        let tone = indigo(0.04 + 0.96 * Double(i) / Double(bands.count - 1))
        inside = mix(inside, glass(sheen(tone, x, y, size: 420, 0.2), s, x, y, rim: 7, light: 0.6), cover(s(x, y)))
    }
    return mix(c, glass(inside, disc, x, y, rim: 9, light: 0.9), a)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
let pixels = rep.bitmapData!
// One row per task: `swift` runs this without optimisation, about 5 s on one thread and 1.2 s across the cores.
DispatchQueue.concurrentPerform(iterations: side) { row in
    for column in 0..<side {
        let x = Double(column) + 0.5, y = Double(side - row) - 0.5
        let d = body(x, y), a = cover(d)
        var c: RGB = (0, 0, 0)
        if a > 0 {
            c = icon(x, y)
            // Tahoe-style lit edge on the body: brightest along the top, faint along the bottom.
            let t = (y - 100) / 824
            let lit = t > 0.5 ? 0.04 + 0.30 * smooth((t - 0.5) * 2) : 0.04 + 0.06 * smooth((0.5 - t) * 2)
            c = mix(c, white, 0.5 * lit * (1 - cover(d + 3)))
        }
        // The macOS drop shadow under the body.
        let alpha = a + (1 - a) * 0.3 * (1 - smooth((body(x, y + 12) + 14) / 44))
        let o = (row * side + column) * 4
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        pixels[o] = byte(c.r * a); pixels[o + 1] = byte(c.g * a); pixels[o + 2] = byte(c.b * a); pixels[o + 3] = byte(alpha)
    }
}
guard let png = rep.retagging(with: .sRGB)?.representation(using: .png, properties: [:])
else { fatalError("could not render the icon") }
try png.write(to: output)
