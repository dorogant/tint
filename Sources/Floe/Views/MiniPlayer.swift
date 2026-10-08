import AppKit
import SwiftUI

/// Bottom bar: transport on the left, the current track in the centre, volume on the right.
struct MiniPlayerView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @PlaybackMotion.Still private var still
    @ViewState private var hovering = false

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
                MiniCover(url: track.coverURL) { navigator.surface = .nowPlaying }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        // A new song's details rise into place as the old ones lift away.
                        ZStack(alignment: .leading) {
                            details(track).id(track.uri).transition(.trackChange(still: still))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                        .animation(still ? PlaybackMotion.fade : PlaybackMotion.enter, value: track.uri)
                        extras(track)
                        LikeButton(uri: track.uri)
                    }
                    ProgressBar()
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // The hover-only controls, for keyboard, VoiceOver and right clicks.
            .contextMenu {
                Button("Now Playing") { navigator.surface = .nowPlaying }
                Button(LocalizedStringKey(navigator.surface == .lyrics ? "Hide lyrics" : "Show lyrics"),
                       action: toggleLyrics)
                Divider()
                trackItems(track)
            }
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
        }
    }

    /// Lyrics and a "More" menu slide 6 pt in from the right under the
    /// pointer. They keep their room, so the title never reflows.
    private func extras(_ track: TrackInfo) -> some View {
        let shown = hovering
        return HStack(spacing: 2) {
            MiniAction(systemImage: "quote.bubble", active: navigator.surface == .lyrics,
                       help: navigator.surface == .lyrics ? "Hide lyrics" : "Show lyrics", action: toggleLyrics)
            Menu {
                trackItems(track)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .foregroundStyle(Theme.secondary)
            .frame(width: 22, height: 22)
            .help("More")
        }
        .opacity(shown ? 1 : 0)
        .offset(x: shown || still ? 0 : 6)
        .allowsHitTesting(shown)
        .animation(still ? PlaybackMotion.fade : (shown ? PlaybackMotion.enter : PlaybackMotion.exit), value: shown)
    }

    @ViewBuilder
    private func trackItems(_ track: TrackInfo) -> some View {
        Button("Go to Album") { openAlbum(track) }
        let artists = track.artists.filter { $0.uri != nil }
        if artists.count == 1, let uri = artists[0].uri {
            Button("Go to Artist") { navigator.open(uri: uri) }
        } else if !artists.isEmpty {
            Menu("Go to Artist") {
                ForEach(Array(artists.enumerated()), id: \.offset) { _, artist in
                    Button(artist.name) { if let uri = artist.uri { navigator.open(uri: uri) } }
                }
            }
        }
        if track.uri.hasPrefix("spotify:track:"), let id = track.uri.split(separator: ":").last {
            Divider()
            Button("Copy Song Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://open.spotify.com/track/\(id)", forType: .string)
            }
        }
    }

    private func toggleLyrics() {
        navigator.surface = navigator.surface == .lyrics ? .library : .lyrics
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

/// The playing cover. Under the pointer it lifts 2 pt with a deeper shadow
/// and shows that a click opens Now Playing, where the cover flies to.
private struct MiniCover: View {
    let url: URL?
    let open: () -> Void
    @PlaybackMotion.Still private var still
    @ViewState private var hovering = false

    var body: some View {
        let lifted = hovering && !still
        Button(action: open) {
            ArtworkView(url: url, size: 48, cornerRadius: 7)
                .heroCover()
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.black.opacity(0.38))
                        .overlay {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(y: lifted || still ? 0 : 2)
                        }
                        .opacity(hovering ? 1 : 0)
                }
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 8 : 3, y: hovering ? 4 : 1.5)
                .scaleEffect(lifted ? 1.03 : 1)
                .offset(y: lifted ? -1 : 0)
        }
        .buttonStyle(TactileButtonStyle())
        .onHover { hovering = $0 }
        .hoverMotion(hovering)
        .help("Now Playing")
        .accessibilityLabel("Now Playing")
    }
}

