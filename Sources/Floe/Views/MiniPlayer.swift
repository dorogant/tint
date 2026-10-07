import SwiftUI

/// Bottom bar: transport on the left, the current track in the centre, volume on the right.
struct MiniPlayerView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator

    var body: some View {
        HStack(spacing: 16) {
            TransportControls().frame(width: 250, alignment: .leading)
            Spacer(minLength: 0)
            nowPlaying.frame(maxWidth: 560)
            Spacer(minLength: 0)
            VolumeControl().frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = player.track {
            HStack(spacing: 12) {
                ArtworkView(url: track.coverURL, size: 48, cornerRadius: 7)
                    .onTapGesture { openAlbum(track) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        LinkText(track.name) { openAlbum(track) }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("·").foregroundStyle(Theme.tertiary)
                        HStack(spacing: 0) {
                            ForEach(Array(track.artists.enumerated()), id: \.offset) { index, artist in
                                if index > 0 { Text(", ").foregroundStyle(Theme.secondary) }
                                LinkText(artist.name) {
                                    if let uri = artist.uri { navigator.open(uri: uri) }
                                }
                            }
                        }
                        .font(.system(size: 12))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        LikeButton(uri: track.uri)
                    }
                    ProgressBar()
                }
            }
            .onAppear { library.requestLikedState(track.uri) }
            .onChange(of: track.uri) { library.requestLikedState(track.uri) }
        } else {
            Text("Pick something to play")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiary)
        }
    }

    /// librespot doesn't report the album ID; look it up when asked.
    private func openAlbum(_ track: TrackInfo) {
        guard let id = track.uri.split(separator: ":").last.map(String.init) else { return }
        Task {
            if let album = try? await library.api.track(id).album {
                navigator.push(.album(album.id))
            }
        }
    }
}

/// Thin seekable progress line with elapsed/total times.
struct ProgressBar: View {
    @Environment(\.coverPalette) private var palette
    var wavy = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    @Environment(PlayerModel.self) private var player
    @ViewState private var dragFraction: Double?

    var body: some View {
        let duration = max(player.track?.durationMs ?? 0, 1)
        // The mini player updates once a second; Now Playing animates the wave at 12 Hz.
        TimelineView(.animation(minimumInterval: wavy && !reduceMotion && !systemReduceMotion ? 1 / 12 : 1,
                                paused: !player.isPlaying || dragFraction != nil)) { context in
            let fraction = dragFraction ?? min(player.positionMs(at: context.date) / duration, 1)
            HStack(spacing: 8) {
                Text(Format.duration(ms: fraction * duration))
                    .frame(width: 36, alignment: .trailing)
                GeometryReader { geometry in
                    Group {
                        if wavy {
                            WavyProgress(progress: fraction,
                                         phase: reduceMotion || systemReduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 1.2,
                                         color: palette.highlight)
                        } else {
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.14))
                                Capsule().fill(dragFraction == nil ? .white.opacity(0.85) : palette.accent)
                                    .frame(width: geometry.size.width * fraction)
                            }.frame(height: 4)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(max($0.location.x / max(geometry.size.width, 1), 0), 1) }
                        .onEnded { _ in
                            if let target = dragFraction { player.seek(toMs: target * duration) }
                            dragFraction = nil
                        })
                }
                .frame(height: wavy ? 24 : 12)
                Text(Format.duration(ms: duration))
                    .frame(width: 36, alignment: .leading)
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(Theme.tertiary)
        }
        .onChange(of: player.track?.uri) { dragFraction = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(Format.duration(ms: player.positionMs(at: Date())))
        .accessibilityAdjustableAction { direction in
            player.seek(toMs: player.positionMs(at: Date()) + (direction == .increment ? 5000 : -5000))
        }
        .disabled(player.track == nil)
    }
}

struct VolumeControl: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @ViewState private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .frame(width: 20)
                .onTapGesture { player.setVolume(player.volume > 0 ? 0 : 0.6) }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(dragging ? palette.accent : .white.opacity(0.85))
                        .frame(width: geometry.size.width * player.volume)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged {
                        dragging = true
                        player.setVolume($0.location.x / max(geometry.size.width, 1))
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(width: 110, height: 12)
        }
        .help("Volume")
    }

    private var icon: String {
        switch player.volume {
        case 0: "speaker.slash.fill"
        case ..<0.33: "speaker.wave.1.fill"
        case ..<0.66: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}
