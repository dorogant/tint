import SwiftUI

/// Scalloped "cookie" cover mask: round petals meeting in soft creases, plus a
/// slow three-lobe ripple whose position is set by `phase`; animating `phase`
/// makes the outline breathe. The petal tips touch the rect's inscribed circle.
struct BlobShape: Shape {
    var phase: Double
    var lobes = 22
    var depth = 0.045
    var ripple = 0.14

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2 / (1 + depth * (1 + ripple))
        // Rounds the |cos| crease so valleys stay soft at any size.
        let soft = 0.16, peak = (1 + soft * soft).squareRoot() - soft
        var path = Path()
        let steps = lobes * 16
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
