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

    var body: some View {
        LazyVStack(spacing: 0) {
            header
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
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
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 28)
            if showCover { Color.clear.frame(width: 40, height: 1) }
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            if showAlbum { Text("Album").frame(maxWidth: .infinity, alignment: .leading) }
            Color.clear.frame(width: 22, height: 1)
            Image(systemName: "clock").frame(width: 44, alignment: .trailing)
            Color.clear.frame(width: 22, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.panelStroke).frame(height: 1) }
        .padding(.bottom, 6)
    }
}

struct TrackRow: View {
    @Environment(\.coverPalette) private var palette
    let entry: TrackEntry
    let number: Int
    let showCover: Bool
    let showAlbum: Bool
    let play: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    /// Local to the row, so hovering redraws one row rather than the list.
    @ViewState private var hovering = false

    /// With Reduce Motion the row still lights up, it just doesn't move or scale.
    private var still: Bool { reduceMotion || systemReduceMotion }

    /// Quick in, a little slower out, so a fast sweep down the list leaves a
    /// short soft wake instead of flicker. Springs retarget from wherever they
    /// are, so reversing half-way never jumps. Reduce Motion gets a dissolve.
    private var hoverAnimation: Animation {
        still ? .easeOut(duration: hovering ? 0.15 : 0.22) : .spring(duration: hovering ? 0.17 : 0.24, bounce: 0)
    }

    var body: some View {
        let track = entry.track
        let isCurrent = player.displayTrack?.uri == track.uri
        let playable = track.isPlayable != false && track.isCatalogTrack

        HStack(spacing: 12) {
            leading(isCurrent: isCurrent, playable: playable).frame(width: 28)
            if showCover {
                // The cover lifts a touch toward the pointer, as cards do; the
                // shadow only deepens, so Reduce Motion keeps it.
                ArtworkView(images: track.album?.images, size: 40, cornerRadius: 5)
                    .shadow(color: .black.opacity(hovering ? 0.45 : 0), radius: hovering ? 6 : 0, y: 2)
                    .scaleEffect(hovering && !still ? 1.03 : 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(track.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isCurrent ? palette.highlight : .white)
                        .lineLimit(1)
                    if track.explicit == true {
                        Text("E").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3)
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
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(hovering ? litSecondary : Theme.secondary)
                .frame(width: 44, alignment: .trailing)
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
            .frame(width: 22)
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .opacity(playable ? 1 : 0.4)
        .background { highlight(isCurrent: isCurrent) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(hoverAnimation, value: hovering)
        .floeAnimation(value: isCurrent, duration: 0.2)
        .onTapGesture(count: 2) { if playable { play() } }
        .contextMenu { TrackMenuItems(track: track) }
        .onAppear { library.requestLikedState(track.uri) }
        // A row scrolled away under a resting pointer may never hear the exit.
        .onDisappear { hovering = false }
    }

    /// The playing row keeps its selection; any other row fills in a soft wash,
    /// tinted lightly toward the cover, that settles in from just under full size.
    /// A top-lit hairline acknowledges the pointer on either.
    private func highlight(isCurrent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let tint = palette.accent.mix(with: .white, by: 0.55)
        return ZStack {
            shape.fill(Theme.selection).opacity(isCurrent ? 1 : 0)
            ZStack {
                shape.fill(LinearGradient(colors: [tint.opacity(0.11), Theme.hover],
                                          startPoint: .leading, endPoint: .trailing))
                    .opacity(isCurrent ? 0 : 1)
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02)],
                                                  startPoint: .top, endPoint: .bottom))
            }
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
            resting(isCurrent: isCurrent, loading: loading)
                .opacity(glyph ? 0 : 1)
                .scaleEffect(glyph && !still ? 0.75 : 1)
                .blur(radius: glyph && !still ? 2 : 0)
                .accessibilityHidden(glyph)
            if playable {
                let pauses = isCurrent && player.isPlaying
                Button(action: isCurrent ? player.togglePlayPause : play) {
                    Image(systemName: pauses ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24, height: 24)
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
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
                .foregroundStyle(palette.highlight)
                .symbolEffect(.variableColor.iterative, isActive: !still)
        } else {
            Text("\(number)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(isCurrent ? palette.highlight : Theme.tertiary)
        }
    }
}

/// Secondary text brightens toward white while its row is hovered.
private let litSecondary = Color.white.opacity(0.82)

/// "Artist, Artist" where each name opens the artist page.
struct ArtistLinks: View {
    let artists: [ArtistRef]
    var font: Font = .system(size: 12)
    /// Set while the surrounding row is hovered.
    var lit = false
    @Environment(Navigator.self) private var navigator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                if index > 0 { Text(", ").foregroundStyle(lit ? litSecondary : Theme.secondary) }
                LinkText(artist.name, lit: lit) {
                    if let id = artist.id { navigator.push(.artist(id)) }
                }
            }
        }
        .font(font)
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
            .foregroundStyle(hovering ? .white : (lit ? litSecondary : Theme.secondary))
            .lineLimit(1)
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

struct LikeButton: View {
    @Environment(\.coverPalette) private var palette
    let uri: String
    var size: CGFloat = 13
    /// Track rows keep an empty star out of sight until hovered; a filled one
    /// always shows. Their menus carry the same action for keyboard and VoiceOver.
    var revealed = true
    @Environment(LibraryModel.self) private var library

    var body: some View {
        let liked = library.isLiked(uri) ?? false
        Button {
            Task { await library.toggleLike(uri) }
        } label: {
            Image(systemName: liked ? "star.fill" : "star")
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: liked)
                .foregroundStyle(liked ? palette.highlight : Theme.tertiary)
                .frame(width: 22, height: 22)
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
            Button("Copy Song Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://open.spotify.com/track/\(id)", forType: .string)
            }
        }
    }
}
