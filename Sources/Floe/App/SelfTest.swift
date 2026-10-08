import AppKit
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
                    lyrics: LyricsModel, appearance: CoverAppearance,
                    visualization: VisualizationModel, visuals: VisualSettings, settings: AppSettings, connect: ConnectModel) async {
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
        if UserDefaults.standard.bool(forKey: "FloeSelfTestSwitching") {
            let passed = await switching(player: player, library: library, navigator: navigator)
            player.pause()
            return finish(passed, "song switching checks")
        }
        if UserDefaults.standard.bool(forKey: "FloeSelfTestDesign") {
            guard let song = try? await library.api.savedTracks(offset: 0).items.first?.track,
                  let profile = library.profile else { return finish(false, "needs a liked song") }
            player.play(PlayRequest(contextURI: "spotify:user:\(profile.id):collection", startURI: song.uri), selectedTrack: song)
            guard await wait(timeout: 20, { player.isPlaying && !player.isLoading })
            else { return finish(false, "audio did not start") }
            let passed = await phase4(player: player, navigator: navigator, lyrics: lyrics,
                                      visualization: visualization, visuals: visuals)
            if UserDefaults.standard.bool(forKey: "FloeVisualTest") {
                lyrics.showVisualTestFixture()
                player.seek(toMs: 9000)
                navigator.surface = .lyrics
                try? await Task.sleep(for: .seconds(2))
                Snapshot.capture("8-lyrics-synthetic")
                await transitions(navigator: navigator)
            }
            navigator.surface = .nowPlaying
            return finish(passed, "design and real-audio effects checks")
        }
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
        if UserDefaults.standard.bool(forKey: "FloeSelfTestPhase4") {
            ok = await phase4(player: player, navigator: navigator, lyrics: lyrics,
                              visualization: visualization, visuals: visuals) && ok
        }
        if UserDefaults.standard.bool(forKey: "FloeSelfTestPhase5") {
            ok = await phase5(player: player, navigator: navigator, settings: settings, connect: connect) && ok
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

    private static func switching(player: PlayerModel, library: LibraryModel, navigator: Navigator) async -> Bool {
        guard let page = try? await library.api.savedTracks(offset: 0) else { return false }
        let songs = page.items.map(\.track).filter { $0.isCatalogTrack && $0.isPlayable != false }
        guard songs.count >= 4, let profile = library.profile else { return false }
        navigator.surface = .library
        var ok = true
        for (index, song) in songs.prefix(4).enumerated() {
            let start = Date()
            let frames = player.core.takeStats().frames_rendered
            player.play(PlayRequest(contextURI: "spotify:user:\(profile.id):collection", startURI: song.uri), selectedTrack: song)
            ok = check(ok, player.displayTrack?.uri == song.uri && player.isLoading && !player.isPlaying,
                       "selection appears immediately without claiming audio has started")
            say(String(format: "Switch %d: selection updated in %.1f ms", index + 1, Date().timeIntervalSince(start) * 1000))
            let audible = await wait(timeout: 20) {
                player.isPlaying && !player.isLoading && player.track?.name == song.name
                    && player.core.takeStats().frames_rendered > frames + 1024
            }
            ok = check(ok, audible, "selected song produces audio")
            say(String(format: "Switch %d: audio flowing after %.0f ms", index + 1, Date().timeIntervalSince(start) * 1000))
            guard audible else { break }
            try? await Task.sleep(for: .seconds(2))
        }
        if ok {
            player.play(PlayRequest(tracks: songs.map(\.uri), startURI: songs[1].uri), selectedTrack: songs[1])
            player.play(PlayRequest(tracks: songs.map(\.uri), startURI: songs[2].uri), selectedTrack: songs[2])
            ok = check(ok, player.displayTrack?.uri == songs[2].uri && player.isLoading, "latest rapid selection wins immediately")
            ok = check(ok, await wait(timeout: 20) { player.isPlaying && !player.isLoading && player.track?.name == songs[2].name },
                       "latest rapid selection eventually plays")
        }
        if ok {
            try? await Task.sleep(for: .seconds(3))
            let before = player.core.takeStats()
            try? await Task.sleep(for: .seconds(30))
            let after = player.core.takeStats()
            ok = check(ok, after.frames_rendered - before.frames_rendered > 1_200_000,
                       "audio continues throughout the 30-second buffer stability check")
            ok = check(ok, after.underruns == before.underruns,
                       "no new audio underruns during steady playback")
        }
        say(String(format: "Switching footprint: %.1f MiB", MemoryFootprint.currentMB))
        return ok
    }

    private static func phase5(player: PlayerModel, navigator: Navigator, settings: AppSettings, connect: ConnectModel) async -> Bool {
        var ok = true
        let original = settings.playbackConfiguration
        navigator.surface = .library
        let uri = player.track?.uri
        player.seek(toMs: 12000)
        try? await Task.sleep(for: .seconds(1))
        player.core.deliver(.unavailable(uri: "spotify:track:synthetic-unavailable"))
        ok = check(ok, player.lastError != nil && !(player.lastError?.contains("spotify:") ?? true), "unavailable error is human-readable")
        Snapshot.capture("14-unavailable-state")
        player.dismissError()
        settings.bitrate = 160; settings.normalization = true; settings.gapless = false
        player.configurePlayback(settings.playbackConfiguration)
        player.core.deliver(.disconnected)
        ok = check(ok, !player.isPlaying && !player.isConnected, "session loss stops the UI clock")
        Snapshot.capture("15-reconnecting-state")
        player.reconnectPlayback()
        let restored = await wait(timeout: 30) {
            player.isConnected && player.isPlaying && player.track?.uri == uri && !player.isLoading
        }
        ok = check(ok, restored, "reconnect resumes context playback")
        ok = check(ok, player.positionMs(at: Date()) >= 11000 && player.positionMs(at: Date()) < 30000, "reconnect preserves position")
        ok = check(ok, player.activeConfiguration == settings.playbackConfiguration, "quality and normalization configuration applied")
        let frames = player.core.takeStats().frames_rendered
        try? await Task.sleep(for: .seconds(3))
        ok = check(ok, player.core.takeStats().frames_rendered > frames + 110000, "audio flows after reconfiguration")
        player.pause()
        settings.bitrate = original.bitrate; settings.normalization = original.normalization; settings.gapless = original.gapless
        player.configurePlayback(original)
        player.reconnectPlayback()
        let paused = await wait(timeout: 30) {
            player.isConnected && !player.isPlaying && !player.isLoading && player.activeConfiguration == original
        }
        ok = check(ok, paused, "reconnect preserves pause and restores preferences")
        await connect.refresh(.queue)
        if connect.needsPermission {
            say("Queue/Devices: consent is required; existing library permission is preserved")
        } else {
            ok = check(ok, connect.error == nil, "live queue fetch")
            await connect.refresh(.devices)
            ok = check(ok, connect.error == nil && !connect.devices.isEmpty, "live device fetch")
            say("Queue/Devices: \(connect.queue.count) upcoming entries, \(connect.devices.count) devices")
        }
        try? await Task.sleep(for: .seconds(10))
        say(String(format: "Phase 5 after reconnect, paused: %.1f MiB footprint", MemoryFootprint.currentMB))
        return ok
    }

    private static func phase4(player: PlayerModel, navigator: Navigator, lyrics: LyricsModel,
                               visualization: VisualizationModel, visuals: VisualSettings) async -> Bool {
        let defaults = UserDefaults.standard
        let reduced = defaults.object(forKey: "reduceMotion")
        let original = (visuals.showVisualizer, visuals.style, visuals.shape, visuals.sensitivity,
                        visuals.liveBackground, visuals.reactivity)
        defer {
            visuals.showVisualizer = original.0; visuals.style = original.1; visuals.shape = original.2
            visuals.sensitivity = original.3; visuals.liveBackground = original.4; visuals.reactivity = original.5
            if let reduced { defaults.set(reduced, forKey: "reduceMotion") }
            else { defaults.removeObject(forKey: "reduceMotion") }
        }
        defaults.set(false, forKey: "reduceMotion")
        visuals.showVisualizer = false; visuals.style = .circular; visuals.shape = .bars
        visuals.liveBackground = false
        navigator.surface = .nowPlaying
        try? await Task.sleep(for: .seconds(10))
        say(String(format: "Phase 4 baseline (effects off): %.1f MiB footprint", MemoryFootprint.currentMB))
        visuals.showVisualizer = true
        var ok = true
        let before = visualization.framesAnalyzed
        let started = await wait(timeout: 10) {
            visualization.isRunning && visualization.framesAnalyzed > before + 30 && visualization.frame.rms > 0.001
        }
        ok = check(ok, started, "real PCM reaches FFT")
        try? await Task.sleep(for: .seconds(10)) // exclude startup allocations from the steady sample
        let count = visualization.framesAnalyzed
        let stats = player.core.takeStats()
        try? await Task.sleep(for: .seconds(3))
        let analyzed = visualization.framesAnalyzed - count
        let later = player.core.takeStats()
        ok = check(ok, analyzed >= 60 && analyzed <= 120, "analysis runs near 30 Hz")
        ok = check(ok, later.frames_rendered - stats.frames_rendered > 110000, "audio keeps flowing with FFT")
        ok = check(ok, later.underruns == stats.underruns, "no new audio underruns with FFT")
        say(String(format: "Phase 4: %llu FFT frames / 3 s, RMS %.4f, %.1f MiB footprint",
                   analyzed, visualization.frame.rms, MemoryFootprint.currentMB))
        if defaults.bool(forKey: "FloeVisualTest") { lyrics.showVisualTestFixture() }
        for (style, shape, name) in [(VisualSettings.Style.circular, VisualSettings.Shape.bars, "9-circular-bars"),
                                     (.circular, .wave, "10-circular-wave"), (.normal, .bars, "11-normal-bars"),
                                     (.normal, .wave, "12-normal-wave")] {
            visuals.style = style; visuals.shape = shape
            try? await Task.sleep(for: .seconds(2))
            Snapshot.capture(name)
        }
        player.pause()
        _ = await wait(timeout: 3) { !visualization.isRunning }
        try? await Task.sleep(for: .milliseconds(300))
        let frozen = visualization.framesAnalyzed
        try? await Task.sleep(for: .milliseconds(700))
        ok = check(ok, visualization.framesAnalyzed == frozen, "FFT stops on pause")
        player.resume()
        _ = await wait(timeout: 5) { visualization.isRunning }
        navigator.surface = .library
        _ = await wait(timeout: 3) { !visualization.isRunning }
        ok = check(ok, !visualization.isRunning, "hidden visualizer stops analysis")
        visuals.liveBackground = true
        let gpuBefore = visualization.backgroundFramesDrawn
        let gpuStarted = await wait(timeout: 15) { visualization.backgroundFramesDrawn > gpuBefore + 15 }
        ok = check(ok, gpuStarted && visualization.backgroundFailure == nil, "Metal background renders")
        try? await Task.sleep(for: .seconds(3))
        say(String(format: "Phase 4 live background: %llu submitted frames, %.1f MiB footprint",
                   visualization.backgroundFramesDrawn - gpuBefore, MemoryFootprint.currentMB))
        Snapshot.capture("13-live-background-library")
        player.pause()
        _ = await wait(timeout: 3) { !visualization.isRunning }
        try? await Task.sleep(for: .milliseconds(500))
        let gpuFrozen = visualization.backgroundFramesDrawn
        try? await Task.sleep(for: .milliseconds(700))
        ok = check(ok, visualization.backgroundFramesDrawn == gpuFrozen, "Metal clock stops on pause")
        player.resume()
        _ = await wait(timeout: 5) { visualization.isRunning }
        defaults.set(true, forKey: "reduceMotion")
        _ = await wait(timeout: 3) { !visualization.isRunning }
        ok = check(ok, !visualization.isRunning, "Reduce Motion stops decorative animation")
        defaults.set(false, forKey: "reduceMotion")
        visuals.liveBackground = false; visuals.showVisualizer = false
        _ = await wait(timeout: 3) { !visualization.isRunning }
        ok = check(ok, !visualization.isRunning, "disabled effects stop analysis")
        player.pause()
        return ok
    }

    /// Mid-flight frames of the surface transitions and the lyrics-free layout.
    /// Restores the lyrics preference afterwards.
    private static func transitions(navigator: Navigator) async {
        // Hidden windows get few display updates, so animations crawl there.
        let visible = NSApp.windows.contains { $0.canBecomeMain && $0.occlusionState.contains(.visible) }
        say("transitions: window \(visible ? "visible" : "occluded")")
        navigator.surface = .library
        try? await Task.sleep(for: .seconds(1.5))
        navigator.surface = .nowPlaying
        try? await Task.sleep(for: .milliseconds(150))
        Snapshot.capture("14-to-now-playing-mid")
        try? await Task.sleep(for: .seconds(1.5))
        Snapshot.capture("15-now-playing-settled")
        let defaults = UserDefaults.standard
        let lyricsShown = defaults.object(forKey: "nowPlayingLyrics")
        defaults.set(false, forKey: "nowPlayingLyrics")
        try? await Task.sleep(for: .seconds(1.5))
        Snapshot.capture("16-now-playing-no-lyrics")
        if let lyricsShown { defaults.set(lyricsShown, forKey: "nowPlayingLyrics") }
        else { defaults.removeObject(forKey: "nowPlayingLyrics") }
        try? await Task.sleep(for: .seconds(1))
        navigator.surface = .library
        try? await Task.sleep(for: .milliseconds(150))
        Snapshot.capture("17-to-library-mid")
        try? await Task.sleep(for: .seconds(1.5))
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
