import Foundation
import Observation
import os

/// The user's library as the UI sees it: profile, playlists (with pins), Home
/// shelves and which tracks are liked. Backed by the Web API.
@MainActor
@Observable
final class LibraryModel {
    enum Connection: Equatable { case checking, disconnected, connecting, connected, failed(String) }

    private(set) var connection: Connection = .checking
    private(set) var profile: UserProfile?
    private(set) var playlists: [PlaylistRef] = []
    private(set) var pinnedIDs: [String]
    private(set) var recent: [PlayHistory] = []
    private(set) var topArtists: [Artist] = []
    private(set) var savedAlbums: [AlbumRef] = []
    private(set) var loadError: String?
    /// Bumped when Liked Songs changes, so its page reloads.
    private(set) var likedRevision = 0

    @ObservationIgnored let api: WebAPI
    /// Known liked state per track URI; missing means "not checked yet".
    private var liked: [String: Bool] = [:]
    @ObservationIgnored private var likedQueue: Set<String> = []
    @ObservationIgnored private var likedFlush: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "library")

    init(api: WebAPI) {
        self.api = api
        pinnedIDs = UserDefaults.standard.stringArray(forKey: "pinnedPlaylists") ?? []
    }

    var pinnedPlaylists: [PlaylistRef] {
        pinnedIDs.compactMap { id in playlists.first { $0.id == id } }
    }

    func start() async {
        guard connection == .checking else { return }
        await api.user.setAuthorizationExpiredHandler { [weak self] in
            self?.connection = .failed(L10n.string("Spotify authorization expired. Reconnect your library."))
        }
        connection = await api.user.isAuthorized ? .connected : .disconnected
        if connection == .connected { await refresh() }
    }

    /// One-time browser consent for Floe's own developer app (the Web API client).
    func connect() async {
        connection = .connecting
        do {
            try await api.user.authorize()
            connection = .connected
            await refresh()
        } catch is CancellationError {
            connection = .disconnected
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        await api.user.signOut()
        connection = .disconnected
        profile = nil
        playlists = []
        recent = []
        topArtists = []
        savedAlbums = []
        liked = [:]
    }

    func refresh() async {
        loadError = nil
        async let me = api.me()
        async let lists = api.myPlaylists()
        async let history = api.recentlyPlayed()
        async let artists = api.topArtists()
        async let albums = api.savedAlbums()
        do {
            profile = try await me
            playlists = try await lists
        } catch TokenError.notAuthorized {
            connection = .disconnected
            return
        } catch {
            loadError = error.localizedDescription
        }
        // Home shelves are optional: show what loads.
        recent = (try? await history) ?? []
        topArtists = (try? await artists) ?? []
        savedAlbums = (try? await albums) ?? []
    }

    /// Development Mode lists tracks only for playlists the user owns or collaborates on.
    func canListItems(of playlist: PlaylistRef) -> Bool {
        playlist.owner.id == profile?.id || playlist.collaborative == true
    }

    // MARK: - Pins

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    func togglePin(_ id: String) {
        if let index = pinnedIDs.firstIndex(of: id) {
            pinnedIDs.remove(at: index)
        } else {
            pinnedIDs.append(id)
        }
        UserDefaults.standard.set(pinnedIDs, forKey: "pinnedPlaylists")
    }

    // MARK: - Liked songs

    /// nil until checked; rows call `requestLikedState` when they appear.
    func isLiked(_ uri: String) -> Bool? { liked[uri] }

    func markLiked(_ uris: [String]) {
        for uri in uris { liked[uri] = true }
    }

    /// Batches visible rows into `contains` calls (≤40 URIs each).
    func requestLikedState(_ uri: String) {
        guard uri.hasPrefix("spotify:track:"), liked[uri] == nil, connection == .connected else { return }
        likedQueue.insert(uri)
        guard likedFlush == nil else { return }
        likedFlush = Task {
            try? await Task.sleep(for: .milliseconds(250))
            let batch = Array(likedQueue)
            likedQueue = []
            likedFlush = nil
            do {
                for (uri, flag) in try await api.libraryContains(batch) { liked[uri] = flag }
            } catch {
                log.error("Liked check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Optimistic toggle; reverts if Spotify refuses.
    func toggleLike(_ uri: String) async {
        let newValue = !(liked[uri] ?? false)
        liked[uri] = newValue
        do {
            if newValue {
                try await api.saveToLibrary([uri])
            } else {
                try await api.removeFromLibrary([uri])
            }
            likedRevision += 1
        } catch {
            liked[uri] = !newValue
            loadError = error.localizedDescription
        }
    }
}
