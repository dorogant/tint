import SwiftUI

/// Toolbar above a track list: "Find in playlist" and sort. The field
/// brightens under the pointer and takes an accent ring while focused.
private struct ListTools: View {
    @Environment(\.coverPalette) private var palette
    @Binding var filter: String
    @Binding var sort: TrackSort
    var prompt: LocalizedStringKey = "Find in playlist"
    @FocusState private var focused: Bool
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: scale(10)) {
            HStack(spacing: scale(6)) {
                Image(systemName: "magnifyingglass").foregroundStyle(focused ? Theme.secondary : Theme.tertiary)
                TextField(prompt, text: $filter).textFieldStyle(.plain).focused($focused)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.tertiary)
                        .help("Clear")
                }
            }
            .floeFont(size: 12)
            .padding(.horizontal, scale(10))
            .frame(width: scale(220), height: scale(28))
            .background(.white.opacity(focused ? 0.1 : (hovering ? 0.09 : 0.07)), in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? palette.accent.opacity(0.5) : .clear))
            .onHover { hovering = $0 }
            .floeHover(hovering)
            .floeState(value: focused)

            Spacer()
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(TrackSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(sort.label, systemImage: "arrow.up.arrow.down")
                    .floeFont(size: 12)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort by")
        }
    }
}

/// Sorting and filtering need every page. Another request may be fetching
/// one; yield instead of spinning on the main actor and keeping it from finishing.
@MainActor
private func loadEveryPage(more: () -> Bool, busy: () -> Bool, next: () async -> Void) async {
    while more(), !Task.isCancelled {
        if busy() { try? await Task.sleep(for: .milliseconds(50)) } else { await next() }
    }
}

/// The rows a long list shows, filtered and sorted. Worked out again only when
/// the tracks, the filter or the order change, not on every redraw: sorting
/// 5,000 liked songs by title takes ~20 ms, and the page redraws twice for each
/// page that arrives while sorting loads them all. Not observed; reading it redraws nothing.
@MainActor
private final class ShownTracks {
    private var key: (revision: Int, filter: String, sort: TrackSort)?
    private var rows: [TrackEntry] = []

    /// `revision` changes whenever `entries` do.
    func rows(of entries: [TrackEntry], revision: Int, filter: String, sort: TrackSort) -> [TrackEntry] {
        if let key, key == (revision, filter, sort) { return rows }
        rows = sort.apply(entries.filtered(filter))
        key = (revision, filter, sort)
        return rows
    }
}

