import SwiftUI

/// Toolbar above a track list: "Find in playlist" and sort.
struct ListTools: View {
    @Binding var filter: String
    @Binding var sort: TrackSort
    var prompt: LocalizedStringKey = "Find in playlist"

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                TextField(prompt, text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.tertiary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 220)
            .background(.white.opacity(0.07), in: Capsule())

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
    @ViewState private var filter = ""
    @ViewState private var sort = TrackSort.custom

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let playlist {
                header(playlist)
                if !library.canListItems(of: playlist) {
                    MessageView(systemImage: "lock",
                                message: String(localized: "Spotify only lets developer apps list the songs of playlists you own or collaborate on. Play still works."))
                }
            } else if error == nil {
                LoadingView()
            }
            if let error {
                MessageView(systemImage: "exclamationmark.triangle", message: error)
                if playlist == nil {
                    PlayPill { player.play(PlayRequest(contextURI: "spotify:playlist:\(id)")) }
                        .frame(maxWidth: .infinity)
                }
            }
            if !entries.isEmpty {
                ListTools(filter: $filter, sort: $sort)
                TrackListView(entries: sort.apply(entries.filtered(filter)), play: play,
                              onReachEnd: { Task { await loadNextPage() } })
            } else if let playlist, library.canListItems(of: playlist), nextOffset == nil, error == nil {
                MessageView(systemImage: "music.note.list", message: String(localized: "This playlist is empty."))
            }
            if loadingPage { LoadingView() }
        }
        .task(id: id) { await load() }
        .onChange(of: sort) { Task { await loadAll() } }
        .onChange(of: filter) { Task { await loadAll() } }
    }

    private func header(_ playlist: PlaylistRef) -> some View {
        var parts = [playlist.owner.displayName ?? playlist.owner.id]
        if let count = playlist.itemCount { parts.append(String(localized: "\(count) songs")) }
        if nextOffset == nil, !entries.isEmpty {
            parts.append(Format.total(ms: entries.reduce(0) { $0 + $1.track.durationMs }))
        }
        let description = Format.plainText(playlist.description)
        return PageHeader(
            badge: "Playlist",
            title: playlist.name,
            subtitle: ([description].filter { !$0.isEmpty } + [parts.joined(separator: " · ")]).joined(separator: "\n")
        ) {
            cover(playlist)
        } actions: {
            PlayPill { playFromStart(shuffled: false) }
            IconButton(systemImage: "shuffle", size: 16, help: "Shuffle play") { playFromStart(shuffled: true) }
            IconButton(systemImage: library.isPinned(playlist.id) ? "pin.fill" : "pin", size: 15,
                       active: library.isPinned(playlist.id), help: "Pin to sidebar") {
                library.togglePin(playlist.id)
            }
        }
    }

    @ViewBuilder
    private func cover(_ playlist: PlaylistRef) -> some View {
        if let images = playlist.images, !images.isEmpty {
            ArtworkView(images: images, size: 200, cornerRadius: 12)
        } else {
            MosaicCover(albums: entries.compactMap(\.track.album), size: 200)
        }
    }

    private func load() async {
        playlist = nil
        entries = []
        nextOffset = 0
        error = nil
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
            error = String(localized: "Spotify doesn't share this playlist with developer apps, but you can play it.")
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
        while nextOffset != nil, error == nil {
            await loadNextPage()
        }
    }

    private func play(_ entry: TrackEntry) {
        guard let playlist else { return }
        player.play(PlayRequest(contextURI: playlist.uri, startURI: entry.track.uri))
    }

    private func playFromStart(shuffled: Bool) {
        guard let playlist else { return }
        if player.shuffle != shuffled { player.toggleShuffle() }
        player.play(PlayRequest(contextURI: playlist.uri))
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
        VStack(alignment: .leading, spacing: 22) {
            if let album {
                PageHeader(badge: album.albumType == "single" ? "Single" : "Album", title: album.name,
                           subtitle: subtitle(album)) {
                    ArtworkView(images: album.images, size: 200, cornerRadius: 12)
                } actions: {
                    PlayPill { playFromStart(shuffled: false) }
                    IconButton(systemImage: "shuffle", size: 16, help: "Shuffle play") { playFromStart(shuffled: true) }
                }
                HStack(spacing: 4) {
                    Text("By").foregroundStyle(Theme.secondary)
                    ArtistLinks(artists: album.artists, font: .system(size: 13, weight: .semibold))
                }
                .font(.system(size: 13))
                TrackListView(entries: entries, showCover: false, showAlbum: false, numbering: .trackNumber) { entry in
                    player.play(PlayRequest(contextURI: album.uri, startURI: entry.track.uri))
                }
            } else if let error {
                MessageView(systemImage: "exclamationmark.triangle", message: error)
            } else {
                LoadingView()
            }
        }
        .task(id: id) { await load() }
    }

    private func subtitle(_ album: Album) -> String {
        var parts = [album.artists.map(\.name).joined(separator: ", ")]
        if let year = album.ref.year { parts.append(year) }
        parts.append(String(localized: "\(album.totalTracks ?? entries.count) songs"))
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
        if player.shuffle != shuffled { player.toggleShuffle() }
        player.play(PlayRequest(contextURI: album.uri))
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
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(badge: "Playlist", title: String(localized: "Liked Songs"),
                       subtitle: total.map { String(localized: "\($0) songs") } ?? " ") {
                LikedCover(size: 200)
            } actions: {
                PlayPill { playFromStart(shuffled: false) }
                IconButton(systemImage: "shuffle", size: 16, help: "Shuffle play") { playFromStart(shuffled: true) }
            }
            if let error { MessageView(systemImage: "exclamationmark.triangle", message: error) }
            if !entries.isEmpty {
                ListTools(filter: $filter, sort: $sort, prompt: "Find in Liked Songs")
                TrackListView(entries: sort.apply(entries.filtered(filter)), play: play,
                              onReachEnd: { Task { await loadNextPage() } })
            }
            if loadingPage { LoadingView() }
        }
        .task(id: library.likedRevision) { await reload() }
        .onChange(of: sort) { Task { await loadAll() } }
        .onChange(of: filter) { Task { await loadAll() } }
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
        while nextOffset != nil, error == nil {
            await loadNextPage()
        }
    }

    private func play(_ entry: TrackEntry) {
        guard let contextURI else { return }
        player.play(PlayRequest(contextURI: contextURI, startURI: entry.track.uri))
    }

    private func playFromStart(shuffled: Bool) {
        guard let contextURI else { return }
        if player.shuffle != shuffled { player.toggleShuffle() }
        player.play(PlayRequest(contextURI: contextURI))
    }
}

struct LikedCover: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size > 60 ? 12 : 5)
            .fill(LinearGradient(colors: [Color(red: 0.27, green: 0.2, blue: 0.75), Theme.accent.opacity(0.85)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "star.fill").font(.system(size: size * 0.32)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}
