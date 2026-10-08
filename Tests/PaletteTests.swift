import AppKit
import CoreImage
import CoreText
import ImageIO
import Metal
import QuartzCore
import SwiftUI

/// Cover colour checks on synthetic covers: neutral covers stay neutral, dark
/// covers keep their real hue, nothing falls back to a colour the cover lacks.
/// FLOE_PALETTE_PREVIEWS=<dir> also writes a contact sheet of every cover with
/// its colours, accent, highlight and the real visualizer layer drawn in them;
/// FLOE_PALETTE_COVERS=<dir> adds real covers (any images) to it. See
/// scripts/test-palette.sh for comparing against an older extractor.
@main
@MainActor
struct PaletteTests {
    static var failures = 0

    static func main() {
        _ = NSApplication.shared
        var covers = Synthetic.all
        let real = ProcessInfo.processInfo.environment["FLOE_PALETTE_COVERS"].map(realCovers) ?? []
        for (name, image, expect) in covers { check(name, image, expect) }
        for (name, image, _) in real { check(name, image, .any) }
        shadeChecks()
        guard failures == 0 else { print("FAIL: \(failures) palette checks"); exit(1) }
        print("PASS: \(covers.count) synthetic and \(real.count) real covers (neutral stays neutral, dark keeps its hue, no invented green), shades, highlights")
        if let directory = ProcessInfo.processInfo.environment["FLOE_PALETTE_PREVIEWS"] {
            covers += real
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (page, start) in stride(from: 0, to: covers.count, by: 12).enumerated() {
                let rows = Array(covers[start..<min(start + 12, covers.count)])
                write(Sheet.render(rows.map { ($0.0, $0.1) }), to: url.appendingPathComponent("palette-\(page + 1).png"))
            }
            print("Wrote \(covers.count) covers to \(url.path)")
        }
    }

    // MARK: - Checks

    enum Expect {
        case neutral
        /// The accent's OKLCH hue lies in this range of degrees.
        case hue(ClosedRange<Double>)
        /// Soft: low chroma and light.
        case pastel
        /// At least this many distinct hue families among the colours.
        case varied(Int)
        case any
    }

    static func check(_ name: String, _ image: CGImage, _ expect: Expect) {
        guard let cover = CoverColorExtractor.colors(of: image) else { return fail("\(name): unreadable") }
        let accent = OKLab(cover.accent), colors = cover.colors.map(OKLab.init)
        expectTrue(colors.count == CoverColorExtractor.paletteSize, "\(name): the palette must fill every slot")
        let closest = colors.indices.flatMap { i in colors.indices.filter { $0 > i }.map { colors[i].distance(to: colors[$0]) } }.min() ?? 0
        expectTrue(closest > 0.03, "\(name): colours must be distinct (closest pair \(closest))")
        expectTrue(colors[0].distance(to: accent) < 0.25 && (accent.chroma < 0.03 || hueGap(colors[0], accent) < 12),
                   "\(name): the accent must lead the palette")
        expectTrue(colors.allSatisfy { $0.l >= 0.44 }, "\(name): every slot must be able to glow")
        let highlightRGB = CoverColorExtractor.highlight(of: cover.accent), highlight = OKLab(highlightRGB)
        // AA text contrast against the window's base colour.
        let onBase = (highlightRGB.luminance + 0.05) / (RGB(r: 0.045, g: 0.05, b: 0.06).luminance + 0.05)
        expectTrue(onBase >= 4.5, "\(name): the highlight must read on dark glass (contrast \(onBase))")
        expectTrue(accent.chroma < 0.03 || hueGap(highlight, accent) < 4, "\(name): the highlight must keep the accent's hue")
        let contrast = cover.accent.usesDarkText ? (cover.accent.luminance + 0.05) / 0.05 : 1.05 / (cover.accent.luminance + 0.05)
        expectTrue(contrast >= 4.5, "\(name): text on the accent must have contrast (\(contrast))")
        expectTrue(cover.accent != RGB(r: 0.12, g: 0.84, b: 0.38) && cover.accent != .fallback,
                   "\(name): a cover never falls back to a fixed accent")
        switch expect {
        case .neutral:
            expectTrue(cover.isNeutral && cover.source == nil, "\(name): must read as neutral")
            expectTrue(colors.allSatisfy { $0.chroma <= 0.03 }, "\(name): a neutral cover gets no saturated hue")
            expectTrue(accent.l >= 0.85, "\(name): a neutral accent is a light silver")
        case .hue(let range):
            let degrees = hueDegrees(accent)
            expectTrue(!cover.isNeutral && range.contains(degrees), "\(name): accent hue \(Int(degrees))° must be in \(range)")
            let family = colors.filter { $0.chroma > 0.04 }
            expectTrue(family.allSatisfy { hueGap($0, accent) < 30 }, "\(name): a one-colour cover's shades stay in its hue")
        case .pastel:
            expectTrue(!cover.isNeutral && accent.chroma < 0.12 && accent.l > 0.75, "\(name): a pastel cover stays soft")
        case .varied(let count):
            let families = Set(colors.filter { $0.chroma > 0.05 }.map { Int(hueDegrees($0) / 30) })
            expectTrue(families.count >= count, "\(name): a multicoloured cover must give \(count) hues, got \(families.count)")
        case .any:
            break
        }
        if case .hue(let range) = expect, range.overlaps(120...165) { return }
        if case .any = expect { return }
        // Green is fine when the cover has it; it must never appear from nowhere.
        expectTrue(colors.allSatisfy { $0.chroma < 0.05 || !(125...160).contains(hueDegrees($0)) },
                   "\(name): no green the cover doesn't have")
    }

