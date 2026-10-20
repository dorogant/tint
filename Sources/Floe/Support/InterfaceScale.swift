import SwiftUI

/// The main window's sizes at the chosen `InterfaceSize`. Size literals in the
/// views are Compact points, the original layout, and pass through here, so
/// Compact reproduces it exactly. Type, spacing and artwork grow instead of
/// the window being magnified: `scaleEffect` would blur text and leave hit
/// areas behind. Read once per body, like any environment value.
struct InterfaceScale: Equatable, Sendable {
    let factor: CGFloat
    // The guides every page shares, on one spacing scale in multiples of 4 at
    // Compact, and rounded to the grid rather than multiplied at other sizes.

    /// Window margin and the gap between panels. Panels round to `corner`, so
    /// they stay concentric with the window's own corners.
    let margin: CGFloat
    /// From a page panel's edge to its content: titles, section headers,
    /// covers, card artwork and list columns all start on this line.
    let gutter: CGFloat
    /// How far a hover or selection plate reaches past what it holds. Plates
    /// round to their content's radius plus this, so the corners nest.
    let plate: CGFloat
    /// Between the sections of a page.
    let sectionGap: CGFloat
    /// From a section header to its content.
    let headerGap: CGFloat
    let corner: CGFloat

    /// The original layout.
    static let compact = Self(factor: 1, margin: 8, gutter: 28, plate: 8, sectionGap: 32, headerGap: 12, corner: 18)
    /// Text that was 12.5 pt reads 14.
    static let standard = Self(factor: 1.12, margin: 9, gutter: 32, plate: 9, sectionGap: 36, headerGap: 14, corner: 20)
    static let large = Self(factor: 1.25, margin: 10, gutter: 36, plate: 10, sectionGap: 40, headerGap: 15, corner: 22)

    /// A Compact length at this size, in whole points so edges stay sharp.
    func callAsFunction(_ points: CGFloat) -> CGFloat {
        factor == 1 ? points : (points * factor).rounded()
    }

    /// A Compact type size at this size, in half points.
    func text(_ size: CGFloat) -> CGFloat {
        factor == 1 ? size : (size * factor * 2).rounded() / 2
    }

    /// `Font.system(size:weight:design:)` with a Compact size.
    func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: text(size), weight: weight, design: design)
    }
}

private struct InterfaceScaleKey: EnvironmentKey {
    static let defaultValue = InterfaceScale.compact
}
extension EnvironmentValues {
    /// Set once at the root from Settings > Appearance.
    var interfaceScale: InterfaceScale {
        get { self[InterfaceScaleKey.self] }
        set { self[InterfaceScaleKey.self] = newValue }
    }
}

extension View {
    /// `.font(.system(size:weight:design:))` with a Compact size, drawn at the interface size.
    func floeFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

private struct ScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content.font(scale.font(size: size, weight: weight, design: design))
    }
}