extension [TrackEntry] {
    func filtered(_ text: String) -> [TrackEntry] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self }
        return filter {
            $0.track.name.localizedCaseInsensitiveContains(query)
                || $0.track.artistLine.localizedCaseInsensitiveContains(query)
                || ($0.track.album?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

extension PlayRequest {
    /// Plays `entry`, then the rows after it. A list in its own order plays as
    /// its context; filtered or sorted it plays as the songs on screen, which
    /// the context doesn't know: the songs a filter hid came up next. The songs
    /// go along in both cases, because Spotify Soloist can start an album or a
    /// playlist at a chosen song but not Liked Songs (`PlaybackStart`).
    static func rows(_ rows: [TrackEntry], from entry: TrackEntry, context: String, rearranged: Bool) -> PlayRequest {
        let songs = rows.filter(\.track.isCatalogTrack)
        guard let index = songs.firstIndex(where: { $0.id == entry.id }) else {
            return PlayRequest(contextURI: context, startURI: entry.track.uri)
        }
        let window = PlaybackStart.window(of: songs.map(\.track.uri), around: index)
        return PlayRequest(contextURI: rearranged ? nil : context, tracks: window.uris,
                           startURI: entry.track.uri, startIndex: window.position)
    }
}

// MARK: - Playlist

struct PlaylistView: View {
    let id: String

    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @ViewState private var playlist: PlaylistRef?
    @ViewState private var entries: [TrackEntry] = []
    /// Bumped with every change to `entries`.
    @ViewState private var revision = 0
    @ViewState private var shown = ShownTracks()
    @ViewState private var nextOffset: Int? = 0
    @ViewState private var loadingPage = false
    @ViewState private var error: String?
    /// False for answers a retry won't change (Spotify hides the playlist).
    @ViewState private var retryable = true
    @ViewState private var filter = ""
    @ViewState private var sort = TrackSort.custom
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale(24)) {
            if let playlist {
                header(playlist).reveal("header")
                if !library.canListItems(of: playlist) {
                    MessageView(systemImage: "lock",
                                message: L10n.string("Spotify only lets developer apps list the songs of playlists you own or collaborate on. Play still works."))
                }
            } else if error == nil {
                PagePlaceholder()
            }
            if let error {
                if playlist == nil, retryable {
                    MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange,
                                actionTitle: "Try Again") { Task { await load() } }
                } else {
                    MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange)
                }
                if playlist == nil {
                    PlayPill { player.play(PlayRequest(contextURI: "spotify:playlist:\(id)")) }
                        .frame(maxWidth: .infinity)
                }
            }
            if !entries.isEmpty {
                ListTools(filter: $filter, sort: $sort).reveal("tools", order: 1)
                TrackListView(entries: shown.rows(of: entries, revision: revision, filter: filter, sort: sort),
                              play: play, onReachEnd: { Task { await loadNextPage() } })
                    .reveal("tracks", order: 2)
            } else if let playlist, library.canListItems(of: playlist), nextOffset == nil, error == nil {
                MessageView(systemImage: "music.note.list", message: L10n.string("This playlist is empty."))
            }
            if loadingPage { LoadingView() }
        }
        .revealScope()
        .task(id: id) { await load() }
        .task(id: "\(sort.rawValue):\(filter)") { await loadAll() }
    }

    private func header(_ playlist: PlaylistRef) -> some View {
        var parts = [playlist.owner.displayName ?? playlist.owner.id]
        if let count = playlist.itemCount { parts.append(L10n.string("\(count) songs")) }
        if nextOffset == nil, !entries.isEmpty {
            parts.append(Format.total(ms: entries.reduce(0) { $0 + $1.track.durationMs }))
        }
        let pinned = library.isPinned(playlist.id)
        return PageHeader(
            badge: "Playlist",
            title: playlist.name,
            subtitle: Format.plainText(playlist.description),
            detail: parts.joined(separator: " · ")
        ) {
            cover(playlist)
        } actions: {
            PlayPill { playFromStart(shuffled: false) }
            IconButton(systemImage: "shuffle", size: 16, help: "Shuffle play") { playFromStart(shuffled: true) }
            IconButton(systemImage: pinned ? "pin.fill" : "pin", size: 15,
                       active: pinned, help: pinned ? "Unpin" : "Pin to Sidebar") {
                library.togglePin(playlist.id)
            }
        }
    }

    @ViewBuilder
    private func cover(_ playlist: PlaylistRef) -> some View {
        if let images = playlist.images, !images.isEmpty {
            ArtworkView(images: images, size: scale(200), cornerRadius: scale(12)).coverGlow(images)
        } else {
            let albums = entries.compactMap(\.track.album)
            MosaicCover(albums: albums, size: scale(200)).coverGlow(albums.first?.images)
        }
    }

    private func load() async {
        playlist = nil
        entries = []
        revision += 1
        nextOffset = 0
        error = nil
        retryable = true
        do {
            let loaded = try await library.api.playlist(id)
            playlist = loaded
            if library.canListItems(of: loaded) {
                await loadNextPage()
            } else {
                nextOffset = nil
            }
        } catch let failure as WebAPI.Failure where failure.status == 404 {
            // Spotify-made (editorial/algorithmic) playlists are hidden from developer apps.
            retryable = false
            error = L10n.string("Spotify doesn't share this playlist with developer apps, but you can play it.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadNextPage() async {
        guard let offset = nextOffset, !loadingPage, let playlist else { return }
        loadingPage = true
        defer { loadingPage = false }
        do {
            let page = try await library.api.playlistItems(playlist.id, offset: offset)
            let start = entries.count
            entries += page.items.enumerated().compactMap { index, item in
                item.track.map { TrackEntry(id: start + index, track: $0, addedAt: item.addedAt) }
            }
            revision += 1
            nextOffset = page.next == nil ? nil : offset + 100
        } catch {
            self.error = error.localizedDescription
            nextOffset = nil
        }
    }

    private func loadAll() async {
        guard sort != .custom || !filter.isEmpty else { return }
        await loadEveryPage(more: { nextOffset != nil && error == nil }, busy: { loadingPage }, next: loadNextPage)
    }

    private func play(_ entry: TrackEntry) {
        guard let playlist else { return }
        let rows = shown.rows(of: entries, revision: revision, filter: filter, sort: sort)
        player.play(.rows(rows, from: entry, context: playlist.uri, rearranged: sort != .custom || !filter.isEmpty),
                    selectedTrack: entry.track)
    }

    private func playFromStart(shuffled: Bool) {
        guard let playlist else { return }
        player.playContext(playlist.uri, shuffled: shuffled)
    }
}

/// 2×2 grid of album covers, for playlists without their own image.
private struct MosaicCover: View {
    let albums: [AlbumRef]
    let size: CGFloat
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        var seen = Set<String>()
        let unique = albums.filter { seen.insert($0.id).inserted }.prefix(4)
        return Group {
            if unique.count < 4 {
                ArtworkView(images: unique.first?.images, size: size, cornerRadius: scale(12))
            } else {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(images: unique[unique.startIndex].images, size: half, cornerRadius: 0)
                        ArtworkView(images: unique[unique.startIndex + 1].images, size: half, cornerRadius: 0)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(images: unique[unique.startIndex + 2].images, size: half, cornerRadius: 0)
                        ArtworkView(images: unique[unique.startIndex + 3].images, size: half, cornerRadius: 0)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: scale(12)))
            }
        }
    }
}

