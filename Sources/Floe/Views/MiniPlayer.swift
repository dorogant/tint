import AppKit
import SwiftUI

/// Bottom bar: transport on the left, the current track in the centre, volume on the right.
struct MiniPlayerView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(\.interfaceScale) private var scale
    @ReducedMotion private var still
    @ViewState private var hovering = false

    /// Transport and volume get the same width, so the song sits on the
    /// window's centre line, under the toolbar's switcher. Just wider than
    /// the transport, so a narrow window leaves the song as much room as it can.
    private static let sideWidth: CGFloat = 200
    /// The bar's height in Compact points.
    static let height: CGFloat = 76

    var body: some View {
        HStack(spacing: scale(16)) {
            // A 44 pt Play button leaves 16 pt above and below, the bar's side inset.
            TransportControls(playSize: 44).frame(width: scale(Self.sideWidth), alignment: .leading)
            Spacer(minLength: 0)
            nowPlaying.frame(maxWidth: scale(560))
            Spacer(minLength: 0)
            VolumeControl().frame(width: scale(Self.sideWidth), alignment: .trailing)
        }
        .padding(.horizontal, scale(16))
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = player.displayTrack {
            HStack(spacing: scale(12)) {
                MiniCover(url: track.coverURL) { navigator.surface = .nowPlaying }
                VStack(alignment: .leading, spacing: scale(3)) {
                    HStack(spacing: scale(4)) {
                        // A new song's details rise into place as the old ones lift away.
                        ZStack(alignment: .leading) {
                            details(track).id(track.uri).transition(.trackChange(still: still))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                        .animation(still ? FloeMotion.fade : FloeMotion.enter, value: track.uri)
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
                .floeFont(size: 13)
                .foregroundStyle(Theme.tertiary)
        }
    }

    private func details(_ track: TrackInfo) -> some View {
        HStack(spacing: scale(8)) {
            TitleLink(text: track.name) { navigator.openAlbum(of: track, api: library.api) }
                .floeFont(size: 13, weight: .semibold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            Text("·").foregroundStyle(Theme.tertiary)
            HStack(spacing: 0) {
                ForEach(Array(track.artists.enumerated()), id: \.offset) { index, artist in
                    if index > 0 { Text(", ").foregroundStyle(Theme.secondary) }
                    LinkText(artist.name) {
                        if let uri = artist.uri { navigator.open(uri: uri) }
                    }
                }
            }
            .floeFont(size: 12)
            .lineLimit(1)
        }
    }

    /// Lyrics and a "More" menu slide 6 pt in from the right under the
    /// pointer. They keep their room, so the title never reflows.
    private func extras(_ track: TrackInfo) -> some View {
        let shown = hovering
        return HStack(spacing: scale(2)) {
            MiniAction(systemImage: "quote.bubble", active: navigator.surface == .lyrics,
                       help: navigator.surface == .lyrics ? "Hide lyrics" : "Show lyrics", action: toggleLyrics)
            Menu {
                trackItems(track)
            } label: {
                Image(systemName: "ellipsis").floeFont(size: 12, weight: .semibold)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .foregroundStyle(Theme.secondary)
            .frame(width: scale(22), height: scale(22))
            .help("More")
        }
        .opacity(shown ? 1 : 0)
        .offset(x: shown || still ? 0 : 6)
        .allowsHitTesting(shown)
        .floeHover(shown)
    }

    @ViewBuilder
    private func trackItems(_ track: TrackInfo) -> some View {
        Button("Go to Album") { navigator.openAlbum(of: track, api: library.api) }
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
            CopySongLinkButton(id: String(id))
        }
    }

    private func toggleLyrics() {
        navigator.surface = navigator.surface == .lyrics ? .library : .lyrics
    }
}

/// The playing cover. Under the pointer it lifts 2 pt with a deeper shadow
/// and shows that a click opens Now Playing, where the cover flies to.
private struct MiniCover: View {
    let url: URL?
    let open: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.isOnstage) private var onstage
    @ReducedMotion private var still
    @ViewState private var hovering = false

    var body: some View {
        let lifted = hovering && !still
        Button(action: open) {
            ArtworkView(url: url, size: scale(48), cornerRadius: scale(7))
                .heroCover(active: onstage)
                .overlay {
                    RoundedRectangle(cornerRadius: scale(7), style: .continuous)
                        .fill(.black.opacity(0.38))
                        .overlay {
                            Image(systemName: "chevron.up")
                                .floeFont(size: 14, weight: .bold)
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
        .floeHover(hovering)
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
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: active ? "\(systemImage).fill" : systemImage)
                .floeFont(size: 12, weight: .semibold)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(active ? palette.highlight : .white)
                .opacity(active || hovering ? 1 : 0.62)
                .frame(width: scale(22), height: scale(22))
                .background(Circle().fill(Theme.hover).opacity(hovering ? 1 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(TactileButtonStyle())
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A slim seekable track with elapsed and remaining times, like the system's
/// media scrubbers. Under the pointer the track thickens, a thumb grows out of
/// the playhead and the time under the pointer follows it; a drag scrubs,
/// previewing the time before release. Now Playing (`large`) glides its
/// playhead and sets the times beneath the track's ends.
struct ProgressBar: View {
    @Environment(\.coverPalette) private var palette
    var large = false
    @ReducedMotion private var still
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.windowVisible) private var windowVisible
    @Environment(\.isOnstage) private var onstage
    @Environment(PlayerModel.self) private var player
    @Environment(\.interfaceScale) private var scale
    @ViewState private var dragFraction: Double?
    @ViewState private var hovering = false

    var body: some View {
        let duration = max(player.displayTrack?.durationMs ?? 0, 1)
        let enabled = player.displayTrack != nil && !player.isLoading
        let visible = scenePhase == .active && windowVisible && onstage
        // Both bars tick once a second; Core Animation glides the Now Playing
        // playhead in between and moves the pointer readout.
        TimelineView(.animation(minimumInterval: 1, paused: !player.isPlaying || dragFraction != nil || !visible)) { context in
            let fraction = dragFraction ?? min(player.positionMs(at: context.date) / duration, 1)
            // Aim the glide at where playback will be on the next tick.
            let ahead = dragFraction ?? min(player.positionMs(at: context.date.addingTimeInterval(1)) / duration, 1)
            let scrubbing = dragFraction != nil
            let glide = large && player.isPlaying && !scrubbing && visible && !still
            let track = self.track(progress: glide ? ahead : fraction, glide: glide, scrubbing: scrubbing,
                                   duration: duration, enabled: enabled)
            let elapsed = Text(Format.duration(ms: fraction * duration))
                .foregroundStyle(scrubbing ? .white : (large ? Theme.secondary : Theme.tertiary))
            // Whole seconds on both sides, so elapsed and remaining always add up to the length.
            let remaining = Text("\u{2212}" + Format.duration(ms: Double(Int(duration / 1000) - Int(fraction * duration / 1000)) * 1000))
            if large {
                // The times sit about 6 pt under the track, inside its generous hit area.
                VStack(spacing: -3) {
                    track.frame(height: scale(22))
                    HStack {
                        elapsed
                        Spacer(minLength: scale(8))
                        remaining
                    }
                    .font(scale.font(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                }
            } else {
                HStack(spacing: scale(8)) {
                    elapsed.frame(width: scale(36), alignment: .trailing)
                    track.frame(height: scale(12))
                    remaining.frame(width: scale(40), alignment: .trailing)
                }
                .font(scale.font(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
            }
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

    /// The fill stays a calm white; while scrubbing it takes the cover's colour.
    private func track(progress: Double, glide: Bool, scrubbing: Bool, duration: Double, enabled: Bool) -> some View {
        let metrics = large ? ProgressTrackView.Metrics.regular : .compact
        return GeometryReader { geometry in
            ProgressTrack(progress: progress, fill: scrubbing ? palette.highlight : .white.opacity(hovering ? 0.95 : 0.85),
                          metrics: metrics, glide: glide,
                          emphasis: scrubbing ? .grab : (hovering && enabled ? .hover : .rest), still: still)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .floeHover(hovering || scrubbing)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = min(max($0.location.x / max(geometry.size.width, 1), 0), 1) }
                    .onEnded { _ in
                        if let target = dragFraction { player.seek(toMs: target * duration) }
                        dragFraction = nil
                    })
                .overlay(alignment: .bottom) {
                    // Clear of the grabbed thumb, which is 15% larger than at rest.
                    ScrubReadout(durationMs: duration, scrub: dragFraction, trackHeight: geometry.size.height,
                                 clearance: (metrics.thumb * 1.15 / 2).rounded(.up) + 6, still: still, enabled: enabled)
                        .frame(height: geometry.size.height + 34)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}

/// The speaker shows the level through its lit waves. Under the pointer the
/// slider thickens and grows its knob; keyboard changes land without animation.
struct VolumeControl: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @ReducedMotion private var still
    @ViewState private var dragging = false
    @ViewState private var hovering = false
    @ViewState private var speakerHovering = false
    @ViewState private var audibleVolume = 0.6
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: scale(8)) {
            Button(action: toggleMute) {
                Image(systemName: player.volume > 0 ? "speaker.wave.3.fill" : "speaker.slash.fill",
                      variableValue: player.volume)
                    .contentTransition(.symbolEffect(.replace))
                    .floeFont(size: 13)
                    .foregroundStyle(.white)
                    .opacity(speakerHovering ? 1 : 0.62)
                    .frame(width: scale(22), height: scale(22))
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle())
            .onHover { speakerHovering = $0 }
            .floeHover(speakerHovering)
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
            .frame(width: scale(110), height: scale(14))
            .onHover { hovering = $0 }
            .floeHover(hovering || dragging)
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
        withAnimation(still ? nil : FloeMotion.glide) {
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
    @ReducedMotion private var still

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
