import SwiftUI

struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(VisualSettings.self) private var settings
    @ReducedMotion private var still
    @AppStorage("nowPlayingLyrics") private var showLyrics = true
    @Environment(\.interfaceScale) private var scale
    @ViewState private var ringShown = false

    var body: some View {
        if let track = player.displayTrack {
            GeometryReader { geometry in
                let circular = settings.showVisualizer && settings.style == .circular
                let normal = settings.showVisualizer && settings.style == .normal
                let compact = geometry.size.height < scale(600)
                // Reserve room for a wrapped title, transport and optional bottom strip;
                // the circular ring scales with the cover, as in the reference.
                let controlsHeight = scale(compact ? 310 : 390)
                let ring = circular ? VisualizerView.ringScale : 1
                let available = (geometry.size.height - controlsHeight - (normal ? scale(96) : 0)) / ring
                let lyricsWidth = showLyrics ? max(scale(330), geometry.size.width * 0.42) : 0
                let columnWidth = geometry.size.width - 2 * scale.margin - lyricsWidth - (showLyrics ? scale(20) : 0)
                let coverWidth = (columnWidth - scale(compact ? 24 : 40)) / ring
                let coverSize = min(scale(showLyrics ? 330 : 420), max(scale(100), min(available, coverWidth)))
                VStack(spacing: scale(12)) {
                    HStack(spacing: scale(20)) {
                        // Cover, words, then controls: the wider gaps separate the
                        // groups and the narrower ones hold each group together.
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            CoverStage(size: coverSize, ring: ring) {
                                if circular { VisualizerView(circular: true).opacity(ringShown ? 1 : 0) }
                            }
                            // A new song's details rise into place as the old ones lift away.
                            ZStack {
                                TrackTitle(track: track, compact: compact)
                                    .id(track.uri)
                                    .transition(.trackChange(distance: 14, still: still))
                            }
                            .animation(still ? FloeMotion.fade : FloeMotion.enter, value: track.uri)
                            .padding(.top, scale(compact ? 14 : 26))
                            VStack(spacing: scale(compact ? 4 : 8)) {
                                ProgressBar(large: true).frame(maxWidth: scale(480))
                                TransportControls(playSize: 58)
                                VolumeControl().padding(.top, scale(compact ? 2 : 4))
                            }
                            .padding(.top, scale(compact ? 10 : 18))
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(scale(compact ? 12 : 20))
                        if showLyrics {
                            LyricsView().frame(width: lyricsWidth)
                                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: scale.corner - scale.margin, style: .continuous))
                                .transition(lyricsTransition)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    if normal { VisualizerView().frame(height: scale(84)).padding(.horizontal, scale(24)) }
                }
                .padding(scale.margin)
                .animation(still ? nil : FloeMotion.enter, value: showLyrics)
            }
            .overlay(alignment: .topTrailing) { LyricsToggle(on: $showLyrics).padding(2 * scale.margin) }
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
    @ViewBuilder var ringView: Ring
    @ReducedMotion private var still
    @ViewState private var hovering = false

    var body: some View {
        let lifted = hovering && !still
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [.black.opacity(0.5), .black.opacity(0)], center: .center,
                                     startRadius: 0, endRadius: size * 0.52))
                .frame(width: size * 1.05, height: size * 0.92)
                .offset(y: size * (lifted ? 0.1 : 0.06))
                .opacity(hovering ? 1 : 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ringView
            FlowerCoverView(size: size)
                .contentShape(Circle())
                .onHover { hovering = $0 }
        }
        .frame(width: size * ring, height: size * ring)
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
        VStack(spacing: 0) {
            Text(track.name)
                .floeFont(size: compact ? 24 : 28, weight: .bold)
                .tracking(compact ? -0.2 : -0.35)
                .lineLimit(2)
                .multilineTextAlignment(.center)
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
        .frame(maxWidth: scale(520))
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
            .foregroundStyle(on ? palette.highlight.mix(with: .white, by: 0.3) : (hovering ? .white : Theme.secondary))
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

/// The petals crawl around an upright cover and the edge breathes, both run by
/// Core Animation (see `CrawlingCover`), so playback costs no per-frame work here.
private struct FlowerCoverView: View {
    let size: CGFloat
    @Environment(PlayerModel.self) private var player
    @Environment(CoverAppearance.self) private var appearance
    @Environment(\.coverPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @ReducedMotion private var still

    private var running: Bool { player.isPlaying && !still && scenePhase == .active }

    var body: some View {
        // A tinted rim, like a bottle cap's edge, separates the cover from the ring.
        let rim = palette.highlight.mix(with: .black, by: 0.45).opacity(0.9)
        // Flexible inside, so the hero flight can draw it at the mini player's size.
        Group {
            if let image = appearance.image {
                CrawlingCover(image: image, rim: NSColor(rim), rimWidth: max(2, size * 0.014),
                              running: running, fade: !still)
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
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Album cover")
    }
}
