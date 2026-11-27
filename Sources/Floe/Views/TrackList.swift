import AppKit
import SwiftUI

/// A track at a position in some list (the same track can appear twice in a playlist).
struct TrackEntry: Identifiable {
    let id: Int
    let track: Track
    var addedAt: Date? = nil
}

enum TrackSort: String, CaseIterable, Identifiable {
    case custom, title, artist, album, added, duration
    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .custom: "Custom order"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .added: "Date added"
        case .duration: "Duration"
        }
    }

    func apply(_ entries: [TrackEntry]) -> [TrackEntry] {
        switch self {
        case .custom: entries
        case .title: entries.sorted { $0.track.name.localizedStandardCompare($1.track.name) == .orderedAscending }
        case .artist: entries.sorted { $0.track.artistLine.localizedStandardCompare($1.track.artistLine) == .orderedAscending }
        case .album: entries.sorted { ($0.track.album?.name ?? "").localizedStandardCompare($1.track.album?.name ?? "") == .orderedAscending }
        case .added: entries.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        case .duration: entries.sorted { $0.track.durationMs < $1.track.durationMs }
        }
    }
}

struct TrackListView: View {
    enum Numbering { case position, trackNumber }

    let entries: [TrackEntry]
    var showCover = true
    var showAlbum = true
    var numbering = Numbering.position
    let play: (TrackEntry) -> Void
    /// Called when the last row appears (load the next page).
    var onReachEnd: (() -> Void)?
    @Environment(\.interfaceScale) private var scale
    @ViewState private var motion = ListMotion()

    var body: some View {
        LazyVStack(spacing: 0) {
            header
            // Not copied into an array: with 5,000 liked songs that was a megabyte
            // of rows (and their reference counts) on every redraw of the list.
            ForEach(entries.enumerated(), id: \.element.id) { index, entry in
                TrackRow(
                    entry: entry,
                    number: numbering == .trackNumber ? (entry.track.trackNumber ?? index + 1) : index + 1,
                    showCover: showCover,
                    showAlbum: showAlbum,
                    play: { play(entry) }
                )
                .onAppear {
                    if entry.id == entries.last?.id { onReachEnd?() }
                }
            }
        }
        // Row plates reach past the page gutter; the columns stay on it.
        .padding(.horizontal, -scale.plate)
        // The list moving in the window is the page scrolling.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _ in motion.moved() }
        .environment(\.listMotion, motion)
    }

    private var header: some View {
        HStack(spacing: scale(12)) {
            Text("#").frame(width: scale(28))
            if showCover { Color.clear.frame(width: scale(40), height: 1) }
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            if showAlbum { Text("Album").frame(maxWidth: .infinity, alignment: .leading) }
            Color.clear.frame(width: scale(22), height: 1)
            Image(systemName: "clock").frame(width: scale(44), alignment: .trailing)
            Color.clear.frame(width: scale(22), height: 1)
        }
        .floeFont(size: 11, weight: .semibold)
        .foregroundStyle(Theme.tertiary)
        .padding(.bottom, scale(8))
        // The rule stays on the gutter like the text; only row plates reach past it.
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.panelStroke).frame(height: 1) }
        .padding(.horizontal, scale.plate)
        .padding(.bottom, scale(4))
    }
}

private struct TrackRow: View {
    @Environment(\.coverPalette) private var palette
    let entry: TrackEntry
    let number: Int
    let showCover: Bool
    let showAlbum: Bool
    let play: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(\.interfaceScale) private var scale
    @Environment(\.listMotion) private var motion
    /// Rows round like the sidebar's plates (Compact points).
    static let radius: CGFloat = 10
    /// With Reduce Motion the row still lights up, it just doesn't move or scale.
    @ReducedMotion private var still
    /// Local to the row, so hovering redraws one row rather than the list.
    @ViewState private var hovering = false

