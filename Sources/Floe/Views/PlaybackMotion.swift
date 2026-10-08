import SwiftUI

/// Squashes slightly on press and springs back on release, optionally nudging
/// toward `nudge` (previous and next lean the way they go). The label owns its
/// hover look, so this stays usable for any shape.
struct TactileButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    var nudge = CGSize.zero
    @Environment(\.isEnabled) private var enabled
    @ReducedMotion private var still

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && enabled && !still
        configuration.label
            .scaleEffect(pressed ? pressedScale : 1)
            .offset(pressed ? nudge : .zero)
            .opacity(configuration.isPressed && enabled ? 0.88 : 1)
            .animation(still ? FloeMotion.fade : FloeMotion.press(configuration.isPressed), value: configuration.isPressed)
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
                .animation(still ? FloeMotion.fade : FloeMotion.enter),
            removal: AnyTransition(TrackChangeTransition(distance: distance, still: still))
                .animation(still ? FloeMotion.fade : FloeMotion.exit))
    }
}
