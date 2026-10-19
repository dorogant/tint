// Tint's icon: the app's 22-petal scalloped cover mask as a glass disc
// holding a wash of cover tints, on a dark glowing ground. No green and no
// sound arcs, so it never reads as Spotify's mark.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

typealias RGB = (r: Double, g: Double, b: Double)
func color(_ c: RGB, _ a: Double = 1) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a) }
func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t) }
func smooth(_ t: Double) -> Double { let x = max(0, min(1, t)); return x * x * (3 - 2 * x) }
/// Cyclic ramp through `stops`, t in 0..<1.
func ring(_ stops: [RGB], _ t: Double) -> RGB {
    let n = Double(stops.count), u = (t - floor(t)) * n
    let i = Int(u) % stops.count
    return mix(stops[i], stops[(i + 1) % stops.count], smooth(u - floor(u)))
}
/// Paints a per-pixel colour field (canvas coordinates, y up) into an image.
func field(_ rect: NSRect, _ f: (Double, Double) -> (RGB, Double)) -> NSImage {
    let w = Int(rect.width), h = Int(rect.height)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    let p = rep.bitmapData!
    for j in 0..<h {
        for i in 0..<w {
            let (c, a) = f(rect.minX + Double(i) + 0.5, rect.maxY - Double(j) - 0.5)
            let o = (j * w + i) * 4
            func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            p[o] = byte(c.r * a); p[o + 1] = byte(c.g * a); p[o + 2] = byte(c.b * a); p[o + 3] = byte(a)
        }
    }
    let image = NSImage(size: rect.size)
    image.addRepresentation(rep.retagging(with: .sRGB)!)
    return image
}

// Cover tints, warm to cool and back.
let tints: [RGB] = [(1.00, 0.36, 0.42), (1.00, 0.62, 0.30), (1.00, 0.83, 0.42), (0.36, 0.80, 0.96),
                    (0.33, 0.45, 1.00), (0.62, 0.38, 0.98), (0.93, 0.33, 0.72)]

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
let center = NSPoint(x: 512, y: 518)
let tipRadius = 268.0

func cookie(_ tip: Double) -> NSBezierPath {
    let lobes = 22.0, depth = 0.06, soft = 0.16, peak = (1 + soft * soft).squareRoot() - soft
    let base = tip / (1 + depth)
    let path = NSBezierPath()
    let steps = 22 * 24
    for i in 0..<steps {
        let theta = Double(i) / Double(steps) * 2 * .pi + .pi / 2
        let wave = cos(lobes / 2 * (theta - .pi / 2))
        let petal = ((wave * wave + soft * soft).squareRoot() - soft) / peak
        let r = base * (1 + depth * petal)
        let p = NSPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta))
        i == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.close()
    return path
}

let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let bodyRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: 185, yRadius: 185)
    let ctx = NSGraphicsContext.current!

    // Body with the macOS drop shadow.
    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSGradient(colors: [color((0.035, 0.035, 0.07)), color((0.09, 0.075, 0.15))])!.draw(in: body, angle: 90)
    ctx.restoreGraphicsState()

    ctx.saveGraphicsState()
    body.addClip()

    // Dark ground with cover-coloured glows bleeding from behind the disc.
    let glows: [(RGB, Double, Double, Double, Double)] = [
        (tints[6], 260, 300, 360, 0.5), (tints[4], 780, 760, 380, 0.55), (tints[5], 760, 240, 260, 0.3)]
    field(bodyRect) { x, y in
        var c = mix((0.03, 0.03, 0.065), (0.085, 0.07, 0.14), smooth((y - 100) / 824))
        for (g, gx, gy, r, a) in glows {
            let d2 = ((x - gx) * (x - gx) + (y - gy) * (y - gy)) / (r * r)
            c = mix(c, g, a * exp(-2.2 * d2))
        }
        return (c, 1)
    }.draw(in: bodyRect)

    let disc = cookie(tipRadius)

    // Soft contact shadow under the disc.
    ctx.saveGraphicsState()
    let discShadow = NSShadow()
    discShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    discShadow.shadowBlurRadius = 40
    discShadow.shadowOffset = NSSize(width: 0, height: -22)
    discShadow.set()
    NSColor.black.setFill()
    disc.fill()
    ctx.restoreGraphicsState()

    // The glass: a ring of tints, frosted toward a bright centre.
    ctx.saveGraphicsState()
    disc.addClip()
    let box = NSRect(x: center.x - tipRadius - 2, y: center.y - tipRadius - 2, width: tipRadius * 2 + 4, height: tipRadius * 2 + 4)
    // Mesh-like wash of cover tints, each anchored at a point inside the disc.
    let anchors: [(RGB, Double, Double)] = [
        (tints[0], -0.6, 0.35), (tints[1], -0.35, -0.6), (tints[2], 0.25, -0.8),
        (tints[6], 0.75, -0.15), (tints[5], 0.45, 0.65), (tints[4], -0.1, 0.9)]
    field(box) { x, y in
        let nx = (x - center.x) / tipRadius, ny = (y - center.y) / tipRadius
        let d = (nx * nx + ny * ny).squareRoot()
        var sum: RGB = (0, 0, 0), wsum = 0.0
        for (c, ax, ay) in anchors {
            let w = 1 / pow((nx - ax) * (nx - ax) + (ny - ay) * (ny - ay) + 0.12, 1.7)
            sum = (sum.r + c.r * w, sum.g + c.g * w, sum.b + c.b * w); wsum += w
        }
        var c: RGB = (sum.r / wsum, sum.g / wsum, sum.b / wsum)
        // Frosted bright core where the light passes straight through.
        let core = exp(-pow(d / 0.42, 2) * 1.0)
        c = mix(c, (1, 0.96, 0.94), 0.42 * core)
        // Diagonal sheen, brighter toward the upper left.
        let sheen = smooth((ny * 0.8 - nx * 0.6 + 0.15) / 1.3)
        c = mix(c, (1, 1, 1), 0.2 * sheen)
        // Thick-glass rim: denser colour, then a thin lit edge on the light side.
        let rimBand = smooth((d - 0.78) / 0.2)
        c = mix(c, (c.r * 0.8, c.g * 0.74, c.b * 0.88), rimBand * 0.55)
        let lightSide = max(0, (ny * 0.75 - nx * 0.66) / d)
        c = mix(c, (1, 1, 1), smooth((d - 0.86) / 0.1) * lightSide * 0.6)
        return (c, 1)
    }.draw(in: box)
    ctx.restoreGraphicsState()

    // Glass rim: bright where the light hits, faint opposite.
    ctx.saveGraphicsState()
    let cg = ctx.cgContext
    cg.addPath(disc.cgPath)
    cg.setLineWidth(10)
    cg.replacePathWithStrokedPath()
    cg.clip()
    disc.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.95), NSColor.white.withAlphaComponent(0.25),
                        NSColor.white.withAlphaComponent(0.55)])!.draw(in: box, angle: -50)
    ctx.restoreGraphicsState()

    // Tahoe-style lit edge on the body.
    let inner = NSBezierPath(roundedRect: bodyRect.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
    let edge = NSBezierPath()
    edge.append(body)
    edge.append(inner.reversed)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.34), NSColor.white.withAlphaComponent(0.04),
                        NSColor.white.withAlphaComponent(0.1)])!.draw(in: edge, angle: -90)
    ctx.restoreGraphicsState()
    return true
}
guard let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
else { fatalError("could not render the icon") }
try png.write(to: output)
