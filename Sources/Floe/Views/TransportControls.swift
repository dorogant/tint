import SwiftUI

/// Shared transport for the mini player and Now Playing. Each button answers
/// the pointer by itself: a hover wash, a press that squashes (previous and
/// next lean the way they go), and a dot under shuffle and repeat while on.
struct TransportControls: View {
    var playSize: CGFloat = 42
    @Environment(PlayerModel.self) private var player

    private var large: Bool { playSize >= 50 }

    var body: some View {
        let icon: CGFloat = large ? 17 : 15
        HStack(spacing: large ? 10 : 4) {
            TransportButton(systemImage: "shuffle", size: icon - 1, active: player.shuffle, crossover: true,
                            label: "Shuffle") { player.toggleShuffle() }
            TransportButton(systemImage: "backward.fill", size: icon, nudge: -1, label: "Previous") { player.previous() }
            PlayPauseButton(size: playSize)
            TransportButton(systemImage: "forward.fill", size: icon, nudge: 1, label: "Next") { player.next() }
            TransportButton(systemImage: player.repeatMode == .track ? "repeat.1" : "repeat", size: icon - 1,
                            active: player.repeatMode != .off, label: "Repeat", value: repeatValue) {
                player.cycleRepeat()
            }
        }
    }

    private var repeatValue: LocalizedStringKey {
        switch player.repeatMode {
        case .off: "Repeat off"
        case .context: "Repeat all"
        case .track: "Repeat one"
        }
    }
}

/// A quiet round button. Previous and next nudge 3 pt their way on press; the
/// rest give a short symbol bounce, or shuffle's crossover kick.
private struct TransportButton: View {
    let systemImage: String
    let size: CGFloat
    /// -1 leans left on press, 1 leans right.
    var nudge: CGFloat = 0
    /// Shuffle and repeat show their state; nil for plain actions.
    var active: Bool?
    var crossover = false
    let label: LocalizedStringKey
    var value: LocalizedStringKey?
    let action: () -> Void
    @Environment(\.coverPalette) private var palette
    @ReducedMotion private var still
    @ViewState private var hovering = false
    @ViewState private var presses = 0

    var body: some View {
        let on = active == true
        let diameter = (size * 2.1).rounded()
        Button {
            presses += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.4), value: still || crossover || nudge != 0 ? 0 : presses)
                .foregroundStyle(on ? palette.highlight : (hovering ? .white : Theme.secondary))
                .modifier(ShufflePressFeedback(trigger: presses, enabled: crossover && !still,
                                               diameter: diameter, tint: palette.highlight, ripple: on))
                .frame(width: diameter, height: diameter)
                .background {
                    Circle().fill(Theme.hover)
                        .scaleEffect(hovering || still ? 1 : 0.95)
                        .opacity(hovering ? 1 : 0)
                }
                .overlay(alignment: .bottom) {
                    if active != nil {
                        // The "on" dot rises a couple of points into place.
                        Circle().fill(palette.highlight)
                            .frame(width: 4, height: 4)
                            .opacity(on ? 1 : 0)
                            .offset(y: on || still ? 0 : 2)
                            .padding(.bottom, diameter * 0.07)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(TactileButtonStyle(nudge: CGSize(width: nudge * 3, height: 0)))
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .animation(still ? FloeMotion.fade : FloeMotion.release, value: on)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(value.map { Text($0) } ?? Text(""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The accent disc: its symbol morphs between play and pause, a soft glow
/// gathers under the pointer, and a press squashes it slightly.
private struct PlayPauseButton: View {
    let size: CGFloat
    @Environment(PlayerModel.self) private var player
    @Environment(\.coverPalette) private var palette
    @ReducedMotion private var still
    @ViewState private var hovering = false

    var body: some View {
        let busy = player.isPlaying || player.isLoading
        Button(action: player.togglePlayPause) {
            Group {
                if player.isLoading {
                    ProgressView().controlSize(.small).tint(palette.onAccent)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        // The triangle's weight sits left of its box; centre it by eye.
                        .offset(x: player.isPlaying ? 0 : size * 0.03)
                }
            }
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(palette.onAccent)
            .frame(width: size, height: size)
            .glassControl(tint: palette.accent, in: .circle)
            .contentShape(Circle())
        }
        .buttonStyle(PlayButtonStyle(hovering: hovering))
        .background {
            Circle()
                .fill(RadialGradient(colors: [palette.accent.opacity(0.5), palette.accent.opacity(0)], center: .center,
                                     startRadius: size * 0.35, endRadius: size * 0.85))
                .frame(width: size * 1.7, height: size * 1.7)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .help(busy ? "Pause" : "Play")
        .accessibilityLabel(busy ? "Pause" : "Play")
    }
}

/// Lifts 3% under the pointer; a press squashes it a little more vertically
/// than horizontally, like a soft key, then springs back.
private struct PlayButtonStyle: ButtonStyle {
    let hovering: Bool
    @ReducedMotion private var still

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let rest: CGFloat = hovering ? 1.03 : 1
        configuration.label
            .scaleEffect(x: still ? 1 : (pressed ? 0.975 : rest), y: still ? 1 : (pressed ? 0.95 : rest))
            .brightness(pressed ? -0.05 : 0)
            .animation(still ? FloeMotion.fade : FloeMotion.press(pressed), value: pressed)
    }
}