    static func shadeChecks() {
        for name in ["green", "blue", "violet", "amber"] {
            let base = name == "blue" ? RGB.fallback : RGB(r: name == "green" ? 0.12 : name == "violet" ? 0.73 : 1,
                                                         g: name == "green" ? 0.84 : name == "violet" ? 0.5 : 0.7,
                                                         b: name == "green" ? 0.38 : name == "violet" ? 1 : 0.3)
            let shades = CoverColorExtractor.shades(of: base).map(OKLab.init)
            expectTrue(shades.count == CoverColorExtractor.paletteSize, "\(name): shades must fill every slot")
            expectTrue(shades.allSatisfy { hueGap($0, OKLab(base)) < 20 }, "\(name): shades must keep the hue")
            let closest = shades.indices.flatMap { i in shades.indices.filter { $0 > i }.map { shades[i].distance(to: shades[$0]) } }.min()!
            expectTrue(closest > 0.04, "\(name): shades must differ (closest pair \(closest))")
        }
        let grey = CoverColorExtractor.shades(of: RGB(r: 0.8, g: 0.8, b: 0.8)).map(OKLab.init)
        expectTrue(grey.allSatisfy { $0.chroma < 0.01 }, "grey shades stay grey")
        expectTrue(RGB.fallback.usesDarkText, "the default accent takes dark text")
    }

