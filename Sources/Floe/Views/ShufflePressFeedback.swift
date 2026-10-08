import SwiftUI

/// A brief crossover kick and accent ripple, driven only by a local press.
/// The button keeps its fixed hit target and dispatches playback immediately.
struct ShufflePressFeedback: ViewModifier {
    let trigger: Int
    let enabled: Bool
    let diameter: CGFloat
    let tint: Color
    /// The ripple marks shuffle turning on; turning it off only kicks.
    var ripple = true

    private struct Frame {
        var rotation = 0.0
        var width: CGFloat = 1
        var height: CGFloat = 1
        var haloScale: CGFloat = 0.85
        var haloOpacity = 0.0
    }

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.keyframeAnimator(initialValue: Frame(), trigger: trigger) { symbol, frame in
                symbol
                    .scaleEffect(x: frame.width, y: frame.height)
                    .rotationEffect(.degrees(frame.rotation))
                    .overlay {
                        Circle()
                            .strokeBorder(tint, lineWidth: 1)
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(frame.haloScale)
                            .opacity(ripple ? frame.haloOpacity : 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            } keyframes: { _ in
                KeyframeTrack(\.rotation) {
                    CubicKeyframe(-24, duration: 0.08)
                    CubicKeyframe(20, duration: 0.13)
                    SpringKeyframe(0, duration: 0.31, spring: .snappy)
                }
                KeyframeTrack(\.width) {
                    CubicKeyframe(0.76, duration: 0.08)
                    SpringKeyframe(1.14, duration: 0.14, spring: .bouncy)
                    SpringKeyframe(1, duration: 0.30, spring: .smooth)
                }
                KeyframeTrack(\.height) {
                    CubicKeyframe(1.08, duration: 0.08)
                    SpringKeyframe(0.94, duration: 0.14, spring: .smooth)
                    SpringKeyframe(1, duration: 0.30, spring: .smooth)
                }
                KeyframeTrack(\.haloScale) {
                    LinearKeyframe(0.85, duration: 0)
                    CubicKeyframe(1.30, duration: 0.52)
                }
                KeyframeTrack(\.haloOpacity) {
                    LinearKeyframe(0.5, duration: 0.06)
                    CubicKeyframe(0, duration: 0.46)
                }
            }
        } else {
            // Switching Reduce Motion on also removes any in-flight transform.
            content
        }
    }
}
