import SwiftUI

/// Motion for the playback surfaces, on the same scale as `floeAnimation`:
/// hover arrives quickly and leaves a little slower, presses settle fast and
/// release with a small spring, and exits are quicker than entrances.
enum PlaybackMotion {
    static let hoverIn = Animation.spring(duration: 0.16, bounce: 0)
    static let hoverOut = Animation.spring(duration: 0.24, bounce: 0)
    static let pressDown = Animation.spring(duration: 0.14, bounce: 0)
    static let pressUp = Animation.spring(duration: 0.3, bounce: 0.15)
    /// Indicators and reveals that travel.
    static let glide = Animation.spring(duration: 0.4, bounce: 0.12)
    static let enter = Animation.spring(duration: 0.4, bounce: 0.1)
    static let exit = Animation.spring(duration: 0.22, bounce: 0)
    /// With Reduce Motion, colour and opacity still change, briefly.
    static let fade = Animation.easeOut(duration: 0.15)

    static func hover(_ hovering: Bool, still: Bool) -> Animation {
        still ? fade : (hovering ? hoverIn : hoverOut)
    }

    static func press(_ pressed: Bool, still: Bool) -> Animation {
        still ? fade : (pressed ? pressDown : pressUp)
    }

    /// True when the app's or the system's Reduce Motion is on. Callers keep
    /// scale and offset at rest then, and let colour and opacity fade.
    @propertyWrapper
    struct Still: DynamicProperty {
        @Environment(\.accessibilityReduceMotion) private var system
        @AppStorage("reduceMotion") private var app = false
        init() {}
        var wrappedValue: Bool { system || app }
    }
}

extension View {
    /// Springs hover in and eases it out; a short fade with Reduce Motion.
    func hoverMotion(_ hovering: Bool) -> some View {
        modifier(HoverMotion(hovering: hovering))
    }
}

private struct HoverMotion: ViewModifier {
    let hovering: Bool
    @PlaybackMotion.Still private var still

    func body(content: Content) -> some View {
        content.animation(PlaybackMotion.hover(hovering, still: still), value: hovering)
    }
}

/// Squashes slightly on press and springs back on release, optionally nudging
/// toward `nudge` (previous and next lean the way they go). The label owns its
/// hover look, so this stays usable for any shape.
struct TactileButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    var nudge = CGSize.zero
    @Environment(\.isEnabled) private var enabled
    @PlaybackMotion.Still private var still

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && enabled && !still
        configuration.label
            .scaleEffect(pressed ? pressedScale : 1)
            .offset(pressed ? nudge : .zero)
            .opacity(configuration.isPressed && enabled ? 0.88 : 1)
            .animation(PlaybackMotion.press(configuration.isPressed, still: still), value: configuration.isPressed)
    }
}

/// A new song's text rises into place while the old one lifts away. A slight
/// blur bridges the two, so they read as one change rather than two objects
/// crossing. Reduce Motion keeps only the crossfade.
struct TrackChangeTransition: Transition {
    var distance: CGFloat = 8
    var still = false

    func body(content: Content, phase: TransitionPhase) -> some View {
        let y: CGFloat = switch phase {
        case .willAppear: distance
        case .identity: 0
        case .didDisappear: -distance
        }
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(y: still ? 0 : y)
            .blur(radius: phase.isIdentity || still ? 0 : 2)
    }
}

extension AnyTransition {
    /// Enters on a gentle spring and leaves faster.
    static func trackChange(distance: CGFloat = 8, still: Bool) -> AnyTransition {
        .asymmetric(
            insertion: AnyTransition(TrackChangeTransition(distance: distance, still: still))
                .animation(still ? PlaybackMotion.fade : PlaybackMotion.enter),
            removal: AnyTransition(TrackChangeTransition(distance: distance, still: still))
                .animation(still ? PlaybackMotion.fade : PlaybackMotion.exit))
    }
}
