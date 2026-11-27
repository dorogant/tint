import SwiftUI

// MARK: - Home

/// Built from the user's own data (Spotify removed browse/recommendations for new apps).
/// Each section has its own shape, from most to least immediate: tiles to jump
/// back into, recent songs as rows, top artists as small circles, then saved
/// albums. Playlists already fill the sidebar, so they appear here only as
/// tiles, or as the last shelf when there are no saved albums. Nothing shows
/// twice: later sections skip what a tile already offers.
struct HomeView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    /// Tiles and song rows share these columns, so their artwork lines up.
    @ViewState private var columns = 4
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let shortcuts = Array(HomeShortcut.recent(in: library).prefix(columns * 2))
        let shown = Set(shortcuts.map(\.id))
        let songs = recentSongs(excluding: shown)
        let factor = scale.factor
        VStack(alignment: .leading, spacing: scale.sectionGap) {
            VStack(alignment: .leading, spacing: scale(20)) {
                Text(greeting)
                    .floeFont(size: 32, weight: .heavy)
                    .tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)
                    .reveal("greeting")
                if !shortcuts.isEmpty {
                    LazyVGrid(columns: grid, spacing: scale(12)) {
                        ForEach(shortcuts) { item in
                            ShortcutTile(item: item) { navigator.push(item.route) } play: {
                                player.play(PlayRequest(contextURI: item.id))
                            }
                        }
                    }
                    .reveal("shortcuts", order: 1)
                }
            }
            if let error = library.loadError {
                MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange,
                            actionTitle: "Try Again") { Task { await library.refresh() } }
            }
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: scale.headerGap) {
                    SectionHeader("Recently played")
                    LazyVGrid(columns: grid, spacing: 2 * scale.plate) {
                        ForEach(songs, id: \.track.uri) { item in
                            SongTile(track: item.track) { play(item) }
                        }
                    }
                }
                .reveal("recent", order: 2)
            }
            Shelf(title: "Your top artists", items: library.shownTopArtists.filter { !shown.contains($0.uri) }) { artist in
                Card(images: artist.images, title: artist.name, circle: true, size: 128, actions: [
                    CardAction(title: "Hide from Top Artists", systemImage: "eye.slash") { library.hide(artist) },
                ]) {
                    navigator.push(.artist(artist.id))
                } play: {
                    player.play(PlayRequest(contextURI: artist.uri))
                }
            }
            .floeAnimation(value: library.hiddenArtists)
            .reveal("artists", order: 3)
            if !library.savedAlbums.isEmpty {
                Shelf(title: "Saved albums", items: library.savedAlbums.filter { !shown.contains($0.uri) }) { album in
                    Card(images: album.images, title: album.name,
                         subtitle: album.artists?.map(\.name).joined(separator: ", ") ?? "") {
                        navigator.push(.album(album.id))
                    } play: {
                        player.play(PlayRequest(contextURI: album.uri))
                    }
                }
                .reveal("albums", order: 4)
            } else {
                Shelf(title: "Your playlists", items: library.playlists.filter { !shown.contains($0.uri) }) { playlist in
                    Card(images: playlist.images, title: playlist.name,
                         subtitle: playlist.owner.displayName ?? "") {
                        navigator.push(.playlist(playlist.id))
                    } play: {
                        player.play(PlayRequest(contextURI: playlist.uri))
                    }
                }
                .reveal("playlists", order: 4)
            }
        }
        .revealScope()
        // Larger tiles need more room per column, so measure in Compact points.
        .onGeometryChange(for: Int.self) { Self.columns(for: $0.size.width / factor) } action: { columns = $0 }
    }

    private var grid: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: scale(12), alignment: .leading), count: columns)
    }

    /// Four across a wide window, three at the default size, two at the smallest (Compact points).
    nonisolated static func columns(for width: CGFloat) -> Int {
        width >= 1000 ? 4 : (width >= 640 ? 3 : 2)
    }

    /// Up to three full rows of distinct songs. A song whose album is already
    /// a tile above would only repeat its cover, so it's left out.
    private func recentSongs(excluding shown: Set<String>) -> [PlayHistory] {
        var seen = Set<String>()
        let songs = library.recent
            .filter { !shown.contains($0.track.album?.uri ?? "") && seen.insert($0.track.uri).inserted }
            .prefix(columns * 3)
        // A ragged last row reads as unfinished; keep a short history whole.
        let whole = songs.count < columns ? songs.count : songs.count - songs.count % columns
        return Array(songs.prefix(whole))
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

/// Somewhere to jump back into: a playlist, album, artist or Liked Songs.
private struct HomeShortcut: Identifiable {
    enum Kind { case playlist, album, artist, liked }
    /// The context URI, which is also what Play starts.
    let id: String
    let kind: Kind
    let route: Route
    let title: String
    let images: [SpotifyImage]?

    /// What was played from most recently, newest first, then pinned and
    /// other playlists to fill the grid. Songs played without a context stand
    /// in for their album; contexts Tint can't name (editorial playlists) are skipped.
    @MainActor
    static func recent(in library: LibraryModel, limit: Int = 8) -> [HomeShortcut] {
        var result: [HomeShortcut] = []
        var seen = Set<String>()
        func add(_ shortcut: HomeShortcut?) {
            guard let shortcut, result.count < limit, seen.insert(shortcut.id).inserted else { return }
            result.append(shortcut)
        }
        for item in library.recent where result.count < limit {
            guard let context = item.context else {
                add(item.track.album.map(HomeShortcut.init))
                continue
            }
            if context.uri.hasSuffix(":collection") {
                add(HomeShortcut(id: context.uri, kind: .liked, route: .songs,
                                 title: L10n.string("Liked Songs"), images: nil))
            } else {
                switch context.type {
                case "playlist": add(library.playlists.first { $0.uri == context.uri }.map(HomeShortcut.init))
                case "album": add(item.track.album.flatMap { $0.uri == context.uri ? HomeShortcut($0) : nil })
                case "artist": add(library.topArtists.first { $0.uri == context.uri }.map(HomeShortcut.init))
                default: break
                }
            }
        }
        // Every playlist can be hundreds; stop as soon as the grid is full.
        for playlist in [library.pinnedPlaylists, library.playlists].joined() {
            guard result.count < limit else { break }
            add(HomeShortcut(playlist))
        }
        return result
    }

    init(id: String, kind: Kind, route: Route, title: String, images: [SpotifyImage]?) {
        self.id = id
        self.kind = kind
        self.route = route
        self.title = title
        self.images = images
    }

    init(_ playlist: PlaylistRef) {
        self.init(id: playlist.uri, kind: .playlist, route: .playlist(playlist.id), title: playlist.name,
                  images: playlist.images)
    }

    init(_ album: AlbumRef) {
        self.init(id: album.uri, kind: .album, route: .album(album.id), title: album.name, images: album.images)
    }

    init(_ artist: Artist) {
        self.init(id: artist.uri, kind: .artist, route: .artist(artist.id), title: artist.name, images: artist.images)
    }
}

/// A compact tile: the cover flush to its leading edge, the title beside it.
/// Under the pointer it brightens and a Play button rises in at its end; the
/// tile itself opens the item. While its context plays, the title takes the
/// accent and the playing bars show.
private struct ShortcutTile: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @Environment(\.interfaceScale) private var scale
    @ReducedMotion private var still
    let item: HomeShortcut
    let open: () -> Void
    let play: () -> Void
    @ViewState private var hovering = false
    @ViewState private var pressed = false

    /// In Compact points.
    static let height: CGFloat = 56

    private var height: CGFloat { scale(Self.height) }

    var body: some View {
        let playing = player.contextURI == item.id && player.isPlaying
        let shape = RoundedRectangle(cornerRadius: scale(Card.radius), style: .continuous)
        Button(action: open) {
            HStack(spacing: scale(12)) {
                cover
                Text(item.title)
                    .floeFont(size: 13, weight: .semibold)
                    .foregroundStyle(playing ? palette.highlight : .white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            // Room for the Play button, so the title never runs under it.
            .padding(.trailing, scale(52))
            .frame(height: height)
            .background(.white.opacity(hovering ? 0.12 : 0.07))
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(hovering ? 0.08 : 0.04)))
            .contentShape(shape)
        }
        .buttonStyle(CardPressStyle(pressed: $pressed))
        .overlay(alignment: .trailing) {
            ZStack {
                if hovering {
                    HoverPlayButton(diameter: scale(32), action: play)
                        .transition(HoverPlayButton.transition(still: still))
                } else if playing {
                    LoopingSymbol.playing(pointSize: scale.text(11), color: palette.highlight, running: !still)
                        .transition(.opacity)
                }
            }
            .frame(width: scale(32))
            .padding(.trailing, scale(12))
        }
        .scaleEffect(pressed && !still ? 0.98 : 1)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .floeState(value: playing, duration: 0.3)
        .animation(still ? FloeMotion.fade : FloeMotion.press(pressed), value: pressed)
        .modifier(PlayMenu(play: play))
    }

    @ViewBuilder private var cover: some View {
        switch item.kind {
        case .liked:
            LikedCover(size: height, cornerRadius: 0)
        case .artist:
            // Artists keep their round portrait, inset like an avatar.
            ArtworkView(images: item.images, size: height - scale(12), circle: true)
                .frame(width: height, height: height)
        case .playlist, .album:
            ArtworkView(images: item.images, size: height, cornerRadius: 0)
        }
    }
}

