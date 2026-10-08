import SwiftUI

struct NowPlayingView: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @Environment(VisualSettings.self) private var settings
    @Environment(CoverAppearance.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false

    var body: some View {
        if let track = player.displayTrack {
            GeometryReader { geometry in
                let circular = settings.showVisualizer && settings.style == .circular
                let normal = settings.showVisualizer && settings.style == .normal
                let compact = geometry.size.height < 600
                // Reserve room for a wrapped title, transport and optional bottom strip.
                let controlsHeight: CGFloat = compact ? 310 : 390
                let coverSize = min(330, max(100, geometry.size.height - controlsHeight - (circular ? 64 : 0) - (normal ? 96 : 0)))
                VStack(spacing: 12) {
                    HStack(spacing: 20) {
                        VStack(spacing: compact ? 8 : 14) {
                            Spacer(minLength: 0)
                            ZStack {
                                if circular { VisualizerView(circular: true) }
                                cover(size: coverSize)
                            }.frame(width: coverSize + (circular ? 64 : 0), height: coverSize + (circular ? 64 : 0))
                            VStack(spacing: 6) {
                                Text(track.name).font(.system(size: 28, weight: .bold))
                                    .lineLimit(2).multilineTextAlignment(.center)
                                Text([track.artistLine, track.album].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(2)
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

    private func cover(size: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !player.isPlaying || reduceMotion || systemReduceMotion)) { context in
            let phase = reduceMotion || systemReduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 0.18
            ZStack {
                BlobShape(phase: phase).fill(palette.accent.opacity(0.16)).padding(-8)
                if let image = appearance.image {
                    Image(decorative: image, scale: 2).resizable().scaledToFill()
                        .frame(width: size, height: size).clipShape(BlobShape(phase: phase))
                } else {
                    BlobShape(phase: phase).fill(.white.opacity(0.06))
                        .overlay(Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(Theme.tertiary))
                }
                BlobShape(phase: phase).stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .frame(width: size, height: size)

        }
        .accessibilityLabel("Album cover")
    }
}
