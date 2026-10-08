import SwiftUI

/// Toolbar above a track list: "Find in playlist" and sort. The field
/// brightens under the pointer and takes an accent ring while focused.
struct ListTools: View {
    @Environment(\.coverPalette) private var palette
    @Binding var filter: String
    @Binding var sort: TrackSort
    var prompt: LocalizedStringKey = "Find in playlist"
    @FocusState private var focused: Bool
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(focused ? Theme.secondary : Theme.tertiary)
                TextField(prompt, text: $filter).textFieldStyle(.plain).focused($focused)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.tertiary)
                        .help("Clear")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(width: 220, height: 28)
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
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort by")
        }
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

// MARK: - Playlist

struct PlaylistView: View {
    let id: String

    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @ViewState private var playlist: PlaylistRef?
    @ViewState private var entries: [TrackEntry] = []
    @ViewState private var nextOffset: Int? = 0
    @ViewState private var loadingPage = false
    @ViewState private var error: String?
    /// False for answers a retry won't change (Spotify hides the playlist).
    @ViewState private var retryable = true
    @ViewState private var filter = ""
    @ViewState private var sort = TrackSort.custom

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
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
                TrackListView(entries: sort.apply(entries.filtered(filter)), play: play,
                              onReachEnd: { Task { await loadNextPage() } })
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
            ArtworkView(images: images, size: 200, cornerRadius: 12).coverGlow(images)
        } else {
            let albums = entries.compactMap(\.track.album)
            MosaicCover(albums: albums, size: 200).coverGlow(albums.first?.images)
        }
    }

    private func load() async {
        playlist = nil
        entries = []
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
            nextOffset = page.next == nil ? nil : offset + 100
        } catch {
            self.error = error.localizedDescription
            nextOffset = nil
        }
    }

    /// Sorting and filtering need every page.
    private func loadAll() async {
        guard sort != .custom || !filter.isEmpty else { return }
        while nextOffset != nil, error == nil, !Task.isCancelled {
            // Another request may be fetching a page. Yield instead of spinning
            // on the main actor and preventing that request from completing.
            if loadingPage {
                try? await Task.sleep(for: .milliseconds(50))
            } else {
                await loadNextPage()
            }
        }
    }

    private func play(_ entry: TrackEntry) {
        guard let playlist else { return }
        player.play(PlayRequest(contextURI: playlist.uri, startURI: entry.track.uri), selectedTrack: entry.track)
    }

    private func playFromStart(shuffled: Bool) {
        guard let playlist else { return }
        player.playContext(playlist.uri, shuffled: shuffled)
    }
}

/// 2×2 grid of album covers, for playlists without their own image.
struct MosaicCover: View {
    let albums: [AlbumRef]
    let size: CGFloat

    var body: some View {
        var seen = Set<String>()
        let unique = albums.filter { seen.insert($0.id).inserted }.prefix(4)
        return Group {
            if unique.count < 4 {
                ArtworkView(images: unique.first?.images, size: size, cornerRadius: 12)
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
                .clipShape(RoundedRectangle(cornerRadius: 12))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let album {
                PageHeader(badge: album.albumType == "single" ? "Single" : "Album", title: album.name,
                           detail: detail(album)) {
                    ArtworkView(images: album.images, size: 200, cornerRadius: 12).coverGlow(album.images)
                } byline: {
                    HStack(spacing: 4) {
                        Text("By").foregroundStyle(Theme.secondary)
                        ArtistLinks(artists: album.artists, font: .system(size: 13, weight: .semibold))
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
    @ViewState private var total: Int?
    @ViewState private var nextOffset: Int? = 0
    @ViewState private var loadingPage = false
    @ViewState private var error: String?
    @ViewState private var filter = ""
    @ViewState private var sort = TrackSort.custom

    private var contextURI: String? {
        library.profile.map { "spotify:user:\($0.id):collection" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(badge: "Playlist", title: L10n.string("Liked Songs"),
                       detail: total.map { L10n.string("\($0) songs") } ?? " ") {
                LikedCover(size: 200).coverGlow(color: LikedCover.violet)
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
                TrackListView(entries: sort.apply(entries.filtered(filter)), play: play,
                              onReachEnd: { Task { await loadNextPage() } })
                    .reveal("tracks", order: 2)
            }
            if loadingPage { LoadingView() }
        }
        .revealScope()
        .task(id: library.likedRevision) { await reload() }
        .task(id: "\(sort.rawValue):\(filter)") { await loadAll() }
    }

    private func reload() async {
        entries = []
        nextOffset = 0
        error = nil
        await loadNextPage()
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
            library.markLiked(page.items.map(\.track.uri))
            nextOffset = page.next == nil ? nil : offset + 50
        } catch {
            self.error = error.localizedDescription
            nextOffset = nil
        }
    }

    private func loadAll() async {
        guard sort != .custom || !filter.isEmpty else { return }
        while nextOffset != nil, error == nil, !Task.isCancelled {
            // Another request may be fetching a page. Yield instead of spinning
            // on the main actor and preventing that request from completing.
            if loadingPage {
                try? await Task.sleep(for: .milliseconds(50))
            } else {
                await loadNextPage()
            }
        }
    }

    private func play(_ entry: TrackEntry) {
        guard let contextURI else { return }
        player.play(PlayRequest(contextURI: contextURI, startURI: entry.track.uri), selectedTrack: entry.track)
    }

    private func playFromStart(shuffled: Bool) {
        guard let contextURI else { return }
        player.playContext(contextURI, shuffled: shuffled)
    }
}

struct LikedCover: View {
    @Environment(\.coverPalette) private var palette
    let size: CGFloat
    /// Defaults to the radius artwork of this size uses.
    var cornerRadius: CGFloat?
    static let violet = Color(red: 0.27, green: 0.2, blue: 0.75)

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius ?? (size > 60 ? 12 : 5))
            .fill(LinearGradient(colors: [Self.violet, palette.accent.opacity(0.85)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "star.fill").font(.system(size: size * 0.32)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}
