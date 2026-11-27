import SwiftUI

struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(VisualSettings.self) private var settings
    @Environment(Navigator.self) private var navigator
    @ReducedMotion private var still
    @AppStorage("nowPlayingLyrics") private var showLyrics = true
    @Environment(\.interfaceScale) private var scale
    @ViewState private var ringShown = false

    var body: some View {
        if let track = player.displayTrack {
            GeometryReader { geometry in
                // The card stands on its reflection, so a ring can't go round it:
                // its visualizer is always the strip along the bottom.
                let card = settings.cover == .card
                let circular = settings.showVisualizer && settings.style == .circular && !card
                let normal = settings.showVisualizer && (settings.style == .normal || card)
                let compact = geometry.size.height < scale(600)
                // With the controls put away the cover takes their room and may grow.
                let clean = navigator.controlsHidden
                // Reserve room for a wrapped title, transport and optional bottom strip;
                // the circular ring scales with the cover, as in the reference.
                let controlsHeight = scale(compact ? 310 : 390) - (clean ? scale(compact ? 130 : 150) : 0)
                let ring = circular ? VisualizerView.ringScale : 1
                let foot = card ? FloatingCover.foot : 0
                let available = (geometry.size.height - controlsHeight - (normal ? scale(96) : 0)) / (ring + foot)
                let lyricsWidth = showLyrics ? max(scale(330), geometry.size.width * 0.42) : 0
                let columnWidth = geometry.size.width - 2 * scale.margin - lyricsWidth - (showLyrics ? scale(20) : 0)
                let coverWidth = (columnWidth - scale(compact ? 24 : 40)) / ring
                let largest: CGFloat = showLyrics ? (clean ? 400 : 330) : (clean ? 520 : 420)
                let coverSize = min(scale(largest), max(scale(100), min(available, coverWidth)))
                VStack(spacing: scale(12)) {
                    HStack(spacing: scale(20)) {
                        // Cover, words, then controls: the wider gaps separate the
                        // groups and the narrower ones hold each group together.
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            CoverStage(size: coverSize, ring: ring, card: card) {
                                if circular { VisualizerView(circular: true).opacity(ringShown ? 1 : 0).transition(.opacity) }
                            }
                            // A new song's details rise into place as the old ones lift away.
                            ZStack {
                                TrackTitle(track: track, compact: compact)
                                    .id(track.uri)
                                    .transition(.trackChange(distance: 14, still: still))
                            }
                            .animation(still ? FloeMotion.fade : FloeMotion.enter, value: track.uri)
                            .padding(.top, scale(compact ? 14 : 26))
                            if !clean {
                                VStack(spacing: scale(compact ? 4 : 8)) {
                                    ProgressBar(large: true).frame(maxWidth: scale(480))
                                    TransportControls(playSize: 58)
                                    VolumeControl().padding(.top, scale(compact ? 2 : 4))
                                }
                                .padding(.top, scale(compact ? 10 : 18))
                                .transition(still ? .opacity : .opacity.combined(with: .offset(y: 12)))
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(scale(compact ? 12 : 20))
                        if showLyrics {
                            LyricsView().frame(width: lyricsWidth)
                                .background {
                                    RoundedRectangle(cornerRadius: scale.corner - scale.margin, style: .continuous)
                                        .fill(.black.opacity(0.08)).opacity(clean ? 0 : 1)
                                }
                                .transition(lyricsTransition)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    if normal {
                        VisualizerView().frame(height: scale(84)).padding(.horizontal, scale(24))
                            .transition(still ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(scale.margin)
                .animation(still ? nil : FloeMotion.enter, value: showLyrics)
                .animation(still ? FloeMotion.fade : FloeMotion.enter, value: clean)
                // Turning the visualizer on or off, or changing its style, eases
                // the strip, the ring and the cover's new size into place.
                .animation(still ? FloeMotion.fade : FloeMotion.enter, value: settings.showVisualizer)
                .animation(still ? FloeMotion.fade : FloeMotion.enter, value: settings.style)
                .animation(still ? FloeMotion.fade : FloeMotion.enter, value: settings.cover)
            }
            .overlay(alignment: .topTrailing) {
                // Both stay mounted while the controls are away, so ⇧⌘H and ⇧⌘L still work.
                HStack(spacing: scale(8)) {
                    ControlsToggle(hidden: false, shortcut: KeyboardShortcut("h", modifiers: [.command, .shift])) {
                        navigator.controlsHidden.toggle()
                    }
                    LyricsToggle(on: $showLyrics)
                }
                .padding(2 * scale.margin)
                .opacity(navigator.controlsHidden ? 0 : 1)
                .allowsHitTesting(!navigator.controlsHidden)
                .accessibilityHidden(navigator.controlsHidden)
                .animation(FloeMotion.fade, value: navigator.controlsHidden)
            }
            .onAppear {
                // The ring fades in once the cover has flown into place.
                withAnimation(still ? nil : .easeOut(duration: 0.4).delay(0.35)) {
                    ringShown = true
                }
            }
        } else {
            MessageView(systemImage: "music.note", message: L10n.string("Pick something to play"))
                .frame(maxHeight: .infinity)
        }
    }

    /// The column slides in 40 pt from the right, softened by a little blur,
    /// and leaves faster than it came. Reduce Motion keeps the crossfade.
    private var lyricsTransition: AnyTransition {
        let moved = AnyTransition.opacity.combined(with: .offset(x: 40))
            .combined(with: .modifier(active: Soften(radius: 4), identity: Soften(radius: 0)))
        return still ? AnyTransition.opacity.animation(FloeMotion.fade)
            : .asymmetric(insertion: moved.animation(FloeMotion.enter),
                          removal: moved.animation(.spring(duration: 0.26, bounce: 0)))
    }
}

private struct Soften: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

/// The cover and its ring lift together under the pointer: 2% larger, with
/// the shadow beneath deepening and dropping. Only the SwiftUI container
/// scales; the Core Animation layers inside keep running untouched. With
/// Reduce Motion only the shadow darkens.
private struct CoverStage<Ring: View>: View {
    let size: CGFloat
    let ring: CGFloat
    let card: Bool
    @ViewBuilder var ringView: Ring
    @ReducedMotion private var still
    @ViewState private var hovering = false

    var body: some View {
        let lifted = hovering && !still
        // The card's reflection hangs below the square the cover stands in.
        let foot = card ? size * FloatingCover.foot : 0
        ZStack {
            RadialGradient(colors: [.black.opacity(0.5), .black.opacity(0)], center: .center,
                           startRadius: 0, endRadius: size * 0.52)
                .frame(width: size * 1.05, height: size * 0.92)
                .clipShape(Ellipse())
                .offset(y: size * (lifted ? 0.1 : 0.06) - foot / 2)
                .opacity(hovering ? 1 : 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ringView
            CoverView(size: size, card: card)
                .contentShape(card ? AnyShape(Rectangle()) : AnyShape(Circle()))
                .onHover { hovering = $0 }
        }
        .frame(width: size * ring, height: size * ring + foot)
        .scaleEffect(lifted ? 1.02 : 1)
        .floeHover(hovering)
    }
}

/// Title, artists and album. The artists take a tint from the cover and, like
/// the album, open their page; the title stays white so it reads first.
private struct TrackTitle: View {
    let track: TrackInfo
    let compact: Bool
    @Environment(\.coverPalette) private var palette
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        // The star's room is kept on both sides, so the title stays centred.
        let star = scale(compact ? 30 : 34)
        VStack(spacing: 0) {
            Text(track.name)
                .floeFont(size: compact ? 24 : 28, weight: .bold)
                .tracking(compact ? -0.2 : -0.35)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, star + scale(4))
                .overlay(alignment: .trailing) {
                    LikeButton(uri: track.uri, size: compact ? 16 : 18, side: compact ? 30 : 34)
                        .opacity(navigator.controlsHidden ? 0 : 1)
                        .allowsHitTesting(!navigator.controlsHidden)
                        .accessibilityHidden(navigator.controlsHidden)
                }
            HStack(spacing: 0) {
                ForEach(Array(track.artists.enumerated()), id: \.offset) { index, artist in
                    if index > 0 { Text(", ") }
                    TitleLink(text: artist.name) {
                        if let uri = artist.uri { navigator.open(uri: uri) }
                    }
                }
            }
            .floeFont(size: compact ? 14 : 15, weight: .medium)
            .foregroundStyle(palette.highlight.mix(with: .white, by: 0.45))
            .lineLimit(1)
            .padding(.top, scale(compact ? 4 : 6))
            if let album = track.album, !album.isEmpty {
                TitleLink(text: album) { navigator.openAlbum(of: track, api: library.api) }
                    .floeFont(size: 12.5)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.top, scale(3))
            }
        }
        // As wide as before for the title, plus the star's room either side.
        .frame(maxWidth: scale(520) + 2 * (star + scale(4)))
        // The mini player asks too, but it needn't be what this star depends on.
        .onAppear { library.requestLikedState(track.uri) }
    }
}

/// Puts Now Playing's controls and the toolbar away (⇧⌘H), leaving the cover,
/// the lyrics and the background to watch. While they're away it's the way
/// back, with its name beside it, and Escape presses it.
struct ControlsToggle: View {
    let hidden: Bool
    let shortcut: KeyboardShortcut
    let action: () -> Void
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: scale(6)) {
                Image(systemName: "tv")
                if hidden { Text("Show controls") }
            }
            .floeFont(size: 12, weight: .semibold)
            .foregroundStyle(.white)
            .opacity(hovering ? 1 : 0.62)
            .padding(.horizontal, hidden ? scale(12) : 0)
            .frame(minWidth: scale(30), minHeight: scale(30))
            .glassControl(in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.floe)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .keyboardShortcut(shortcut)
        .help(hidden ? "Show controls" : "Hide controls")
        .accessibilityLabel(hidden ? "Show controls" : "Hide controls")
    }
}

/// A capsule with its label, so it reads as the switch for the column beside
/// it. On, it takes a tint from the cover; ⇧⌘L toggles it from the keyboard.
private struct LyricsToggle: View {
    @Binding var on: Bool
    @Environment(\.coverPalette) private var palette
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: scale(6)) {
                Image(systemName: on ? "quote.bubble.fill" : "quote.bubble")
                    .contentTransition(.symbolEffect(.replace))
                Text("Lyrics")
            }
            .floeFont(size: 12, weight: .semibold)
            .foregroundStyle(on ? palette.highlight.mix(with: .white, by: 0.3) : .white)
            .opacity(on || hovering ? 1 : 0.62)
            .padding(.horizontal, scale(12))
            .frame(height: scale(30))
            .glassControl(tint: on ? palette.accent.opacity(0.22) : nil, in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.floe)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .animation(FloeMotion.fade, value: on)
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .help(on ? "Hide lyrics" : "Show lyrics")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The cover in the shape chosen in Visuals. As a flower, the petals crawl
/// around an upright cover and the edge breathes; as a card, it sways in
/// perspective over its reflection. Core Animation runs both (see
/// `CrawlingCover` and `FloatingCover`), so playback costs no per-frame work here.
private struct CoverView: View {
    let size: CGFloat
    let card: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(VisualSettings.self) private var settings
    @Environment(CoverAppearance.self) private var appearance
    @Environment(\.coverPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.windowVisible) private var windowVisible
    @ReducedMotion private var still

    private var running: Bool { player.isPlaying && !still && scenePhase == .active && windowVisible }

    var body: some View {
        // A tinted rim, like a bottle cap's edge, separates the cover from the ring.
        let rim = palette.highlight.mix(with: .black, by: 0.45).opacity(0.9)
        // One container for both shapes, so the hero flight always has a single
        // cover to move; flexible inside, so it can draw at the mini player's size.
        ZStack {
            if let image = appearance.image {
                if card {
                    // The clock keeps running with the sway off, for the crossfade to a new cover.
                    FloatingCover(image: image, running: running, sways: settings.coverMotion && !still, fade: !still)
                } else {
                    // The petals are animations on the clock, so stopping them stops the clock.
                    CrawlingCover(image: image, rim: NSColor(rim), rimWidth: max(2, size * 0.014),
                                  running: running && settings.coverMotion, fade: !still)
                }
            } else if card {
                RoundedRectangle(cornerRadius: size * FloatingCover.inset * 0.085, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(Image(systemName: "music.note").floeFont(size: 60).foregroundStyle(Theme.tertiary))
                    .aspectRatio(1, contentMode: .fit)
                    .scaleEffect(FloatingCover.inset)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                BlobShape(phase: 0).fill(.white.opacity(0.06))
                    .overlay(Image(systemName: "music.note").floeFont(size: 60).foregroundStyle(Theme.tertiary))
                    .overlay(BlobShape(phase: 0).stroke(rim, lineWidth: max(2, size * 0.014)))
            }
        }
        // A new cover dips and springs back as it arrives.
        .keyframeAnimator(initialValue: 1.0, trigger: still ? nil : appearance.imageURL) {
            content, scale in content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0.97, duration: 0.1)
                SpringKeyframe(1, duration: 0.35, spring: SwiftUI.Spring(duration: 0.35, bounce: 0.15))
            }
        }
        .heroCover()
        .frame(width: size, height: size * (card ? 1 + FloatingCover.foot : 1))
        .accessibilityElement()
        .accessibilityLabel("Album cover")
    }
}
