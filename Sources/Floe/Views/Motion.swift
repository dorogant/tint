import SwiftUI

/// Short, event-driven motion; hover and navigation never start their own timer.
private struct FloeAnimation<Value: Equatable>: ViewModifier {
    let value: Value
    var duration: Double
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false

    func body(content: Content) -> some View {
        content.animation(reduceMotion || systemReduceMotion ? nil : .smooth(duration: duration), value: value)
    }
}

extension View {
    func floeAnimation<Value: Equatable>(value: Value, duration: Double = 0.24) -> some View {
        modifier(FloeAnimation(value: value, duration: duration))
    }
}

struct FloeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let still = reduceMotion || systemReduceMotion
        configuration.label
            .scaleEffect(still || !enabled ? 1 : (configuration.isPressed ? 0.96 : (hovering ? 1.015 : 1)))
            .brightness(enabled && hovering ? 0.035 : 0)
            .opacity(configuration.isPressed && enabled ? 0.86 : 1)
            .onHover { hovering = $0 }
            .floeAnimation(value: configuration.isPressed, duration: 0.16)
            .floeAnimation(value: hovering, duration: 0.18)
    }
}

extension ButtonStyle where Self == FloeButtonStyle {
    static var floe: FloeButtonStyle { FloeButtonStyle() }
}