    static func hueDegrees(_ c: OKLab) -> Double {
        let degrees = c.hue * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    static func hueGap(_ x: OKLab, _ y: OKLab) -> Double {
        let gap = abs(hueDegrees(x) - hueDegrees(y)).truncatingRemainder(dividingBy: 360)
        return min(gap, 360 - gap)
    }

    static func expectTrue(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) {
        failures += 1
        print("  ✗ \(message)")
    }

    // MARK: - Covers

    /// Every image in a directory, decoded at the 96 px the app reads colours from.
    static func realCovers(_ path: String) -> [(String, CGImage, Expect)] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.sorted().compactMap { name in
            guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 96,
                  ] as CFDictionary) else { return nil }
            return ((name as NSString).deletingPathExtension, image, .any)
        }
    }

    static func write(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// Drawn covers for the cases that went wrong: black with type, black with a
/// little deep colour, greys, plus pastel, vivid and sepia for contrast.
enum Synthetic {
    static let all: [(String, CGImage, PaletteTests.Expect)] = [
        ("Black, white type", cover { ctx, s in
            fill(ctx, 0.02, 0.02, 0.02)
            text(ctx, "NOCTURNE", at: CGPoint(x: s * 0.14, y: s * 0.46), size: s * 0.13, color: (0.96, 0.96, 0.96))
            text(ctx, "the night sessions", at: CGPoint(x: s * 0.14, y: s * 0.38), size: s * 0.05, color: (0.7, 0.7, 0.7))
        }, .neutral),
        ("Black, deep red detail", cover { ctx, s in
            fill(ctx, 0.03, 0.02, 0.02)
            ctx.setFillColor(CGColor(srgbRed: 0.42, green: 0.03, blue: 0.05, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: s * 0.38, y: s * 0.4, width: s * 0.26, height: s * 0.26))
            text(ctx, "VELVET", at: CGPoint(x: s * 0.1, y: s * 0.1), size: s * 0.07, color: (0.9, 0.9, 0.9))
        }, .hue(0...45)),
        ("Black, tiny deep red", cover { ctx, s in
            fill(ctx, 0.02, 0.02, 0.02)
            ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.04, blue: 0.06, alpha: 1))
            ctx.fill(CGRect(x: s * 0.44, y: s * 0.44, width: s * 0.16, height: s * 0.16))
        }, .hue(0...45)),
        ("Grey photo, cool", cover { ctx, s in photo(ctx, s, cast: (-0.01, -0.012, 0.02), seed: 3) }, .neutral),
        ("B&W photo, warm", cover { ctx, s in photo(ctx, s, cast: (0.025, 0.012, -0.015), seed: 7) }, .neutral),
        ("White, black type", cover { ctx, s in
            fill(ctx, 0.95, 0.95, 0.94)
            text(ctx, "Minimal", at: CGPoint(x: s * 0.12, y: s * 0.12), size: s * 0.12, color: (0.05, 0.05, 0.05))
        }, .neutral),
        ("Dark navy", cover { ctx, s in
            gradient(ctx, s, top: (0.08, 0.12, 0.36), bottom: (0.01, 0.02, 0.07))
            text(ctx, "Deep Water", at: CGPoint(x: s * 0.1, y: s * 0.8), size: s * 0.07, color: (0.85, 0.87, 0.9))
        }, .hue(235...285)),
        // Its glow sits at the bottom of the usable range, where shades run out downward.
        ("Navy bands", cover { ctx, s in
            fill(ctx, 0.02, 0.03, 0.08)
            ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 1))
            ctx.fill(CGRect(x: 0, y: s / 4, width: s, height: s * 3 / 4))
        }, .hue(235...285)),
        ("Pastel", cover { ctx, s in
            fill(ctx, 0.98, 0.84, 0.88)
            ctx.setFillColor(CGColor(srgbRed: 0.78, green: 0.87, blue: 0.99, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: s * 0.4, y: s * 0.3, width: s * 0.7, height: s * 0.7))
            ctx.setFillColor(CGColor(srgbRed: 0.99, green: 0.94, blue: 0.8, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: -s * 0.1, y: -s * 0.1, width: s * 0.5, height: s * 0.5))
        }, .pastel),
        ("Vivid", cover { ctx, s in
            fill(ctx, 0.98, 0.45, 0.12)
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.35, blue: 0.95, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.4))
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.15, blue: 0.55, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: s * 0.25, y: s * 0.25, width: s * 0.5, height: s * 0.5))
            ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.88, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: s * 0.62, y: s * 0.62, width: s * 0.3, height: s * 0.3))
        }, .varied(3)),
        ("Sepia", cover { ctx, s in photo(ctx, s, cast: (0.09, 0.03, -0.07), seed: 11) }, .hue(25...100)),
        // As faint as real sepia prints and hazy covers: tinted, not neutral.
        ("Faint sepia", cover { ctx, s in photo(ctx, s, cast: (0.065, 0.016, -0.055), seed: 5) }, .hue(40...100)),
        ("Violet haze", cover { ctx, s in photo(ctx, s, cast: (0.025, -0.03, 0.06), seed: 9) }, .hue(275...330)),
        ("Black, neon green mark", cover { ctx, s in
            fill(ctx, 0.02, 0.02, 0.02)
            ctx.setFillColor(CGColor(srgbRed: 0.25, green: 1, blue: 0.35, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: s * 0.42, y: s * 0.42, width: s * 0.2, height: s * 0.2))
            text(ctx, "ACID", at: CGPoint(x: s * 0.08, y: s * 0.08), size: s * 0.08, color: (0.92, 0.92, 0.92))
        }, .hue(125...160)),
        ("Black, neon green speck", cover { ctx, s in
            fill(ctx, 0.02, 0.02, 0.02)
            ctx.setFillColor(CGColor(srgbRed: 0.25, green: 1, blue: 0.35, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: s * 0.86, y: s * 0.86, width: s * 0.05, height: s * 0.05))
            text(ctx, "ACID", at: CGPoint(x: s * 0.08, y: s * 0.08), size: s * 0.08, color: (0.92, 0.92, 0.92))
        }, .neutral),
        ("Dark forest", cover { ctx, s in
            gradient(ctx, s, top: (0.06, 0.22, 0.12), bottom: (0.01, 0.03, 0.02))
        }, .hue(125...175)),
        ("Black, brown", cover { ctx, s in
            fill(ctx, 0.02, 0.02, 0.02)
            ctx.setFillColor(CGColor(srgbRed: 0.33, green: 0.2, blue: 0.11, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.35))
        }, .hue(35...85)),
    ]

    static func cover(_ draw: (CGContext, CGFloat) -> Void) -> CGImage {
        let side = 192
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGFloat(side))
        return ctx.makeImage()!
    }

    static func fill(_ ctx: CGContext, _ r: Double, _ g: Double, _ b: Double) {
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    }

    static func gradient(_ ctx: CGContext, _ s: CGFloat, top: (Double, Double, Double), bottom: (Double, Double, Double)) {
        let colors = [CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1),
                      CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil)!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: .zero, options: [])
    }

    /// A soft photo-like field of greys, tinted by `cast` (added to every channel's grey).
    static func photo(_ ctx: CGContext, _ s: CGFloat, cast: (Double, Double, Double), seed: UInt64) {
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
        func grey(_ v: Double) -> CGColor {
            CGColor(srgbRed: min(1, max(0, v + cast.0 * v * 2)), green: min(1, max(0, v + cast.1 * v * 2)),
                    blue: min(1, max(0, v + cast.2 * v * 2)), alpha: 1)
        }
        ctx.setFillColor(grey(0.22)); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        for _ in 0..<40 {
            let r = s * (0.08 + random() * 0.3)
            ctx.setFillColor(grey(0.1 + random() * 0.75))
            ctx.fillEllipse(in: CGRect(x: random() * s - r / 2, y: random() * s - r / 2, width: r, height: r))
        }
    }

    static func text(_ ctx: CGContext, _ string: String, at point: CGPoint, size: CGFloat, color: (Double, Double, Double)) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font,
                          kCTForegroundColorAttributeName: CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}

