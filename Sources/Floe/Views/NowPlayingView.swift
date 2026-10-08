import SwiftUI

struct NowPlayingView: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @Environment(VisualSettings.self) private var settings
    @Environment(CoverAppearance.self) private var appearance

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
                let coverSize = min(330, max(100, (geometry.size.height - controlsHeight - (normal ? 96 : 0)) / ring))
                VStack(spacing: 12) {
                    HStack(spacing: 20) {
                        VStack(spacing: compact ? 8 : 14) {
                            Spacer(minLength: 0)
                            ZStack {
                                if circular { VisualizerView(circular: true) }
                                FlowerCoverView(size: coverSize)
                            }.frame(width: coverSize * ring, height: coverSize * ring)
                            VStack(spacing: 6) {
                                Text(track.name).font(.system(size: 28, weight: .bold))
                                    .lineLimit(2).multilineTextAlignment(.center)
                                    .contentTransition(.opacity)
                                    .floeAnimation(value: track.name)
                                Text([track.artistLine, track.album].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(2)
                                    .contentTransition(.opacity)
                                    .floeAnimation(value: track.artistLine)
                            }
                            ProgressBar(wavy: true).frame(maxWidth: 480)
                            TransportControls(playSize: 58)
                            VolumeControl()
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(compact ? 12 : 20)
                        LyricsView().frame(width: max(330, geometry.size.width * 0.42))
                            .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    }
                    .frame(maxHeight: .infinity)
                    if normal { VisualizerView().frame(height: 84).padding(.horizontal, 24) }
                }
                .padding(12)
            }
        } else {
            MessageView(systemImage: "music.note", message: L10n.string("Pick something to play"))
                .frame(maxHeight: .infinity)
        }
    }

}

/// The clock counts active playback, so pause/resume never jumps to wall time.
private struct FlowerCoverView: View {
    let size: CGFloat
    @Environment(PlayerModel.self) private var player
    @Environment(CoverAppearance.self) private var appearance
    @Environment(VisualizationModel.self) private var visualization
    @Environment(\.coverPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    @ViewState private var elapsed: TimeInterval = 0
    @ViewState private var started: Date?

    private var running: Bool {
        player.isPlaying && !reduceMotion && !systemReduceMotion && scenePhase == .active
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { context in
            let time = elapsed + (started.map { max(0, context.date.timeIntervalSince($0)) } ?? 0)
            let phase = time * 0.65
            let energy = running && visualization.isRunning ? min(1, Double(visualization.frame.rms) * 3.2) : 0
            ZStack {
                if let image = appearance.image {
                    Image(decorative: image, scale: 2).resizable().scaledToFill()
                        .frame(width: size, height: size).clipShape(BlobShape(phase: phase))
                        .id(appearance.imageURL)
                        .transition(.opacity)
                } else {
                    BlobShape(phase: phase).fill(.white.opacity(0.06))
                        .overlay(Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(Theme.tertiary))
                }
                // A tinted rim, like a bottle cap's edge, separates the cover from the ring.
                BlobShape(phase: phase)
                    .stroke(palette.highlight.mix(with: .black, by: 0.45).opacity(0.9),
                            lineWidth: max(2, size * 0.014))
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(time * 18))
            .scaleEffect(1 + energy * 0.018)
            .floeAnimation(value: appearance.imageURL, duration: 0.35)
        }
        .onChange(of: running, initial: true) {
            let now = Date()
            if let started { elapsed += max(0, now.timeIntervalSince(started)) }
            started = running ? now : nil
        }
        .accessibilityLabel("Album cover")
    }
}