/// A recently played song: cover, title and artists. A click plays it where
/// it was played from; under the pointer a plate grows in around it (reaching
/// past the column, so the covers stay on the grid) and the cover shows Play.
private struct SongTile: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    let track: Track
    let play: () -> Void
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    private static let radius: CGFloat = 6

    var body: some View {
        let current = player.displayTrack?.uri == track.uri
        let radius = scale(Self.radius)
        Button(action: play) {
            HStack(spacing: scale(12)) {
                ArtworkView(images: track.album?.images, size: scale(40), cornerRadius: radius)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(.black.opacity(0.4))
                            .overlay(Image(systemName: "play.fill").floeFont(size: 13).foregroundStyle(.white))
                            .opacity(hovering ? 1 : 0)
                    }
                VStack(alignment: .leading, spacing: scale(2)) {
                    Text(track.name)
                        .floeFont(size: 13, weight: .medium)
                        .foregroundStyle(current ? palette.highlight : .white)
                    Text(track.artistLine)
                        .floeFont(size: 12)
                        .foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .hoverPlate(hovering, radius: radius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.floeRow)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .contextMenu { TrackMenuItems(track: track) }
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
    @ViewState private var popular = PopularSongs()
    /// Five at first, as on Spotify, so the albums stay on the first screen.
    @ViewState private var shown = ArtistView.firstSongs
    @ViewState private var loadingMore = false
    @ViewState private var error: String?
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.sectionGap) {
            if let artist {
                // Development Mode refuses an artist's top tracks, so Popular is
                // what search ranks first for the artist (`WebAPI.songs(by:offset:)`).
                // Play still hands Spotify the artist, which starts with the real ones.
                PageHeader(badge: "Artist", title: artist.name,
                           detail: (artist.genres ?? []).prefix(3).map(\.localizedCapitalized).joined(separator: " · ")) {
                    ArtworkView(images: artist.images, size: scale(200), circle: true).coverGlow(artist.images)
                } actions: {
                    PlayPill { player.play(PlayRequest(contextURI: artist.uri)) }
                }
                .reveal("header")
                if !popular.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: scale.headerGap) {
                        SectionHeader(title: "Popular") {
                            if shown < popular.tracks.count || popular.hasMore {
                                ShowMoreButton(busy: loadingMore) { Task { await showMoreSongs(by: artist) } }
                            }
                        }
                        let entries = popular.tracks.prefix(shown).enumerated().map { TrackEntry(id: $0, track: $1) }
                        TrackListView(entries: entries) { entry in
                            // Play the list from this song, so next and previous move through
                            // it, on into the songs loaded but not shown yet.
                            player.play(PlayRequest(tracks: popular.tracks.map(\.uri), startURI: entry.track.uri),
                                        selectedTrack: entry.track)
                        }
                    }
                    .reveal("popular", order: 1)
                }
                Shelf(title: "Discography", items: albums) { album in
                    Card(images: album.images, title: album.name,
                         subtitle: [album.year, album.albumType?.capitalized].compactMap { $0 }.joined(separator: " · ")) {
                        navigator.push(.album(album.id))
                    } play: {
                        player.play(PlayRequest(contextURI: album.uri))
                    }
                }
                .reveal("discography", order: 2)
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

    /// The page shows once its songs are in too (one more round trip), so
    /// Discography doesn't appear and then move down to make room for them.
    /// Without them, the page is as it was: header and albums.
    private func load() async {
        artist = nil
        error = nil
        popular = PopularSongs()
        shown = Self.firstSongs
        async let discography = library.api.artistAlbums(id)
        do {
            let loaded = try await library.api.artist(id)
            let songs = try? await library.api.extending(PopularSongs(), by: loaded)
            albums = (try? await discography) ?? []
            guard !Task.isCancelled else { return }
            popular = songs ?? PopularSongs()
            artist = loaded
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static let firstSongs = 5

    /// The first press shows the songs that came with the page; later ones ask for more.
    private func showMoreSongs(by artist: Artist) async {
        guard !loadingMore else { return }
        if shown >= popular.tracks.count, popular.hasMore {
            loadingMore = true
            defer { loadingMore = false }
            guard let more = try? await library.api.extending(popular, by: artist), self.artist?.id == artist.id else { return }
            popular = more
        }
        shown = popular.tracks.count
    }
}
