import SwiftUI

/// Short, event-driven motion; hover and navigation never start their own timer.
private struct FloeAnimation<Value: Equatable>: ViewModifier {
    let value: Value
    var duration: Double
    var bounce: Double
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false

    func body(content: Content) -> some View {
        content.animation(reduceMotion || systemReduceMotion ? nil : .spring(duration: duration, bounce: bounce),
                          value: value)
    }
}

extension View {
    /// A spring that settles in `duration`; a little `bounce` suits larger moves.
    func floeAnimation<Value: Equatable>(value: Value, duration: Double = 0.24, bounce: Double = 0) -> some View {
        modifier(FloeAnimation(value: value, duration: duration, bounce: bounce))
    }

    /// The playing cover flies between the mini player and Now Playing.
    func heroCover() -> some View { modifier(HeroCover()) }
}

private struct HeroNamespaceKey: EnvironmentKey {
    static var defaultValue: Namespace.ID? { nil }
}

extension EnvironmentValues {
    var heroNamespace: Namespace.ID? {
        get { self[HeroNamespaceKey.self] }
        set { self[HeroNamespaceKey.self] = newValue }
    }
}

private struct HeroCover: ViewModifier {
    @Environment(\.heroNamespace) private var namespace
    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: "cover", in: namespace) } else { content }
    }
}

/// Library sits underneath: Now Playing and Lyrics rise over it like a sheet,
/// and the library recedes and softens while they're up.
struct SurfaceTransition: Transition {
    var raised: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(phase.isIdentity ? 1 : (raised ? 0.97 : 0.95))
            .offset(y: phase.isIdentity || !raised ? 0 : 40)
            .blur(radius: phase.isIdentity || raised ? 0 : 10)
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

/// A fixed-rate clock that pauses cleanly: paused, it emits a single entry.
/// Each tick is a SwiftUI update of the whole window, so keep it slow; for
/// continuous motion, use Core Animation (see `CrawlingCover`, `WavyProgress`).
struct SteadySchedule: TimelineSchedule {
    var interval: TimeInterval
    var paused = false

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if paused { return AnyIterator([startDate].makeIterator()) }
        var next = startDate
        let interval = interval
        return AnyIterator {
            defer { next += interval }
            return next
        }
    }
}
