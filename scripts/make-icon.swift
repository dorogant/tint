// Draws the placeholder app icon (1024×1024 PNG). Usage: swift make-icon.swift out.png
// A frosted "floe" on a deep teal squircle; replaced by a real icon in Phase 5.
import AppKit

let size = 1024.0
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: 824 pt body, ~185 pt corner radius, centred.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(srgbRed: 0.04, green: 0.13, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.33, blue: 0.38, alpha: 1),
    ])!.draw(in: squircle, angle: 70)

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    // Soft glow behind the floe, in the default green accent.
    NSGradient(colors: [
        NSColor(srgbRed: 0.11, green: 0.73, blue: 0.33, alpha: 0.55),
        NSColor(srgbRed: 0.11, green: 0.73, blue: 0.33, alpha: 0),
    ])!.draw(in: NSBezierPath(ovalIn: body.insetBy(dx: 90, dy: 90)), relativeCenterPosition: .zero)

    // The floe: an irregular rounded blob made of overlapping translucent discs.
    let discs: [(x: Double, y: Double, r: Double, a: Double)] = [
        (512, 520, 230, 0.80), (390, 600, 150, 0.55), (640, 610, 140, 0.55),
        (430, 420, 140, 0.50), (620, 430, 150, 0.50),
    ]
    for d in discs {
        NSColor(white: 1, alpha: d.a).setFill()
        NSBezierPath(ovalIn: NSRect(x: d.x - d.r, y: d.y - d.r, width: d.r * 2, height: d.r * 2)).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    return true
}

guard let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
else { fatalError("could not render the icon") }
try png.write(to: output)
