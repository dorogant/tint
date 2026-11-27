import Foundation

/// A mix's view of the user: Tint's own listening history and the Spotify
/// library, through the Web API.
struct MixSpotifyLibrary: MixLibrary {
    let api: WebAPI
    let history: ListeningHistory

    func listened(since date: Date) async -> [String] {
        await history.plays(since: date).compactMap(\.trackID)
    }

    func heard() async -> Set<String> {
        Set(await history.heard().compactMap(MixSong.trackID(in:)))
    }

    func recentlyPlayed() async throws -> [String] {
        try await api.recentlyPlayed().compactMap(\.track.id)
    }

    func likedSongs(offset: Int) async throws -> (tracks: [Track], total: Int) {
        let page = try await api.savedTracks(offset: offset)
        return (page.items.map(\.track), page.total ?? page.items.count)
    }

    func liked(among ids: [String]) async throws -> Set<String> {
        let flags = try await api.libraryContains(ids.map { "spotify:track:\($0)" })
        return Set(flags.filter(\.value).keys.compactMap(MixSong.trackID(in:)))
    }

    func track(_ id: String) async throws -> Track {
        try await api.track(id)
    }
}

extension PlayerModel: MixPlayer {
    var playingURI: String? { track?.uri }

    /// One song by itself: with Spotify Soloist that needs no playback
    /// permission, and what follows comes from the queue.
    func start(_ song: MixSong, details: Track?) -> Bool {
        play(PlayRequest(tracks: [song.uri]), selectedTrack: details)
        return lastError == nil
    }

    func queue(_ song: MixSong) -> Bool {
        guard isConnected else { return false }
        addToQueue(song.uri)
        return true
    }

    /// What a mix follows: the song the engine confirmed, not one only selected.
    var mixNowPlaying: MixNowPlaying? {
        guard let track else { return nil }
        return MixNowPlaying(uri: track.uri, title: track.name, artists: track.artists.map(\.name), isPlaying: isPlaying,
                             atEnd: track.durationMs > 0 && positionMs(at: Date()) >= track.durationMs - 3000)
    }
}