/// One contact sheet: each cover beside its accent (as the Play pill), its
/// highlight (as a playing row's title), its five background colours and the
/// visualizer's bars and halo drawn by the real layer over the cover's backdrop.
@MainActor
enum Sheet {
    struct Look {
        var accent: RGB
        var highlight: RGB
        var colors: [RGB]
        var tints: (color: NSColor, pale: NSColor)
        var note: String
    }

    static func after(_ image: CGImage) -> Look {
        let cover = CoverColorExtractor.colors(of: image)!
        let highlight = CoverColorExtractor.highlight(of: cover.accent)
        return Look(accent: cover.accent, highlight: highlight, colors: cover.colors,
                    tints: VisualizerView.tints(Color(red: highlight.r, green: highlight.g, blue: highlight.b)),
                    note: cover.isNeutral ? "neutral" : "")
    }

    static var looks: [(String, (CGImage) -> Look)] {
        #if PALETTE_BEFORE
        [("before", before), ("after", after)]
        #else
        [("after", after)]
        #endif
    }

    static let rowHeight = 172.0, groupWidth = 660.0

    static func render(_ covers: [(String, CGImage)]) -> CGImage {
        let width = 150 + groupWidth * Double(looks.count), height = 28 + rowHeight * Double(covers.count)
        let ctx = CGContext(data: nil, width: Int(width) * 2, height: Int(height) * 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        // Top-down, like the app.
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (i, look) in looks.enumerated() {
            label(ctx, look.0.uppercased(), at: CGPoint(x: 150 + groupWidth * Double(i) + 8, y: 8), size: 12, color: .white)
        }
        for (row, (name, image)) in covers.enumerated() {
            let y = 28 + rowHeight * Double(row)
            draw(ctx, image, in: CGRect(x: 12, y: y + 4, width: 112, height: 112))
            label(ctx, String(name.prefix(22)), at: CGPoint(x: 12, y: y + 118), size: 9, color: CGColor(gray: 0.8, alpha: 1))
            for (i, look) in looks.enumerated() {
                group(ctx, look.1(image), cover: image, in: CGRect(x: 150 + groupWidth * Double(i), y: y, width: groupWidth - 8, height: rowHeight - 6))
            }
        }
        return ctx.makeImage()!
    }

    static func group(_ ctx: CGContext, _ look: Look, cover: CGImage, in frame: CGRect) {
        let backdrop = Backdrop.image(cover, accent: look.accent, size: frame.size)
        draw(ctx, backdrop, in: frame)
        let x = frame.minX + 12, y = frame.minY + 12
        // The Play pill: the accent with its chosen text colour.
        let pill = CGRect(x: x, y: y, width: 84, height: 30)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 15, cornerHeight: 15, transform: nil))
        ctx.setFillColor(look.accent.cgColor)
        ctx.fillPath()
        label(ctx, "▶ Play", at: CGPoint(x: x + 20, y: y + 9), size: 12,
              color: look.accent.usesDarkText ? .black : .white)
        // A playing row's title in the highlight beside a plain row in white.
        label(ctx, "Now playing", at: CGPoint(x: x, y: y + 44), size: 13, color: look.highlight.cgColor)
        label(ctx, "Next track", at: CGPoint(x: x, y: y + 62), size: 13, color: .white)
        label(ctx, look.note, at: CGPoint(x: x, y: y + 86), size: 10, color: CGColor(gray: 1, alpha: 0.6))
        // The live background's five colours.
        for (i, color) in look.colors.enumerated() {
            let swatch = CGRect(x: x + 100 + Double(i) * 32, y: y, width: 28, height: 28)
            ctx.setFillColor(color.cgColor)
            ctx.fill(swatch)
        }
        // Accent and highlight chips under the swatches.
        ctx.setFillColor(look.accent.cgColor)
        ctx.fill(CGRect(x: x + 100, y: y + 34, width: 60, height: 12))
        ctx.setFillColor(look.highlight.cgColor)
        ctx.fill(CGRect(x: x + 164, y: y + 34, width: 60, height: 12))
        let model = VisualizationModel()
        let levels = (0..<48).map { i -> Float in
            let x = Float(i) / 47
            return max(0.06, 0.92 - 0.75 * x + 0.18 * sin(x * 19) + 0.08 * cos(x * 41))
        }
        model.frame = SpectrumFrame(bands: levels, levels: levels, rms: 0.3)
        model.flow = 2.3
        for (style, top) in [(VisualizerLayerView.Style.bars, 54.0), (.beads, 112.0)] {
            let size = CGSize(width: 220, height: 52)
            let strip = Visualizer.render(style, look.tints, model: model, size: size,
                                          backdrop: Backdrop.image(cover, accent: look.accent, size: size))
            draw(ctx, strip, in: CGRect(x: x + 100, y: y + top, width: size.width, height: size.height))
        }
        for (style, left) in [(VisualizerLayerView.Style.halo, 330.0), (.radialBars, 482.0)] {
            let size = CGSize(width: 148, height: 148)
            let ring = Visualizer.render(style, look.tints, model: model, size: size,
                                         backdrop: Backdrop.image(cover, accent: look.accent, size: size))
            let ringFrame = CGRect(x: x + left, y: frame.minY + 6, width: size.width, height: size.height)
            draw(ctx, ring, in: ringFrame)
            draw(ctx, cover, in: ringFrame.insetBy(dx: size.width * (1 - 1 / VisualizerView.ringScale) / 2,
                                                   dy: size.height * (1 - 1 / VisualizerView.ringScale) / 2))
        }
    }

    /// Draws upright in the flipped context.
    static func draw(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func label(_ ctx: CGContext, _ string: String, at point: CGPoint, size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: point.x, y: point.y + size)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// The app's backdrop, approximated: the base, the cover blurred at 45%, the
/// accent's corner glow and a black veil.
@MainActor
enum Backdrop {
    static let context = CIContext(options: [.useSoftwareRenderer: true])

    static func image(_ cover: CGImage, accent: RGB, size: CGSize) -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.045, green: 0.05, blue: 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let input = CIImage(cgImage: cover)
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
        if let soft = context.createCGImage(blurred, from: input.extent) {
            ctx.setAlpha(0.45)
            let side = max(size.width, size.height)
            ctx.draw(soft, in: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side))
            ctx.setAlpha(1)
        }
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [accent.cgColor.copy(alpha: 0.22)!, accent.cgColor.copy(alpha: 0)!] as CFArray, locations: nil)!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 0, y: size.height), startRadius: 0,
                               endCenter: CGPoint(x: 0, y: size.height), endRadius: 700, options: [])
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.28))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

