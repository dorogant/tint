import SwiftUI

/// Elapsed part as a sine wave (phase scrolls while playing), the rest as a flat line.
struct WavyProgress: View {
    var progress: Double
    var phase: Double
    var color: Color = .white
    var amplitude: CGFloat = 3.5
    var wavelength: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let split = size.width * progress
            var wave = Path()
            var x: CGFloat = 0
            wave.move(to: CGPoint(x: 0, y: mid))
            while x <= split {
                // Ease the amplitude in near the playhead so the wave meets the line smoothly.
                let fade = min(1, (split - x) / 12)
                let y = mid + sin(x / wavelength * 2 * .pi - phase) * amplitude * fade
                wave.addLine(to: CGPoint(x: x, y: y))
                x += 1.5
            }
            context.stroke(wave, with: .color(color), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            var rest = Path()
            rest.move(to: CGPoint(x: split + 6, y: mid))
            rest.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(rest, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            let knob = Path(roundedRect: CGRect(x: split - 2.5, y: mid - 9, width: 5, height: 18), cornerRadius: 2.5)
            context.fill(knob, with: .color(color))
        }
        .frame(height: 24)
    }
}

