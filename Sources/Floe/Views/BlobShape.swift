import SwiftUI

/// A soft flower/blob: radius modulated by two slow sine terms; `phase` animates it.
struct BlobShape: Shape {
    var phase: Double
    var lobes = 6
    var depth = 0.06

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2 / (1 + depth * 1.6)
        var path = Path()
        let steps = 180
        for i in 0...steps {
            let theta = Double(i) / Double(steps) * 2 * .pi
            let r = base * (1
                + depth * sin(Double(lobes) * theta + phase)
                + depth * 0.6 * sin(Double(lobes - 2) * theta - phase * 1.3 + 1.7))
            let point = CGPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta))
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

