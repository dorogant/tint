import SwiftUI

/// Canvas consumes only the compact analysis frame; no animation timeline or
/// access to the player/library forces unrelated views to redraw at 30 Hz.
/// Every style shares one look: rounded strokes, pale at the top and saturated
/// at the bottom, with a faint glow underneath.
struct VisualizerView: View {
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings
    @Environment(\.coverPalette) private var palette
    var circular = false

    /// The circular ring reaches this multiple of the cover's radius.
    static let ringScale: CGFloat = 1.5

    var body: some View {
        let frame = visualization.frame
        let color = palette.highlight
        let pale = color.mix(with: .white, by: 0.55)
        let sensitivity = Float(settings.sensitivity)
        let wave = settings.shape == .wave
        Canvas { context, size in
            let levels = frame.bands.map { response($0, sensitivity: sensitivity) }
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [pale.opacity(0.75), color.opacity(0.95)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            switch (circular, wave) {
            case (true, false): drawRadialBars(&context, size: size, levels: levels, color: color, shading: shading)
            case (true, true): drawHalo(&context, size: size, levels: levels, color: color, shading: shading)
            case (false, false): drawBars(&context, size: size, levels: levels, color: color, shading: shading)
            case (false, true):
                let ribbon = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [color.opacity(0.95), pale.opacity(0.7), color.opacity(0.95)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
                drawRibbon(&context, size: size, levels: levels, color: color, shading: ribbon)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Mirrored radial bars around the cover: bass at the top, treble at the bottom.
    private func drawRadialBars(_ context: inout GraphicsContext, size: CGSize, levels: [CGFloat],
                                color: Color, shading: GraphicsContext.Shading) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2
        let count = levels.count * 2
        let inner = outer / Self.ringScale + 3
        let width = max(1.5, 2 * .pi * inner / CGFloat(count) * 0.5)
        // Round caps stay clear of the cover outline and the canvas edge.
        let start = inner + width / 2
        let room = outer - start - width / 2
        var path = Path()
        for i in 0..<count {
            let level = levels[i < levels.count ? i : count - i - 1]
            let angle = (Double(i) + 0.5) / Double(count) * 2 * .pi - .pi / 2
            let length = room * (0.05 + 0.95 * level)
            path.move(to: point(center, angle, start))
            path.addLine(to: point(center, angle, start + length))
        }
        context.stroke(path, with: .color(color.opacity(0.14)), style: StrokeStyle(lineWidth: width * 2.2, lineCap: .round))
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// A soft filled halo whose few broad lobes follow the spectrum.
    private func drawHalo(_ context: inout GraphicsContext, size: CGSize, levels: [CGFloat],
                          color: Color, shading: GraphicsContext.Shading) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2
        let cover = outer / Self.ringScale
        let room = outer - cover - 4
        let lobes = emphasized(smoothed(levels, groups: 12))
        let half = Double(lobes.count)
        // Right side runs top to bottom; the left side mirrors it back up.
        let right = lobes.enumerated().map { g, level in
            (angle: -.pi / 2 + (Double(g) + 0.5) / half * .pi, radius: cover + room * (0.22 + 0.78 * level))
        }
        let points = (right + right.reversed().map { (angle: .pi - $0.angle, radius: $0.radius) })
            .map { point(center, $0.angle, $0.radius) }
        var path = Path()
        addCurve(through: points, to: &path, closed: true)
        context.stroke(path, with: .color(color.opacity(0.12)), style: StrokeStyle(lineWidth: 10, lineJoin: .round))
        context.fill(path, with: shading)
        context.stroke(path, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    /// The ring unrolled: bass in the middle, mirrored out to treble at both ends.
    private func drawBars(_ context: inout GraphicsContext, size: CGSize, levels: [CGFloat],
                          color: Color, shading: GraphicsContext.Shading) {
        let mirrored = levels.reversed() + levels
        let step = size.width / CGFloat(mirrored.count)
        let width = max(2, step * 0.5)
        let bottom = size.height - width / 2
        var path = Path()
        for (i, level) in mirrored.enumerated() {
            let x = (CGFloat(i) + 0.5) * step
            path.move(to: CGPoint(x: x, y: bottom))
            path.addLine(to: CGPoint(x: x, y: bottom - (size.height - width) * (0.04 + 0.96 * level)))
        }
        context.stroke(path, with: .color(color.opacity(0.1)), style: StrokeStyle(lineWidth: width * 1.8, lineCap: .round))
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// The halo unrolled: a ribbon around the centre line, bass in the middle,
    /// tapered at both ends.
    private func drawRibbon(_ context: inout GraphicsContext, size: CGSize, levels: [CGFloat],
                            color: Color, shading: GraphicsContext.Shading) {
        let mid = size.height / 2
        let half = emphasized(smoothed(levels, groups: 14))
        let lobes = half.reversed() + half
        let top = [CGPoint(x: 0, y: mid)]
            + lobes.enumerated().map { g, level in
                CGPoint(x: (CGFloat(g) + 0.5) / CGFloat(lobes.count) * size.width,
                        y: mid - (mid - 3) * (0.06 + 0.94 * level))
            }
            + [CGPoint(x: size.width, y: mid)]
        var path = Path()
        addCurve(through: top, to: &path, closed: false)
        addCurve(through: top.reversed().map { CGPoint(x: $0.x, y: 2 * mid - $0.y) }, to: &path, closed: false)
        path.closeSubpath()
        context.stroke(path, with: .color(color.opacity(0.12)), style: StrokeStyle(lineWidth: 8, lineJoin: .round))
        context.fill(path, with: shading)
    }

    /// Most music sits in the upper half of the analyser's dB range, so a knee drops
    /// the quiet floor and stretches what's left; a soft top keeps loud bands distinct.
    private func response(_ value: Float, sensitivity: Float) -> CGFloat {
        let x = max(0, value * sensitivity - 0.3) / 0.7
        return CGFloat(min(1, (1 - exp(-x * 1.4)) / (1 - exp(-1.4))))
    }

    /// Averages neighbouring bands, then blurs once more so outlines get a few broad lobes.
    private func smoothed(_ levels: [CGFloat], groups: Int) -> [CGFloat] {
        let averaged = (0..<groups).map { g in
            let range = (g * levels.count / groups)..<((g + 1) * levels.count / groups)
            return levels[range].reduce(0, +) / CGFloat(max(1, range.count))
        }
        return averaged.indices.map { i in
            (averaged[max(0, i - 1)] + 2 * averaged[i] + averaged[min(groups - 1, i + 1)]) / 4
        }
    }

    /// Smoothing flattens the outline, so stretch each lobe away from the mean:
    /// the shape follows the spectrum while its overall size follows loudness.
    private func emphasized(_ values: [CGFloat], by factor: CGFloat = 2.2) -> [CGFloat] {
        let mean = values.reduce(0, +) / CGFloat(max(1, values.count))
        return values.map { min(1, max(0, mean + ($0 - mean) * factor)) }
    }

    private func point(_ center: CGPoint, _ angle: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    /// Catmull-Rom through every point, so peaks stay where the data puts them.
    /// Continues an existing path from its current point, or starts a new one.
    private func addCurve(through points: [CGPoint], to path: inout Path, closed: Bool) {
        guard points.count > 1 else { return }
        if path.isEmpty { path.move(to: points[0]) } else { path.addLine(to: points[0]) }
        func point(_ index: Int) -> CGPoint {
            points[closed ? (index + points.count) % points.count : min(points.count - 1, max(0, index))]
        }
        for i in 0..<(closed ? points.count : points.count - 1) {
            let p0 = point(i - 1), p1 = point(i), p2 = point(i + 1), p3 = point(i + 2)
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed { path.closeSubpath() }
    }
}

/// Rows only, so the same controls sit in the Visuals popover and in a Settings `Form`.
struct VisualizerOptions: View {
    @Environment(VisualSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        Toggle("Show visualizer", isOn: $settings.showVisualizer)
        Group {
            Picker("Style", selection: $settings.style) {
                Text("Normal").tag(VisualSettings.Style.normal)
                Text("Circular").tag(VisualSettings.Style.circular)
            }.pickerStyle(.segmented)
            Picker("Shape", selection: $settings.shape) {
                Text("Bars").tag(VisualSettings.Shape.bars)
                Text("Wave").tag(VisualSettings.Shape.wave)
            }.pickerStyle(.segmented)
            LabeledContent("Sensitivity") {
                HStack {
                    Slider(value: $settings.sensitivity, in: 0.25...3).labelsHidden()
                    Text("\(Int(settings.sensitivity * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                }
            }
        }.disabled(!settings.showVisualizer)
    }
}

struct BackgroundOptions: View {
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        Toggle("Live background", isOn: $settings.liveBackground)
        LabeledContent("Reactivity") {
            Slider(value: $settings.reactivity, in: 0...2).labelsHidden()
        }.disabled(!settings.liveBackground)
        if settings.liveBackground, let error = visualization.backgroundFailure {
            Text(error).font(.callout).foregroundStyle(.orange)
        }
    }
}

struct VisualControls: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Visuals").font(.title3.bold())
            VisualizerOptions()
            Divider()
            BackgroundOptions()
            Text("Motion stops when playback pauses or Floe is in the background. Reduce Motion keeps the effects still. Live backgrounds use extra energy.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 340)
    }
}
