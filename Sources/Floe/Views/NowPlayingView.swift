import SwiftUI

struct NowPlayingView: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @Environment(VisualSettings.self) private var settings
    @Environment(CoverAppearance.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    @AppStorage("nowPlayingLyrics") private var showLyrics = true
    @ViewState private var ringShown = false

    var body: some View {
        if let track = player.displayTrack {
            GeometryReader { geometry in
                let circular = settings.showVisualizer && settings.style == .circular
                let normal = settings.showVisualizer && settings.style == .normal
                let compact = geometry.size.height < 600
                // Reserve room for a wrapped title, transport and optional bottom strip;
                // the circular ring scales with the cover, as in the reference.
                let controlsHeight: CGFloat = compact ? 310 : 390
                let ring = circular ? VisualizerView.ringScale : 1
                let available = (geometry.size.height - controlsHeight - (normal ? 96 : 0)) / ring
                let lyricsWidth = showLyrics ? max(330, geometry.size.width * 0.42) : 0
                let columnWidth = geometry.size.width - 24 - lyricsWidth - (showLyrics ? 20 : 0)
                let coverWidth = (columnWidth - (compact ? 24 : 40)) / ring
                let coverSize = min(showLyrics ? 330 : 420, max(100, min(available, coverWidth)))
                VStack(spacing: 12) {
                    HStack(spacing: 20) {
                        VStack(spacing: compact ? 8 : 14) {
                            Spacer(minLength: 0)
                            ZStack {
                                if circular { VisualizerView(circular: true).opacity(ringShown ? 1 : 0) }
                                FlowerCoverView(size: coverSize)
                            }.frame(width: coverSize * ring, height: coverSize * ring)
                            // A new song's title rolls up into place.
                            ZStack {
                                VStack(spacing: 6) {
                                    Text(track.name).font(.system(size: 28, weight: .bold))
                                        .lineLimit(2).multilineTextAlignment(.center)
                                    Text([track.artistLine, track.album].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(2)
                                }
                                .id(track.uri)
                                .transition(.push(from: .bottom))
                            }
                            .clipped()
                            ProgressBar(wavy: true).frame(maxWidth: 480)
                            TransportControls(playSize: 58)
                            VolumeControl()
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(compact ? 12 : 20)
                        .floeAnimation(value: track.uri, duration: 0.45, bounce: 0.1)
                        if showLyrics {
                            LyricsView().frame(width: lyricsWidth)
                                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                                .transition(.opacity.combined(with: .offset(x: 60)))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    if normal { VisualizerView().frame(height: 84).padding(.horizontal, 24) }
                }
                .padding(12)
                .floeAnimation(value: showLyrics, duration: 0.55, bounce: 0.12)
            }
            .overlay(alignment: .topTrailing) { lyricsToggle }
            .onAppear {
                // The ring fades in once the cover has flown into place.
                withAnimation(reduceMotion || systemReduceMotion ? nil : .easeOut(duration: 0.4).delay(0.35)) {
                    ringShown = true
                }
            }
        } else {
            MessageView(systemImage: "music.note", message: L10n.string("Pick something to play"))
                .frame(maxHeight: .infinity)
        }
    }

    /// Leaves just the cover and visualizer on screen.
    private var lyricsToggle: some View {
        Button { showLyrics.toggle() } label: {
            Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                .glassControl(in: .circle)
        }
        .buttonStyle(.floe)
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .help(showLyrics ? "Hide lyrics" : "Show lyrics")
        .padding(18)
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false

    private var still: Bool { reduceMotion || systemReduceMotion }
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
                    .overlay(Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(Theme.tertiary))
                    .overlay(BlobShape(phase: 0).stroke(rim, lineWidth: max(2, size * 0.014)))
            }
        }
        // A new cover dips and springs back as it arrives.
        .keyframeAnimator(initialValue: 1.0, trigger: still ? nil : appearance.imageURL) {
            content, scale in content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0.93, duration: 0.14)
                SpringKeyframe(1, duration: 0.6, spring: .bouncy)
            }
        }
        .heroCover()
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Album cover")
    }
}