/// A small icon button for the mini player's revealed controls.
private struct MiniAction: View {
    let systemImage: String
    var active = false
    let help: LocalizedStringKey
    let action: () -> Void
    @Environment(\.coverPalette) private var palette
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: active ? "\(systemImage).fill" : systemImage)
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(active ? palette.highlight : (hovering ? .white : Theme.secondary))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.hover).opacity(hovering ? 1 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(TactileButtonStyle())
        .onHover { hovering = $0 }
        .hoverMotion(hovering)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Thin seekable progress line with elapsed and total times. Under the pointer
/// the line thickens, the knob grows out of the playhead and the time under
/// the pointer follows it; a drag scrubs, previewing the time before release.
struct ProgressBar: View {
    @Environment(\.coverPalette) private var palette
    var wavy = false
    @PlaybackMotion.Still private var still
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlayerModel.self) private var player
    @ViewState private var dragFraction: Double?
    @ViewState private var hovering = false

    var body: some View {
        let duration = max(player.displayTrack?.durationMs ?? 0, 1)
        let enabled = player.displayTrack != nil && !player.isLoading
        // Both bars tick once a second; Core Animation scrolls the Now Playing wave
        // and glides its playhead in between, and moves the pointer readout.
        TimelineView(.animation(minimumInterval: 1, paused: !player.isPlaying || dragFraction != nil || scenePhase != .active)) { context in
            let fraction = dragFraction ?? min(player.positionMs(at: context.date) / duration, 1)
            // Aim the glide at where playback will be on the next tick.
            let ahead = dragFraction ?? min(player.positionMs(at: context.date.addingTimeInterval(1)) / duration, 1)
            let scrubbing = dragFraction != nil
            HStack(spacing: 8) {
                Text(Format.duration(ms: fraction * duration))
                    .foregroundStyle(scrubbing ? .white : Theme.tertiary)
                    .frame(width: 36, alignment: .trailing)
                GeometryReader { geometry in
                    Group {
                        if wavy {
                            let playing = player.isPlaying && !scrubbing && scenePhase == .active
                            let animate = playing && !still
                            WavyProgress(progress: animate ? ahead : fraction, color: palette.highlight,
                                         moving: animate, glide: animate,
                                         knob: still ? .rest : (scrubbing ? .grab : (hovering ? .hover : .rest)))
                        } else {
                            SliderTrack(fraction: fraction, active: hovering || scrubbing, grabbed: scrubbing,
                                        tint: scrubbing ? palette.accent : .white.opacity(0.85))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .hoverMotion(hovering || scrubbing)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(max($0.location.x / max(geometry.size.width, 1), 0), 1) }
                        .onEnded { _ in
                            if let target = dragFraction { player.seek(toMs: target * duration) }
                            dragFraction = nil
                        })
                    .overlay(alignment: .bottom) {
                        ScrubReadout(durationMs: duration, scrub: dragFraction, trackHeight: geometry.size.height,
                                     clearance: wavy ? 15 : 10, still: still, enabled: enabled)
                            .frame(height: geometry.size.height + 34)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
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
        .disabled(!enabled)
    }
}

/// The speaker shows the level through its lit waves. Under the pointer the
/// slider thickens and grows its knob; keyboard changes land without animation.
struct VolumeControl: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @PlaybackMotion.Still private var still
    @ViewState private var dragging = false
    @ViewState private var hovering = false
    @ViewState private var speakerHovering = false
    @ViewState private var audibleVolume = 0.6

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleMute) {
                Image(systemName: player.volume > 0 ? "speaker.wave.3.fill" : "speaker.slash.fill",
                      variableValue: player.volume)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 13))
                    .foregroundStyle(speakerHovering ? .white : Theme.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle())
            .onHover { speakerHovering = $0 }
            .hoverMotion(speakerHovering)
            .help(player.volume > 0 ? "Mute" : "Unmute")
            .accessibilityLabel(player.volume > 0 ? "Mute" : "Unmute")
            GeometryReader { geometry in
                SliderTrack(fraction: player.volume, active: hovering || dragging, grabbed: dragging,
                            tint: dragging ? palette.highlight : .white.opacity(0.88))
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            drag(to: value.location.x / max(geometry.size.width, 1))
                        }
                        .onEnded { _ in dragging = false })
            }
            .frame(width: 110, height: 14)
            .onHover { hovering = $0 }
            .hoverMotion(hovering || dragging)
        }
        .help("Volume")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Volume")
        .accessibilityValue(Text("\(Int(player.volume * 100))%"))
        .accessibilityAdjustableAction { direction in
            player.setVolume(player.volume + (direction == .increment ? 0.05 : -0.05))
        }
    }

    /// A click, so the fill glides; held volume keys step without queueing springs.
    private func toggleMute() {
        withAnimation(still ? nil : PlaybackMotion.glide) {
            if player.volume > 0 { audibleVolume = player.volume; player.setVolume(0) }
            else { player.setVolume(audibleVolume) }
        }
    }

    /// Follows the pointer exactly, with a light tap from the trackpad at either end.
    private func drag(to fraction: Double) {
        let target = min(max(fraction, 0), 1)
        if (target == 0 || target == 1) && target != player.volume {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) { player.setVolume(target) }
    }
}

/// A soft capsule like the system's sliders. Under the pointer it thickens
/// from 4 to 6 pt and a 12 pt knob grows out of the end of the fill; held, the
/// knob swells a little more. With Reduce Motion the knob fades in instead.
/// Only scale and offset change, so none of this re-lays out the window.
private struct SliderTrack: View {
    var fraction: Double
    var active: Bool
    var grabbed = false
    var tint: Color
    @PlaybackMotion.Still private var still

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(active ? 0.22 : 0.16))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(tint).scaleEffect(x: clamped, anchor: .leading)
                    }
                    .clipShape(Capsule())
                    .frame(height: 6)
                    .scaleEffect(y: active && !still ? 1 : 4 / 6)
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .frame(width: 12, height: 12)
                    .scaleEffect(still ? 1 : (active ? (grabbed ? 1.15 : 1) : 4 / 12))
                    .opacity(active ? 1 : 0)
                    .offset(x: width * clamped - 6)
            }
            .frame(width: width, height: geometry.size.height)
        }
    }
}
