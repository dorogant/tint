// Floe's native icon: an icy flower over deep teal, with a small rhythm mark.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSGradient(colors: [NSColor(srgbRed: 0.025, green: 0.11, blue: 0.14, alpha: 1),
                        NSColor(srgbRed: 0.08, green: 0.32, blue: 0.32, alpha: 1)])!.draw(in: body, angle: 70)
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.15, green: 0.9, blue: 0.55, alpha: 0.3), .clear])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: 180, y: 250, width: 640, height: 640)), relativeCenterPosition: NSPoint(x: -0.2, y: 0.2))
    let flower = NSBezierPath()
    for i in 0..<360 {
        let a = Double(i) * 2 * .pi / 360
        let r = 265 + 30 * cos(6 * a + 0.5)
        let p = NSPoint(x: 512 + cos(a) * r, y: 530 + sin(a) * r)
        if i == 0 { flower.move(to: p) } else { flower.line(to: p) }
    }
    flower.close()
    NSGraphicsContext.current?.saveGraphicsState()
    let plateShadow = NSShadow()
    plateShadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
    plateShadow.shadowBlurRadius = 28
    plateShadow.shadowOffset = NSSize(width: 0, height: -20)
    plateShadow.set()
    NSGradient(colors: [NSColor(srgbRed: 0.49, green: 0.79, blue: 0.75, alpha: 1),
                        NSColor(srgbRed: 0.91, green: 1, blue: 0.97, alpha: 1)])!.draw(in: flower, angle: 80)
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.65).setStroke()
    flower.lineWidth = 6
    flower.stroke()
    NSColor(srgbRed: 0.055, green: 0.26, blue: 0.27, alpha: 1).setFill()
    for (x, h) in [(424.0, 104.0), (486.0, 178.0), (548.0, 138.0)] {
        NSBezierPath(roundedRect: NSRect(x: x, y: 530 - h / 2, width: 42, height: h), xRadius: 21, yRadius: 21).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    return true
}
guard let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
else { fatalError("could not render the icon") }
try png.write(to: output)
