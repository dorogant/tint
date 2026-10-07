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
        VStack(alignment: .leading, spacing: 28) {
            Text(greeting)
                .font(.system(size: 30, weight: .heavy))
                .padding(.horizontal, 10)
            if let error = library.loadError {
                MessageView(systemImage: "exclamationmark.triangle", message: error)
            }
            Shelf(title: "Recently played", items: recent) { recent in
                Card(images: recent.item.track.album?.images, title: recent.item.track.name,
                     subtitle: recent.item.track.artistLine) {
                    play(recent.item)
                }
            }
            Shelf(title: "Your top artists", items: library.topArtists) { artist in
                Card(images: artist.images, title: artist.name, subtitle: String(localized: "Artist"),
                     circle: true) {
                    navigator.push(.artist(artist.id))
                }
            }
            Shelf(title: "Your playlists", items: library.playlists) { playlist in
                Card(images: playlist.images, title: playlist.name,
                     subtitle: playlist.owner.displayName ?? "") {
                    navigator.push(.playlist(playlist.id))
                }
            }
            Shelf(title: "Saved albums", items: library.savedAlbums) { album in
                Card(images: album.images, title: album.name,
                     subtitle: album.artists?.map(\.name).joined(separator: ", ") ?? "") {
                    navigator.push(.album(album.id))
                }
            }
        }
    }

    private var greeting: String {
        let name = library.profile?.displayName.map { ", \($0)" } ?? ""
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return String(localized: "Good morning\(name)")
        case 12..<18: return String(localized: "Good afternoon\(name)")
        default: return String(localized: "Good evening\(name)")
        }
    }

    /// Resume in the context it was played from, else its album.
    private func play(_ item: PlayHistory) {
        let context = item.context?.uri ?? item.track.album?.uri
        if let context {
            player.play(PlayRequest(contextURI: context, startURI: item.track.uri))
        } else {
            player.play(PlayRequest(tracks: [item.track.uri]))
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
        VStack(alignment: .leading, spacing: 26) {
            if let artist {
                // No "Popular" list: Development Mode removed top tracks. Playing the
                // artist context still starts with them (Spirc resolves it).
                PageHeader(badge: "Artist", title: artist.name,
                           subtitle: (artist.genres ?? []).prefix(3).joined(separator: " · ")) {
                    ArtworkView(images: artist.images, size: 200, circle: true)
                } actions: {
                    PlayPill { player.play(PlayRequest(contextURI: artist.uri)) }
                }
                Shelf(title: "Discography", items: albums) { album in
                    Card(images: album.images, title: album.name,
                         subtitle: [album.year, album.albumType?.capitalized].compactMap { $0 }.joined(separator: " · ")) {
                        navigator.push(.album(album.id))
                    }
                }
            } else if let error {
                MessageView(systemImage: "exclamationmark.triangle", message: error)
            } else {
                LoadingView()
            }
        }
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
        VStack(alignment: .leading, spacing: 26) {
            if let error = search.error {
                MessageView(systemImage: "exclamationmark.triangle", message: error)
            }
            if let results = search.results {
                if !search.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Songs") {
                            if search.canLoadMoreSongs {
                                Button("Show more") { Task { await search.loadMoreSongs(library.api) } }
                                    .buttonStyle(.plain)
                                    .disabled(search.isLoadingMore)
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        let entries = search.songs.enumerated().map { TrackEntry(id: $0, track: $1) }
                        TrackListView(entries: entries) { entry in
                            // Play the results as a list so next/previous move through them.
                            player.play(PlayRequest(tracks: search.songs.map(\.uri), startURI: entry.track.uri))
                        }
                    }
                }
                Shelf(title: "Artists", items: results.artists?.items ?? []) { artist in
                    Card(images: artist.images, title: artist.name, subtitle: String(localized: "Artist"),
                         circle: true) { navigator.push(.artist(artist.id)) }
                }
                Shelf(title: "Albums", items: results.albums?.items ?? []) { album in
                    Card(images: album.images, title: album.name,
                         subtitle: album.artists?.map(\.name).joined(separator: ", ") ?? "") {
                        navigator.push(.album(album.id))
                    }
                }
                Shelf(title: "Playlists", items: results.playlists?.items ?? []) { playlist in
                    Card(images: playlist.images, title: playlist.name,
                         subtitle: playlist.owner.displayName ?? "") {
                        navigator.push(.playlist(playlist.id))
                    }
                }
            } else if search.isSearching {
                LoadingView()
            } else {
                MessageView(systemImage: "magnifyingglass",
                            message: String(localized: "Search for songs, artists, albums and playlists."))
            }
        }
        .task(id: search.text) { await search.search(library.api) }
    }
}

/// The pill search field from the reference UI.
struct SearchField: View {
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
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? Theme.accent.opacity(0.6) : .clear))
        .onAppear { focused = true }
    }
}
