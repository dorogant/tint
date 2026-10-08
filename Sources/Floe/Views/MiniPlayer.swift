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
        if let track = player.displayTrack {
            HStack(spacing: 12) {
                ArtworkView(url: track.coverURL, size: 48, cornerRadius: 7)
                    .heroCover()
                    .onTapGesture { navigator.surface = .nowPlaying }
                    .help("Now Playing")
                VStack(alignment: .leading, spacing: 3) {
                    // A new song's details roll up into place.
                    ZStack {
                        details(track).id(track.uri).transition(.push(from: .bottom))
                    }
                    .clipped()
                    ProgressBar()
                }
            }
            .floeAnimation(value: track.uri, duration: 0.45, bounce: 0.1)
            .onAppear { library.requestLikedState(track.uri) }
            .onChange(of: track.uri) { library.requestLikedState(track.uri) }
        } else {
            Text("Pick something to play")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiary)
        }
    }

    private func details(_ track: TrackInfo) -> some View {
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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reduceMotion") private var reduceMotion = false
    @Environment(PlayerModel.self) private var player
    @ViewState private var dragFraction: Double?
    @ViewState private var hovering = false

    var body: some View {
        let duration = max(player.displayTrack?.durationMs ?? 0, 1)
        // Both bars tick once a second; Core Animation scrolls the Now Playing wave
        // and glides its playhead in between.
        TimelineView(.animation(minimumInterval: 1, paused: !player.isPlaying || dragFraction != nil || scenePhase != .active)) { context in
            let fraction = dragFraction ?? min(player.positionMs(at: context.date) / duration, 1)
            // Aim the glide at where playback will be on the next tick.
            let ahead = dragFraction ?? min(player.positionMs(at: context.date.addingTimeInterval(1)) / duration, 1)
            HStack(spacing: 8) {
                Text(Format.duration(ms: fraction * duration))
                    .frame(width: 36, alignment: .trailing)
                GeometryReader { geometry in
                    Group {
                        if wavy {
                            let playing = player.isPlaying && dragFraction == nil && scenePhase == .active
                            let animate = playing && !reduceMotion && !systemReduceMotion
                            WavyProgress(progress: animate ? ahead : fraction, color: palette.highlight,
                                         moving: animate, glide: animate)
                        } else {
                            SliderTrack(fraction: fraction, active: hovering || dragFraction != nil,
                                        tint: dragFraction == nil ? .white.opacity(0.85) : palette.accent)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .floeAnimation(value: hovering || dragFraction != nil, duration: 0.2)
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
        .onChange(of: player.displayTrack?.uri) { dragFraction = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(Format.duration(ms: player.positionMs(at: Date())))
        .accessibilityAdjustableAction { direction in
            player.seek(toMs: player.positionMs(at: Date()) + (direction == .increment ? 5000 : -5000))
        }
        .disabled(player.displayTrack == nil || player.isLoading)
    }
}

struct VolumeControl: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @ViewState private var dragging = false
    @ViewState private var hovering = false
    @ViewState private var audibleVolume = 0.6

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if player.volume > 0 { audibleVolume = player.volume; player.setVolume(0) }
                else { player.setVolume(audibleVolume) }
            } label: {
                Image(systemName: player.volume > 0 ? "speaker.wave.3.fill" : "speaker.slash.fill",
                      variableValue: player.volume)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).frame(width: 22)
            }.buttonStyle(.plain).help(player.volume > 0 ? "Mute" : "Unmute")
            GeometryReader { geometry in
                SliderTrack(fraction: player.volume, active: hovering || dragging,
                            tint: dragging ? palette.highlight : .white.opacity(0.88))
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            // Follow the pointer exactly; keys and mute still glide.
                            var immediate = Transaction()
                            immediate.disablesAnimations = true
                            withTransaction(immediate) { player.setVolume(value.location.x / max(geometry.size.width, 1)) }
                        }
                        .onEnded { _ in dragging = false })
            }
            .frame(width: 110, height: 14)
            .onHover { hovering = $0 }
            .floeAnimation(value: hovering || dragging, duration: 0.2)
            .floeAnimation(value: player.volume, duration: 0.2)
        }
        .help("Volume")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Volume")
        .accessibilityValue(Text("\(Int(player.volume * 100))%"))
        .accessibilityAdjustableAction { direction in
            player.setVolume(player.volume + (direction == .increment ? 0.05 : -0.05))
        }
    }
}

/// A soft capsule like the system's sliders; it thickens while the pointer is on it.
private struct SliderTrack: View {
    var fraction: Double
    var active: Bool
    var tint: Color

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.16))
                .overlay(alignment: .leading) {
                    Rectangle().fill(tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
                .clipShape(Capsule())
        }
        .frame(height: active ? 8 : 4)
    }
}
