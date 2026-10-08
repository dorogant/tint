import AppKit
import SwiftUI

// MARK: - Home

/// Built from the user's own data (Spotify removed browse/recommendations for new apps).
struct HomeView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator

    private struct Recent: Identifiable {
        let id: String
        let item: PlayHistory
    }

    private var recent: [Recent] {
        var seen = Set<String>()
        return library.recent
            .filter { seen.insert($0.track.uri).inserted }
            .prefix(16)
            .map { Recent(id: $0.track.uri, item: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(greeting)
                .font(.system(size: 32, weight: .heavy))
                .tracking(-0.6)
                .padding(.horizontal, 10)
                .accessibilityAddTraits(.isHeader)
                .reveal("greeting")
            if let error = library.loadError {
                MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange,
                            actionTitle: "Try Again") { Task { await library.refresh() } }
            }
            // Recently played cards play straight away; the rest open, with Play on hover.
            Shelf(title: "Recently played", items: recent) { recent in
                Card(images: recent.item.track.album?.images, title: recent.item.track.name,
                     subtitle: recent.item.track.artistLine) {
                    play(recent.item)
                }
            }
            .reveal("recent", order: 1)
            Shelf(title: "Your top artists", items: library.topArtists) { artist in
                Card(images: artist.images, title: artist.name, subtitle: L10n.string("Artist"),
                     circle: true) {
                    navigator.push(.artist(artist.id))
                } play: {
                    player.play(PlayRequest(contextURI: artist.uri))
                }
            }
            .reveal("artists", order: 2)
            Shelf(title: "Your playlists", items: library.playlists) { playlist in
                Card(images: playlist.images, title: playlist.name,
                     subtitle: playlist.owner.displayName ?? "") {
                    navigator.push(.playlist(playlist.id))
                } play: {
                    player.play(PlayRequest(contextURI: playlist.uri))
                }
            }
            .reveal("playlists", order: 3)
            Shelf(title: "Saved albums", items: library.savedAlbums) { album in
                Card(images: album.images, title: album.name,
                     subtitle: album.artists?.map(\.name).joined(separator: ", ") ?? "") {
                    navigator.push(.album(album.id))
                } play: {
                    player.play(PlayRequest(contextURI: album.uri))
                }
            }
            .reveal("albums", order: 4)
        }
        .revealScope()
    }

    private var greeting: String {
        let name = library.profile?.displayName.map { ", \($0)" } ?? ""
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return L10n.string("Good morning\(name)")
        case 12..<18: return L10n.string("Good afternoon\(name)")
        default: return L10n.string("Good evening\(name)")
        }
    }

    /// Resume in the context it was played from, else its album.
    private func play(_ item: PlayHistory) {
        let context = item.context?.uri ?? item.track.album?.uri
        if let context {
            player.play(PlayRequest(contextURI: context, startURI: item.track.uri), selectedTrack: item.track)
        } else {
            player.play(PlayRequest(tracks: [item.track.uri]), selectedTrack: item.track)
        }
    }
}

// MARK: - Artist