// MARK: - Album

struct AlbumView: View {
    let id: String

    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @ViewState private var album: Album?
    @ViewState private var entries: [TrackEntry] = []
    @ViewState private var error: String?
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale(24)) {
            if let album {
                PageHeader(badge: album.albumType == "single" ? "Single" : "Album", title: album.name,
                           detail: detail(album)) {
                    ArtworkView(images: album.images, size: scale(200), cornerRadius: scale(12)).coverGlow(album.images)
                } byline: {
                    HStack(spacing: scale(4)) {
                        Text("By").foregroundStyle(Theme.secondary)
                        ArtistLinks(artists: album.artists, font: scale.font(size: 13, weight: .semibold))
                    }
                } actions: {
                    PlayPill { playFromStart(shuffled: false) }
                    IconButton(systemImage: "shuffle", size: 16, help: "Shuffle play") { playFromStart(shuffled: true) }
                }
                .reveal("header")
                TrackListView(entries: entries, showCover: false, showAlbum: false, numbering: .trackNumber) { entry in
                    player.play(PlayRequest(contextURI: album.uri, startURI: entry.track.uri), selectedTrack: entry.track)
                }
                .reveal("tracks", order: 1)
            } else if let error {
                MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange,
                            actionTitle: "Try Again") { Task { await load() } }
            } else {
                PagePlaceholder()
            }
        }
        .revealScope()
        .task(id: id) { await load() }
    }

    /// Year, length and running time; the artists are the byline.
    private func detail(_ album: Album) -> String {
        var parts: [String] = []
        if let year = album.ref.year { parts.append(year) }
        parts.append(L10n.string("\(album.totalTracks ?? entries.count) songs"))
        parts.append(Format.total(ms: entries.reduce(0) { $0 + $1.track.durationMs }))
        return parts.joined(separator: " · ")
    }

    private func load() async {
        album = nil
        error = nil
        do {
            let loaded = try await library.api.album(id)
            var tracks = loaded.tracks.items
            var next = loaded.tracks.next
            while next != nil {
                let page = try await library.api.albumTracks(id, offset: tracks.count)
                tracks += page.items
                next = page.next
            }
            // Album tracks come without their album; attach it for menus and Now Playing.
            entries = tracks.enumerated().map { index, track in
                TrackEntry(id: index, track: track.withAlbum(loaded.ref))
            }
            album = loaded
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func playFromStart(shuffled: Bool) {
        guard let album else { return }
        player.playContext(album.uri, shuffled: shuffled)
    }
}

extension Track {
    func withAlbum(_ album: AlbumRef) -> Track {
        Track(id: id, uri: uri, name: name, durationMs: durationMs, explicit: explicit, artists: artists,
              album: album, trackNumber: trackNumber, discNumber: discNumber, isLocal: isLocal,
              isPlayable: isPlayable)
    }
}

// MARK: - Liked Songs

struct SongsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @ViewState private var entries: [TrackEntry] = []
    /// Bumped with every change to `entries`.
    @ViewState private var revision = 0
    @ViewState private var shown = ShownTracks()
    @ViewState private var total: Int?
    @ViewState private var nextOffset: Int? = 0
    @ViewState private var loadingPage = false
    @ViewState private var error: String?
    @ViewState private var filter = ""
    @ViewState private var sort = TrackSort.custom
    /// Rows take their place in the list as their identity; songs added at the
    /// top later count down from here instead.
    @ViewState private var addedID = 0
    @ReducedMotion private var still
    @Environment(\.interfaceScale) private var scale

    private var contextURI: String? {
        library.profile.map { "spotify:user:\($0.id):collection" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale(24)) {
            PageHeader(badge: "Playlist", title: L10n.string("Liked Songs"),
                       detail: total.map { L10n.string("\($0) songs") } ?? " ") {
                LikedCover(size: scale(200)).coverGlow(color: LikedCover.violet)
            } actions: {
                PlayPill { playFromStart(shuffled: false) }
                IconButton(systemImage: "shuffle", size: 16, help: "Shuffle play") { playFromStart(shuffled: true) }
            }
            .reveal("header")
            if let error {
                MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange,
                            actionTitle: "Try Again") { Task { await reload() } }
            }
            if !entries.isEmpty {
                ListTools(filter: $filter, sort: $sort, prompt: "Find in Liked Songs").reveal("tools", order: 1)
                TrackListView(entries: shown.rows(of: entries, revision: revision, filter: filter, sort: sort),
                              play: play, onReachEnd: { Task { await loadNextPage() } })
                    .reveal("tracks", order: 2)
            }
            if loadingPage { LoadingView() }
        }
        .revealScope()
        .task(id: library.likedRevision) {
            if entries.isEmpty { await reload() } else { await reconcile() }
        }
        .task(id: "\(sort.rawValue):\(filter)") { await loadAll() }
    }

    private func reload() async {
        entries = []
        revision += 1
        nextOffset = 0
        error = nil
        await loadNextPage()
    }

    /// A song was liked or unliked while the list is up. Loading it all again
    /// emptied the page and threw the scroll back to the top, so the list is
    /// brought in line where it stands: unliked songs leave, and songs the
    /// newest page has that the list doesn't are added at the top.
    private func reconcile() async {
        guard let page = try? await library.api.savedTracks(offset: 0), !Task.isCancelled else { return }
        total = page.total
        let kept = entries.filter { library.isLiked($0.track.uri) != false }
        let known = Set(kept.map(\.track.uri))
        // Spotify's list can trail an unlike by a moment; don't bring that song back.
        let fresh = page.items.filter { !known.contains($0.track.uri) && library.isLiked($0.track.uri) != false }
        guard kept.count != entries.count || !fresh.isEmpty else { return }
        // Later pages moved by as many places as the list grew or shrank.
        if let offset = nextOffset { nextOffset = max(0, offset + fresh.count - (entries.count - kept.count)) }
        // The row leaves and the rows below close up, rather than jumping.
        withAnimation(still ? FloeMotion.fade : FloeMotion.glide) {
            entries = fresh.map { saved in
                addedID -= 1
                return TrackEntry(id: addedID, track: saved.track, addedAt: saved.addedAt)
            } + kept
            revision += 1
        }
        library.markLiked(fresh.map(\.track.uri))
    }

    private func loadNextPage() async {
        guard let offset = nextOffset, !loadingPage else { return }
        loadingPage = true
        defer { loadingPage = false }
        do {
            let page = try await library.api.savedTracks(offset: offset)
            total = page.total
            let start = entries.count
            entries += page.items.enumerated().map { index, saved in
                TrackEntry(id: start + index, track: saved.track, addedAt: saved.addedAt)
            }
            revision += 1
            library.markLiked(page.items.map(\.track.uri))
            nextOffset = page.next == nil ? nil : offset + 50
        } catch {
            self.error = error.localizedDescription
            nextOffset = nil
        }
    }

    private func loadAll() async {
        guard sort != .custom || !filter.isEmpty else { return }
        await loadEveryPage(more: { nextOffset != nil && error == nil }, busy: { loadingPage }, next: loadNextPage)
    }

    private func play(_ entry: TrackEntry) {
        guard let contextURI else { return }
        Task {
            await loadPastEnd(after: entry)
            let rows = shown.rows(of: entries, revision: revision, filter: filter, sort: sort)
            player.play(.rows(rows, from: entry, context: contextURI, rearranged: sort != .custom || !filter.isEmpty),
                        selectedTrack: entry.track)
        }
    }

    /// Spotify Soloist plays Liked Songs as the rows loaded so far
    /// (`PlayRequest.rows`), so a song among the last of them waits for the
    /// next page: otherwise the music ran out a few songs later.
    private func loadPastEnd(after entry: TrackEntry) async {
        guard player.engine == .soloist, let index = entries.firstIndex(where: { $0.id == entry.id }),
              entries.count - index <= 20 else { return }
        let loaded = entries.count
        await loadEveryPage(more: { entries.count == loaded && nextOffset != nil && error == nil },
                            busy: { loadingPage }, next: loadNextPage)
    }

    private func playFromStart(shuffled: Bool) {
        guard let contextURI else { return }
        player.playContext(contextURI, shuffled: shuffled)
    }
}

struct LikedCover: View {
    @Environment(\.coverPalette) private var palette
    @Environment(\.interfaceScale) private var scale
    /// In points, already at the interface size.
    let size: CGFloat
    /// Defaults to the radius artwork of this size uses.
    var cornerRadius: CGFloat?
    static let violet = Color(red: 0.27, green: 0.2, blue: 0.75)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? scale(size > scale(60) ? 12 : 5))
        LinearGradient(colors: [Self.violet, palette.accent.opacity(0.85)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .clipShape(shape)
            .overlay(Image(systemName: "star.fill").font(.system(size: size * 0.32)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}
