import SwiftUI

/// Canvas consumes only the compact analysis frame; no animation timeline or
/// access to the player/library forces unrelated views to redraw at 30 Hz.
struct VisualizerView: View {
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings
    @Environment(\.coverPalette) private var palette
    var circular = false

    var body: some View {
        let frame = visualization.frame
        let color = palette.highlight
        let sensitivity = Float(settings.sensitivity)
        let wave = settings.shape == .wave
        Canvas { context, size in
            if circular {
                drawCircle(context: &context, size: size, frame: frame, color: color,
                           sensitivity: sensitivity, wave: wave)
            } else if wave {
                var path = Path()
                for (i, sample) in frame.waveform.enumerated() {
                    let x = CGFloat(i) / CGFloat(max(1, frame.waveform.count - 1)) * size.width
                    let y = size.height / 2 + CGFloat(min(1, max(-1, sample * sensitivity))) * size.height * 0.4
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else {
                let step = size.width / CGFloat(frame.bands.count)
                var bars = Path()
                for (i, value) in frame.bands.enumerated() {
                    let height = max(2, CGFloat(min(1, value * sensitivity)) * (size.height - 6))
                    bars.addRoundedRect(in: CGRect(x: CGFloat(i) * step + 2, y: size.height - height,
                                                   width: max(1, step - 4), height: height), cornerSize: CGSize(width: 2, height: 2))
                }
                context.fill(bars, with: .linearGradient(Gradient(colors: [color.opacity(0.8), color.opacity(0.18)]),
                                                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawCircle(context: inout GraphicsContext, size: CGSize, frame: SpectrumFrame,
                            color: Color, sensitivity: Float, wave: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 27
        var path = Path()
        if wave {
            for i in 0...frame.waveform.count {
                let angle = Double(i) / Double(frame.waveform.count) * 2 * .pi - .pi / 2
                let sample = frame.waveform[i % frame.waveform.count]
                let r = radius + CGFloat(min(1, max(-1, sample * sensitivity))) * 18
                let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        } else {
            let count = frame.bands.count * 2
            for i in 0..<count {
                let index = i < frame.bands.count ? i : count - i - 1
                let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2
                let length = 2 + CGFloat(min(1, frame.bands[index] * sensitivity)) * 24
                path.move(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * (radius + length), y: center.y + sin(angle) * (radius + length)))
            }
        }
        context.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: wave ? 2 : 2.5, lineCap: .round, lineJoin: .round))
    }
}

struct VisualizerOptions: View {
    @Environment(VisualSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 16) {
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
                HStack {
                    Text("Sensitivity")
                    Slider(value: $settings.sensitivity, in: 0.25...3)
                    Text("\(Int(settings.sensitivity * 100))%")
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
            }.disabled(!settings.showVisualizer)
        }
    }
}

struct BackgroundOptions: View {
    @Environment(VisualizationModel.self) private var visualization
    @Environment(VisualSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Live background", isOn: $settings.liveBackground)
            HStack {
                Text("Reactivity")
                Slider(value: $settings.reactivity, in: 0...2)
            }.disabled(!settings.liveBackground)
            if settings.liveBackground, let error = visualization.backgroundFailure {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }
}

struct VisualControls: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Visuals").font(.system(size: 18, weight: .bold))
            VisualizerOptions()
            Divider()
            BackgroundOptions()
            Text("Motion stops when playback pauses or Floe is in the background. Reduce Motion keeps the effects still. Live backgrounds use extra energy.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(width: 340)
    }
}