    var body: some View {
        let track = entry.track
        let isCurrent = player.displayTrack?.uri == track.uri
        let playable = track.isPlayable != false && track.isCatalogTrack
        #if SCROLL_BENCHMARK
        let _ = ScrollProbe.rows += 1
        #endif

        HStack(spacing: scale(12)) {
            leading(isCurrent: isCurrent, playable: playable).frame(width: scale(28))
            if showCover {
                // The cover lifts a touch toward the pointer, as cards do; the
                // shadow only fades in, so Reduce Motion keeps it. It sits behind
                // the cover and only while hovered: a row at rest has no shadow
                // layer (there was one per row on screen, with a clear colour).
                ArtworkView(images: track.album?.images, size: scale(40), cornerRadius: scale(6))
                    .background {
                        if hovering {
                            RoundedRectangle(cornerRadius: scale(6)).fill(Color(white: 0.11))
                                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                                .transition(.opacity)
                        }
                    }
                    .scaleEffect(hovering && !still ? 1.03 : 1)
            }
            VStack(alignment: .leading, spacing: scale(3)) {
                HStack(spacing: scale(5)) {
                    Text(track.name)
                        .floeFont(size: 13, weight: .medium)
                        .foregroundStyle(isCurrent ? palette.highlight : .white)
                        .lineLimit(1)
                    if track.explicit == true {
                        Text("E").floeFont(size: 9, weight: .bold)
                            .padding(.horizontal, scale(3))
                            .background(Theme.tertiary, in: RoundedRectangle(cornerRadius: 2))
                            .foregroundStyle(.black)
                    }
                }
                ArtistLinks(artists: track.artists, lit: hovering)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAlbum {
                Group {
                    if let album = track.album {
                        LinkText(album.name, lit: hovering) { navigator.push(.album(album.id)) }
                    } else {
                        Text("")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LikeButton(uri: track.uri, revealed: hovering)
            Text(Format.duration(ms: Double(track.durationMs)))
                .monospacedDigit().floeFont(size: 12)
                .secondaryText(lit: hovering)
                .frame(width: scale(44), alignment: .trailing)
            Group {
                // Built only while hovered: a menu per visible row costs layout.
                if hovering {
                    Menu {
                        TrackMenuItems(track: track)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .transition(.opacity)
                } else {
                    Color.clear
                }
            }
            .frame(width: scale(22))
        }
        .padding(.horizontal, scale.plate)
        .frame(height: scale(56))
        .opacity(playable ? 1 : 0.4)
        .background { highlight(isCurrent: isCurrent) }
        .contentShape(Rectangle())
        .onHover(perform: pointer)
        // No focus rings on the row's buttons unless Full Keyboard Access needs
        // them: each is an AppKit view, and every view added as a row scrolls in
        // makes AppKit re-walk the window's regions.
        .focusEffectDisabled(!NSApplication.shared.isFullKeyboardAccessEnabled)
        #if SCROLL_BENCHMARK
        // Where the row is, for the benchmark's pointer sweeping over a resting list.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            ScrollProbe.rowFrames[entry.id] = ($0, pointer)
        }
        // The benchmark's stand-in for a pointer resting over the list.
        .onGeometryChange(for: Bool.self) { proxy in
            ScrollProbe.pointer.map { proxy.frame(in: .global).contains($0) } ?? false
        } action: { under in
            guard ScrollProbe.pointer != nil else { return }
            pointer(under)
            if under { ScrollProbe.hovers += 1 }
        }
        #endif
        // Quick in, a little slower out, so a fast sweep down the list leaves a
        // short soft wake instead of flicker.
        .floeHover(hovering)
        .floeAnimation(value: isCurrent, duration: 0.2)
        .onTapGesture(count: 2) { if playable { play() } }
        .contextMenu { TrackMenuItems(track: track) }
        .onAppear { library.requestLikedState(track.uri) }
        // A row scrolled away under a resting pointer may never hear the exit.
        .onDisappear {
            pointer(false)
            #if SCROLL_BENCHMARK
            ScrollProbe.rowFrames[entry.id] = nil
            #endif
        }
    }

    /// Rows passing under a resting pointer mid-scroll stay dark; the one it
    /// rests on lights up once the list stops. A row the pointer only crosses
    /// stays dark too (`ListMotion.dwell`). Leaving is never held back.
    private func pointer(_ inside: Bool) {
        if inside, let motion {
            if motion.isMoving {
                motion.hold(entry.id, light)
            } else if !hovering {
                motion.enter(entry.id, light)
            }
            return
        }
        motion?.release(entry.id)
        if hovering != inside { hovering = inside }
    }

    private func light() {
        hovering = true
        #if SCROLL_BENCHMARK
        ScrollProbe.lit += 1
        #endif
    }

    /// The playing row keeps its selection; any other row fills in a soft wash,
    /// tinted lightly toward the cover, that settles in from just under full size.
    /// A hairline acknowledges the pointer on either.
    ///
    /// Flat colours and a gradient view under a clip, never a gradient-filled
    /// shape: SwiftUI draws those on the CPU into a bitmap the size of the row,
    /// again on every frame the wash fades. Dragging the pointer down the list
    /// spent 15 ms a frame on that and on text changing colour, with the main
    /// thread (and the live background that draws on it) at a standstill.
    private func highlight(isCurrent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: scale(TrackRow.radius), style: .continuous)
        let tint = palette.accent.mix(with: .white, by: 0.55)
        return ZStack {
            shape.fill(Theme.selection).opacity(isCurrent ? 1 : 0)
            LinearGradient(colors: [tint.opacity(0.11), Theme.hover], startPoint: .leading, endPoint: .trailing)
                .clipShape(shape)
                .opacity(hovering && !isCurrent ? 1 : 0)
                .scaleEffect(hovering || still ? 1 : 0.985)
            shape.strokeBorder(.white.opacity(0.05))
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering || still ? 1 : 0.985)
        }
    }

    /// The number gives way to a play glyph that sharpens into focus. Both stay
    /// in place so a quick in-and-out retargets instead of stacking transitions;
    /// only the visible one takes clicks and VoiceOver focus.
    private func leading(isCurrent: Bool, playable: Bool) -> some View {
        let loading = isCurrent && player.isLoading
        let glyph = hovering && playable && !loading
        return ZStack {
            // One opacity over opaque text: the number's dimness (40% unless it's
            // the playing row's) and its fade under the pointer.
            resting(isCurrent: isCurrent, loading: loading)
                .opacity(glyph ? 0 : (isCurrent ? 1 : 0.4))
                .scaleEffect(glyph && !still ? 0.75 : 1)
                .blur(radius: glyph && !still ? 2 : 0)
                .accessibilityHidden(glyph)
            if playable {
                let pauses = isCurrent && player.isPlaying
                Button(action: isCurrent ? player.togglePlayPause : play) {
                    Image(systemName: pauses ? "pause.fill" : "play.fill")
                        .floeFont(size: 12)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: scale(24), height: scale(24))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.floe)
                .accessibilityLabel(pauses ? Text("Pause") : Text("Play"))
                .opacity(glyph ? 1 : 0)
                .scaleEffect(glyph || still ? 1 : 0.7)
                .blur(radius: glyph || still ? 0 : 2)
                .allowsHitTesting(glyph)
                .accessibilityHidden(!glyph)
            }
        }
    }

    @ViewBuilder
    private func resting(isCurrent: Bool, loading: Bool) -> some View {
        if loading {
            ProgressView().controlSize(.mini)
        } else if isCurrent && player.isPlaying {
            LoopingSymbol.playing(pointSize: scale.text(11), color: palette.highlight, running: !still)
        } else {
            Text("\(number)")
                .monospacedDigit().floeFont(size: 12)
                .foregroundStyle(isCurrent ? palette.highlight : .white)
        }
    }
}

extension View {
    /// Secondary text, brighter while its row is hovered. White text behind an
    /// opacity, not a colour that changes: a colour animating re-draws the text
    /// on every frame, an opacity only fades its layer.
    func secondaryText(lit: Bool = false, bright: Bool = false) -> some View {
        foregroundStyle(.white).opacity(bright ? 1 : (lit ? 0.82 : 0.62))
    }
}

/// "Artist, Artist" where each name opens the artist page.
struct ArtistLinks: View {
    let artists: [ArtistRef]
    /// 12 pt (Compact) unless given.
    var font: Font? = nil
    /// Set while the surrounding row is hovered.
    var lit = false
    @Environment(Navigator.self) private var navigator
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                if index > 0 { Text(", ").secondaryText(lit: lit) }
                LinkText(artist.name, lit: lit) {
                    if let id = artist.id { navigator.push(.artist(id)) }
                }
            }
        }
        .font(font ?? scale.font(size: 12))
        .lineLimit(1)
    }
}