/// The real visualizer layer, rendered offscreen with CARenderer as in LayerTests.
@MainActor
enum Visualizer {
    final class TopDown: NSView {
        override var isFlipped: Bool { true }
    }

    static func render(_ style: VisualizerLayerView.Style, _ tints: (color: NSColor, pale: NSColor),
                       model: VisualizationModel, size: CGSize, backdrop: CGImage) -> CGImage {
        let view = VisualizerLayerView(model: model)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let parent = TopDown(frame: CGRect(origin: .zero, size: size))
        parent.wantsLayer = true
        window.contentView = parent
        view.frame = parent.bounds
        parent.addSubview(view)
        parent.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        view.configure(style: style, sensitivity: 1, color: tints.color, pale: tints.pale, running: false)
        view.layout()
        let root = CALayer()
        root.frame = parent.bounds
        root.isGeometryFlipped = parent.layer!.isGeometryFlipped
        root.contents = backdrop
        let layer = view.layer!
        layer.removeFromSuperlayer()
        layer.frame = root.bounds
        root.addSublayer(layer)

        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width),
                                                                  height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue])
        renderer.layer = root
        renderer.bounds = root.bounds
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let rowBytes = texture.width * 4
        let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared)!
        let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                  destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let data = Data(bytes: buffer.contents(), count: buffer.length)
        // The texture's first row is the layer's bottom; flip it so the image reads top-down.
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                     | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let flipped = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        flipped.translateBy(x: 0, y: CGFloat(image.height))
        flipped.scaleBy(x: 1, y: -1)
        flipped.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return flipped.makeImage()!
    }
}

extension RGB {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

#if PALETTE_BEFORE
extension Sheet {
    /// The older extractor (renamed by scripts/test-palette.sh) with the
    /// highlight and visualizer tints it shipped with.
    static func before(_ image: CGImage) -> Look {
        let found = LegacyExtractor.extract(of: image)
        let accent = found ?? .fallback
        let lift = accent.luminance < 0.2 ? 0.4 : 0.0
        let highlight = Color(red: accent.r + (1 - accent.r) * lift, green: accent.g + (1 - accent.g) * lift,
                              blue: accent.b + (1 - accent.b) * lift)
        let resolved = highlight.resolve(in: EnvironmentValues())
        return Look(accent: RGB(r: accent.r, g: accent.g, b: accent.b),
                    highlight: RGB(r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue)),
                    colors: LegacyExtractor.palette(of: image, accent: accent).map { RGB(r: $0.r, g: $0.g, b: $0.b) },
                    tints: (NSColor(highlight), NSColor(highlight.mix(with: .white, by: 0.55))),
                    note: found == nil ? "no colour found: fallback" : "")
    }
}
#endif