struct ArtistView: View {
    let id: String

    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @ViewState private var artist: Artist?
    @ViewState private var albums: [AlbumRef] = []
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let artist {
                // No "Popular" list: Development Mode removed top tracks. Playing the
                // artist context still starts with them (Spirc resolves it).
                PageHeader(badge: "Artist", title: artist.name,
                           detail: (artist.genres ?? []).prefix(3).map(\.localizedCapitalized).joined(separator: " · ")) {
                    ArtworkView(images: artist.images, size: 200, circle: true).coverGlow(artist.images)
                } actions: {
                    PlayPill { player.play(PlayRequest(contextURI: artist.uri)) }
                }
                .reveal("header")
                Shelf(title: "Discography", items: albums) { album in
                    Card(images: album.images, title: album.name,
                         subtitle: [album.year, album.albumType?.capitalized].compactMap { $0 }.joined(separator: " · ")) {
                        navigator.push(.album(album.id))
                    } play: {
                        player.play(PlayRequest(contextURI: album.uri))
                    }
                }
                .reveal("discography", order: 1)
            } else if let error {
                MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange,
                            actionTitle: "Try Again") { Task { await load() } }
            } else {
                PagePlaceholder(circle: true)
            }
        }
        .revealScope()
        .task(id: id) { await load() }
    }

    private func load() async {
        artist = nil
        error = nil
        async let discography = library.api.artistAlbums(id)
        do {
            let loaded = try await library.api.artist(id)
            albums = (try? await discography) ?? []
            artist = loaded
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(SearchModel.self) private var search

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let error = search.error {
                MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange)
            }
            if let results = search.results {
                if !search.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Songs") {
                            if search.canLoadMoreSongs {
                                ShowMoreButton(busy: search.isLoadingMore) {
                                    Task { await search.loadMoreSongs(library.api) }
                                }
                            }
                        }
                        let entries = search.songs.enumerated().map { TrackEntry(id: $0, track: $1) }
                        TrackListView(entries: entries) { entry in
                            // Play the results as a list so next/previous move through them.
                            player.play(PlayRequest(tracks: search.songs.map(\.uri), startURI: entry.track.uri), selectedTrack: entry.track)
                        }
                    }
                    .reveal("songs")
                }
                Shelf(title: "Artists", items: results.artists?.items ?? []) { artist in
                    Card(images: artist.images, title: artist.name, subtitle: L10n.string("Artist"),
                         circle: true) {
                        navigator.push(.artist(artist.id))
                    } play: {
                        player.play(PlayRequest(contextURI: artist.uri))
                    }
                }
                .reveal("artists", order: 1)
                Shelf(title: "Albums", items: results.albums?.items ?? []) { album in
                    Card(images: album.images, title: album.name,
                         subtitle: album.artists?.map(\.name).joined(separator: ", ") ?? "") {
                        navigator.push(.album(album.id))
                    } play: {
                        player.play(PlayRequest(contextURI: album.uri))
                    }
                }
                .reveal("albums", order: 2)
                Shelf(title: "Playlists", items: results.playlists?.items ?? []) { playlist in
                    Card(images: playlist.images, title: playlist.name,
                         subtitle: playlist.owner.displayName ?? "") {
                        navigator.push(.playlist(playlist.id))
                    } play: {
                        player.play(PlayRequest(contextURI: playlist.uri))
                    }
                }
                .reveal("playlists", order: 3)
            } else if search.isSearching {
                LoadingView()
            } else {
                MessageView(systemImage: "magnifyingglass",
                            message: L10n.string("Search for songs, artists, albums and playlists."))
            }
        }
        .revealScope()
        .task(id: search.text) { await search.search(library.api) }
    }
}

/// A quiet capsule beside the Songs header; dims while the next page loads.
private struct ShowMoreButton: View {
    let busy: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Show more")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? .white : Theme.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.white.opacity(hovering ? 0.12 : 0.07), in: Capsule())
        }
        .buttonStyle(.floe)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .onHover { hovering = $0 }
        .floeHover(hovering)
    }
}

/// The pill search field from the reference UI. Choosing Search puts the cursor
/// here; the accent ring follows focus.
struct SearchField: View {
    @Environment(\.coverPalette) private var palette
    @Environment(Navigator.self) private var navigator
    @Bindable var search: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField("What do you want to play?", text: $search.text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !search.text.isEmpty {
                Button { search.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Clear")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .glassControl(in: .capsule)
        .overlay(Capsule().strokeBorder(focused ? palette.accent.opacity(0.6) : .clear))
        .floeState(value: focused)
        .task(id: navigator.searchFocusRequest) { await takeRequestedFocus() }
    }

    /// Focus set while the field is still being inserted is dropped before its
    /// text field joins the window, so keep asking for a few frames until it
    /// sticks. Only explicit requests count: re-renders and Back never steal focus.
    private func takeRequestedFocus() async {
        guard navigator.searchFocusRequest != navigator.searchFocusHandled else { return }
        navigator.searchFocusHandled = navigator.searchFocusRequest
        if focused {
            // Asked again while typing (⌘F): select the query, ready to replace.
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
            return
        }
        for _ in 0..<12 where !Task.isCancelled && !focused {
            focused = true
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}