/// Secondary text that underlines on hover and acts as a link.
struct LinkText: View {
    let text: String
    /// Set while the surrounding row is hovered.
    var lit = false
    let action: () -> Void
    @ViewState private var hovering = false

    init(_ text: String, lit: Bool = false, action: @escaping () -> Void) {
        self.text = text
        self.lit = lit
        self.action = action
    }

    var body: some View {
        Text(text)
            .underline(hovering)
            .secondaryText(lit: lit, bright: hovering)
            .lineLimit(1)
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

/// Text that brightens and underlines under the pointer and acts as a link,
/// keeping whatever colour it has at rest.
struct TitleLink: View {
    let text: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Text(text)
            .underline(hovering)
            .brightness(hovering ? 0.18 : 0)
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .floeHover(hovering)
            .accessibilityAddTraits(.isLink)
            .accessibilityAction { action() }
    }
}

struct LikeButton: View {
    @Environment(\.coverPalette) private var palette
    let uri: String
    /// The symbol's size in Compact points; the button scales it.
    var size: CGFloat = 13
    /// The side of the square that takes the click, in Compact points.
    var side: CGFloat = 22
    /// Track rows keep an empty star out of sight until hovered; a filled one
    /// always shows. Their menus carry the same action for keyboard and VoiceOver.
    var revealed = true
    @Environment(LibraryModel.self) private var library
    @ReducedMotion private var reduceMotion
    /// Bounces on the user's click, not when liked state arrives or the track changes.
    @ViewState private var presses = 0
    @Environment(\.interfaceScale) private var scale
    @Environment(\.listMotion) private var listMotion

