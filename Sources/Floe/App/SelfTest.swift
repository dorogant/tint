import Foundation
import MediaPlayer

/// Scripted end-to-end check for development, enabled with `-FloeSelfTest YES`.
/// Logs to stdout. Plays music; don't touch playback while it runs.
/// `-FloeSelfTestWrites YES` also likes and then unlikes one song (no net change).
/// `-FloeSelfTestTour YES` also visits each page; with `-FloeSnapshotDir <dir>` it
/// snapshots them too.
@MainActor
enum SelfTest {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "FloeSelfTest") }
    private static var allowWrites: Bool { UserDefaults.standard.bool(forKey: "FloeSelfTestWrites") }

    static func run(player: PlayerModel, library: LibraryModel, navigator: Navigator, search: SearchModel,
                    lyrics: LyricsModel, appearance: CoverAppearance) async {
        let start = Date()
        let forward = player.core.onEvent
        player.core.onEvent = { event in
            let t = String(format: "%6.2f", Date().timeIntervalSince(start))
            say("  t=\(t) event \(String(describing: event).prefix(90))")
            forward?(event)
        }

        say("waiting for playback session and library")
        guard await wait(timeout: 600, {
            player.isConnected && library.connection == .connected && library.profile != nil
        }) else { return finish(false, "not connected") }
        say("library: \(library.playlists.count) playlists, \(library.recent.count) recently played, "
            + "\(library.topArtists.count) top artists, \(library.savedAlbums.count) saved albums")
        let ram0 = MemoryFootprint.currentMB
        var ok = true

        if let own = library.playlists.first(where: { library.canListItems(of: $0) && ($0.itemCount ?? 0) > 0 }) {
            let page = try? await library.api.playlistItems(own.id, offset: 0)
            say("own playlist: \(page?.items.count ?? -1) tracks")
            ok = check(ok, page?.items.isEmpty == false, "own playlist items")
        }
        var found: SearchResults?
        do {
            found = try await library.api.search("never gonna give you up")
            say("search: \(found?.tracks?.items.count ?? 0) songs, \(found?.artists?.items.count ?? 0) artists, "
                + "\(found?.playlists?.items.count ?? 0) playlists")
            ok = check(ok, found?.tracks?.items.isEmpty == false, "search")
        } catch {
            ok = check(ok, false, "search: \(error)")
        }

        // Context playback: Liked Songs, starting at its second song.
        guard let profile = library.profile,
              let liked = try? await library.api.savedTracks(offset: 0), liked.items.count >= 3
        else { return finish(false, "needs at least 3 liked songs") }
        let songs = liked.items.map(\.track)
        player.play(PlayRequest(contextURI: "spotify:user:\(profile.id):collection", startURI: songs[1].uri))
        // Wait for this exact song: Connect can push other state (another device) meanwhile.
        guard await wait(timeout: 30, { player.isPlaying && player.track?.name == songs[1].name }) else {
            return finish(false, "Liked Songs didn't start at \(songs[1].name); playing \(player.track?.name ?? "nothing")")
        }
        say("Liked Songs from #2: \(songs[1].name)")

        player.next()
        guard await wait(timeout: 15, { player.isPlaying && player.track?.name == songs[2].name }) else {
            return finish(false, "next didn't move to \(songs[2].name); playing \(player.track?.name ?? "nothing")")
        }
        say("next: \(songs[2].name)")

        player.previous()
        guard await wait(timeout: 15, { player.isPlaying && player.track?.name == songs[1].name }) else {
            return finish(false, "previous didn't go back; playing \(player.track?.name ?? "nothing")")
        }
        say("previous: \(songs[1].name)")

        // Audio is really flowing, and Control Center shows the track.
        let frames = player.core.takeStats().frames_rendered
        try? await Task.sleep(for: .seconds(3))
        let rendered = Double(player.core.takeStats().frames_rendered - frames) / 44_100
        say(String(format: "rendered %.2f s of audio in 3 s", rendered))
        ok = check(ok, rendered > 2.5, "audio flowing")
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let title = info?[MPMediaItemPropertyTitle] as? String
        let artwork = info?[MPMediaItemPropertyArtwork] != nil
        say("Now Playing: \(title ?? "nil"), artwork \(artwork ? "yes" : "no"), "
            + "state \(MPNowPlayingInfoCenter.default().playbackState == .playing ? "playing" : "other")")
        ok = check(ok, title == player.track?.name && artwork, "Now Playing info")

        if allowWrites, let candidate = found?.tracks?.items.first(where: \.isCatalogTrack) {
            let before = (try? await library.api.libraryContains([candidate.uri]))?[candidate.uri]
            if before == false {
                await library.toggleLike(candidate.uri)
                let liked = (try? await library.api.libraryContains([candidate.uri]))?[candidate.uri]
                await library.toggleLike(candidate.uri)
                let after = (try? await library.api.libraryContains([candidate.uri]))?[candidate.uri]
                say("like toggle: \(liked == true ? "liked" : "NOT liked"), then \(after == false ? "unliked" : "STILL liked")")
                ok = check(ok, liked == true && after == false, "like toggle")
            } else {
                say("like toggle skipped: test song is already liked")
            }
        }

        if UserDefaults.standard.bool(forKey: "FloeSelfTestPhase3") {
            let lyricSearch = try? await library.api.search("Get Lucky Daft Punk")
            guard let candidate = lyricSearch?.tracks?.items.first(where: {
                $0.artists.contains { $0.name == "Daft Punk" } && (360000...380000).contains($0.durationMs)
            }) else { player.pause(); return finish(false, "lyrics fixture song not found") }
            player.play(PlayRequest(tracks: [candidate.uri]))
            navigator.surface = .nowPlaying
            let started = await wait(timeout: 20) { player.isPlaying && player.track?.uri == candidate.uri }
            ok = check(ok, started, "Phase 3 playback")
            say("lyrics signature: \(player.track?.name ?? ""), \(player.track?.artistLine ?? ""), album \(player.track?.album ?? ""), \(player.track?.durationMs ?? 0) ms")
            let loaded = await wait(timeout: 25) {
                guard lyrics.trackURI == candidate.uri, appearance.coverURL == player.track?.coverURL else { return false }
                if case .loaded = lyrics.state { return appearance.image != nil && appearance.background != nil }
                if case .failed = lyrics.state { return true }
                return false
            }
            ok = check(ok, loaded && appearance.image != nil && appearance.background != nil, "cover and background")
            if case let .loaded(.synced(lines)) = lyrics.state {
                say("Phase 3: synced lyrics available (\(lines.count) lines; text stays in live view)")
                ok = check(ok, lines.count > 3, "multiple synced lines")
                if let line = lines.first(where: { $0.time > 10 }) {
                    player.seek(toMs: line.time * 1000)
                    try? await Task.sleep(for: .seconds(1))
                    ok = check(ok, abs(player.positionMs(at: Date()) / 1000 - line.time) < 3, "seek to lyric timing")
                }
            } else {
                ok = check(ok, false, "expected synced lyrics for the fixture song")
            }
            try? await Task.sleep(for: .seconds(20))
            say(String(format: "Now Playing during playback: %.1f MB", MemoryFootprint.currentMB))
        }
        player.pause()
        say(String(format: "RAM after playback checks: %.1f MB", MemoryFootprint.currentMB))
        if Snapshot.isEnabled || UserDefaults.standard.bool(forKey: "FloeSelfTestTour") {
            let rounds = max(UserDefaults.standard.integer(forKey: "FloeSelfTestTourRounds"), 1)
            for round in 1...rounds {
                await tour(library: library, navigator: navigator, search: search)
                say(String(format: "tour %d: %.1f MB", round, MemoryFootprint.currentMB))
            }
        }
        say(String(format: "RAM (phys_footprint): %.1f MB connected, %.1f MB after browsing + playback",
                   ram0, MemoryFootprint.currentMB))
        if UserDefaults.standard.bool(forKey: "FloeVisualTest") {
            lyrics.showVisualTestFixture()
            navigator.surface = .nowPlaying
            player.seek(toMs: 9000)
            try? await Task.sleep(for: .seconds(2))
            Snapshot.capture("7-now-playing-synthetic")
            navigator.surface = .lyrics
            try? await Task.sleep(for: .seconds(1))
            Snapshot.capture("8-lyrics-synthetic")
            navigator.surface = .nowPlaying
        }
        finish(ok, ok ? "all checks passed" : "a check failed")
    }

    /// Visits each page (and snapshots it when enabled).
    private static func tour(library: LibraryModel, navigator: Navigator, search: SearchModel) async {
        func visit(_ route: Route, _ name: String) async {
            navigator.select(route)
            try? await Task.sleep(for: .seconds(3)) // data + artwork
            Snapshot.capture(name)
        }
        await visit(.home, "1-home")
        await visit(.songs, "2-liked-songs")
        if let own = library.playlists.first(where: { library.canListItems(of: $0) }) {
            await visit(.playlist(own.id), "3-playlist")
        }
        if let album = library.savedAlbums.first {
            await visit(.album(album.id), "4-album")
        }
        if let artist = library.topArtists.first {
            await visit(.artist(artist.id), "5-artist")
        }
        search.text = "daft punk"
        await visit(.search, "6-search")
        navigator.select(.home)
    }

    private static func check(_ ok: Bool, _ condition: Bool, _ name: String) -> Bool {
        if !condition { say("  ✗ \(name)") }
        return ok && condition
    }

    private static func wait(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private static func say(_ message: String) {
        print("[selftest] \(message)")
        fflush(stdout)
    }

    private static func finish(_ passed: Bool, _ detail: String) {
        say("\(passed ? "PASS" : "FAIL"): \(detail)")
    }
}
