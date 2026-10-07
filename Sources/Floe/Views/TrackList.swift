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
    let entry: TrackEntry
    let number: Int
    let showCover: Bool
    let showAlbum: Bool
    let play: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @ViewState private var hovering = false

    var body: some View {
        let track = entry.track
        let isCurrent = player.track?.uri == track.uri
        let playable = track.isPlayable != false && track.isCatalogTrack

        HStack(spacing: 12) {
            leading(isCurrent: isCurrent, playable: playable).frame(width: 28)
            if showCover {
                ArtworkView(images: track.album?.images, size: 40, cornerRadius: 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(track.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : .white)
                        .lineLimit(1)
                    if track.explicit == true {
                        Text("E").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(Theme.tertiary, in: RoundedRectangle(cornerRadius: 2))
                            .foregroundStyle(.black)
                    }
                }
                ArtistLinks(artists: track.artists)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAlbum {
                Group {
                    if let album = track.album {
                        LinkText(album.name) { navigator.push(.album(album.id)) }
                    } else {
                        Text("")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LikeButton(uri: track.uri)
            Text(Format.duration(ms: Double(track.durationMs)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 44, alignment: .trailing)
            Group {
                if hovering {
                    Menu {
                        TrackMenuItems(track: track)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                } else {
                    Color.clear
                }
            }
            .frame(width: 22)
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .opacity(playable ? 1 : 0.4)
        .background(isCurrent ? Theme.selection : (hovering ? Theme.hover : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if playable { play() } }
        .contextMenu { TrackMenuItems(track: track) }
        .onAppear { library.requestLikedState(track.uri) }
    }

    @ViewBuilder
    private func leading(isCurrent: Bool, playable: Bool) -> some View {
        if hovering && playable {
            Button(action: isCurrent ? player.togglePlayPause : play) {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        } else if isCurrent && player.isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
        } else {
            Text("\(number)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(isCurrent ? Theme.accent : Theme.tertiary)
        }
    }
}

/// "Artist, Artist" where each name opens the artist page.
struct ArtistLinks: View {
    let artists: [ArtistRef]
    var font: Font = .system(size: 12)
    @Environment(Navigator.self) private var navigator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                if index > 0 { Text(", ").foregroundStyle(Theme.secondary) }
                LinkText(artist.name) {
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
    let action: () -> Void
    @ViewState private var hovering = false

    init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }

    var body: some View {
        Text(text)
            .underline(hovering)
            .foregroundStyle(hovering ? .white : Theme.secondary)
            .lineLimit(1)
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

struct LikeButton: View {
    let uri: String
    var size: CGFloat = 13
    @Environment(LibraryModel.self) private var library

    var body: some View {
        let liked = library.isLiked(uri) ?? false
        Button {
            Task { await library.toggleLike(uri) }
        } label: {
            Image(systemName: liked ? "star.fill" : "star")
                .font(.system(size: size))
                .foregroundStyle(liked ? Theme.accent : Theme.tertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!uri.hasPrefix("spotify:track:"))
        .help(liked ? "Remove from Liked Songs" : "Save to Liked Songs")
    }
}

/// Shared by the row "…" menu and the context menu.
struct TrackMenuItems: View {
    let track: Track
    @Environment(PlayerModel.self) private var player
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button("Add to Queue") { player.addToQueue(track.uri) }
            .disabled(!track.isCatalogTrack)
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