    var body: some View {
        let liked = library.isLiked(uri) ?? false
        #if SCROLL_BENCHMARK
        let _ = ScrollProbe.likes += 1
        #endif
        Button {
            presses += 1
            Task { await library.toggleLike(uri) }
        } label: {
            Image(systemName: liked ? "star.fill" : "star")
                .floeFont(size: size)
                // A symbol swap animates whatever the transaction says; mid-scroll,
                // liked state arriving for each new row would start one per row.
                .contentTransition(listMotion?.isMoving == true ? .identity : .symbolEffect(.replace))
                .symbolEffect(.bounce, value: reduceMotion ? 0 : presses)
                .foregroundStyle(liked ? palette.highlight : Theme.tertiary)
                .frame(width: scale(side), height: scale(side))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(liked || revealed ? 1 : 0)
        .disabled(!uri.hasPrefix("spotify:track:"))
        .help(liked ? "Remove from Liked Songs" : "Save to Liked Songs")
    }
}

/// Shared by the row "…" menu and the context menu.
struct TrackMenuItems: View {
    let track: Track
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button("Add to Queue") { player.addToQueue(track.uri) }
            .disabled(!track.isCatalogTrack)
        if track.uri.hasPrefix("spotify:track:") {
            let title: LocalizedStringKey = library.isLiked(track.uri) == true
                ? "Remove from Liked Songs" : "Save to Liked Songs"
            Button(title) { Task { await library.toggleLike(track.uri) } }
        }
        Divider()
        if let album = track.album {
            Button("Go to Album") { navigator.push(.album(album.id)) }
        }
        ForEach(track.artists.filter { $0.id != nil }) { artist in
            Button("Go to \(artist.name)") { navigator.push(.artist(artist.id!)) }
        }
        if let id = track.id {
            Divider()
            CopySongLinkButton(id: id)
        }
    }
}

/// Copies the song's open.spotify.com link, for pasting anywhere.
struct CopySongLinkButton: View {
    let id: String

    var body: some View {
        Button("Copy Song Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("https://open.spotify.com/track/\(id)", forType: .string)
        }
    }
}

extension Navigator {
    /// librespot doesn't report the album ID; look it up when asked.
    func openAlbum(of track: TrackInfo, api: WebAPI) {
        guard let id = track.uri.split(separator: ":").last.map(String.init) else { return }
        Task {
            if let album = try? await api.track(id).album { push(.album(album.id)) }
        }
    }
}
