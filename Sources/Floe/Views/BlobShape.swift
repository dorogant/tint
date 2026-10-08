import SwiftUI

/// Scalloped "cookie" cover mask: round petals meeting in soft creases, plus a
/// slow three-lobe ripple driven by `phase` so the outline breathes while playing.
/// The petal tips touch the rect's inscribed circle.
struct BlobShape: Shape {
    var phase: Double
    var lobes = 22
    var depth = 0.045

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ripple = 0.14
        let base = min(rect.width, rect.height) / 2 / (1 + depth * (1 + ripple))
        // Rounds the |cos| crease so valleys stay soft at any size.
        let soft = 0.16, peak = (1 + soft * soft).squareRoot() - soft
        var path = Path()
        let steps = lobes * 24
        for i in 0...steps {
            let theta = Double(i) / Double(steps) * 2 * .pi
            let wave = cos(Double(lobes) / 2 * theta)
            let petal = ((wave * wave + soft * soft).squareRoot() - soft) / peak
            let r = base * (1 + depth * (petal + ripple * sin(3 * theta + phase)))
            let point = CGPoint(x: center.x + r * cos(theta), y: center.y + r * sin(theta))
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
