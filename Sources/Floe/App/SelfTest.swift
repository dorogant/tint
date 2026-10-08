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
        if UserDefaults.standard.bool(forKey: "FloeSelfTestTransport") {
            let passed = await transport(player: player, library: library, navigator: navigator)
            player.pause()
            return finish(passed, "Previous boundary and rapid transport checks")
        }
        if UserDefaults.standard.bool(forKey: "FloeSelfTestSwitching") {
            let passed = await switching(player: player, library: library, navigator: navigator)
            player.pause()
            return finish(passed, "song switching checks")
        }
        if UserDefaults.standard.bool(forKey: "FloeSelfTestSearchSwitch") {
            let passed = await searchSwitch(player: player, navigator: navigator, search: search,
                                            visualization: visualization)
            player.pause()
            return finish(passed, "search and switch songs")
        }
        if UserDefaults.standard.bool(forKey: "FloeSelfTestPerf") {
            let passed = await performance(player: player, library: library, navigator: navigator, lyrics: lyrics,
                                           visualization: visualization, visuals: visuals)
            return finish(passed, "performance and equalizer-shape measurements")
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

    /// Uses a real playlist context, with no library edits or lyric capture.
    private static func transport(player: PlayerModel, library: LibraryModel, navigator: Navigator) async -> Bool {
        navigator.surface = .library
        var fixture: (uri: String, songs: [Track])?
        for playlist in library.playlists where library.canListItems(of: playlist) {
            guard let page = try? await library.api.playlistItems(playlist.id, offset: 0) else { continue }
            let songs = page.items.compactMap(\.track).filter { $0.isCatalogTrack && $0.isPlayable != false }
            if songs.count >= 2 { fixture = (playlist.uri, Array(songs.prefix(2))); break }
        }
        guard let fixture else { return check(true, false, "needs a playlist with two playable songs") }
        if player.shuffle { player.toggleShuffle() }
        while player.repeatMode != .off { player.cycleRepeat() }
        let first = fixture.songs[0], second = fixture.songs[1]
        player.play(PlayRequest(contextURI: fixture.uri, startURI: first.uri), selectedTrack: first)
        guard await wait(timeout: 25, {
            player.isPlaying && !player.isLoading && player.track?.uri == first.uri && player.hasPreviousTrack == false
        }) else { return check(true, false, "first playlist song and engine history arrive") }
        var ok = true
        player.previous()
        player.previous()
        ok = check(ok, player.isPlaying && !player.isLoading, "rapid Previous at first song never enters speculative loading")
        try? await Task.sleep(for: .seconds(1))
        let before = player.core.takeStats().frames_rendered
        try? await Task.sleep(for: .seconds(2))
        ok = check(ok, player.isPlaying && !player.isLoading && player.track?.uri == first.uri
                   && player.core.takeStats().frames_rendered > before + 44_100,
                   "first song keeps producing audio after double Previous")
        guard ok else { return false }

        player.seek(toMs: 6000)
        try? await Task.sleep(for: .milliseconds(300))
        player.previous()
        player.previous()
        ok = check(ok, await wait(timeout: 10) {
            player.isPlaying && !player.isLoading && player.track?.uri == first.uri && player.positionMs(at: Date()) < 3000
        }, "seek restart followed immediately by Previous returns to zero")
        let afterRestart = player.core.takeStats().frames_rendered
        try? await Task.sleep(for: .seconds(1))
        ok = check(ok, player.core.takeStats().frames_rendered > afterRestart + 22_050, "restart leaves the audio gate open")

        player.pause()
        guard await wait(timeout: 5, { !player.isPlaying && !player.isLoading }) else { return false }
        player.previous()
        player.previous()
        try? await Task.sleep(for: .milliseconds(300))
        ok = check(ok, !player.isPlaying && !player.isLoading && player.track?.uri == first.uri,
                   "paused first-song Previous preserves pause")
        player.resume()
        guard await wait(timeout: 10, { player.isPlaying }) else { return false }
        player.next()
        guard await wait(timeout: 20, { player.isPlaying && !player.isLoading && player.track?.uri == second.uri })
        else { return check(ok, false, "Next reaches the second playlist song") }
        player.previous()
        ok = check(ok, await wait(timeout: 20) { player.isPlaying && !player.isLoading && player.track?.uri == first.uri },
                   "Previous from the second song still goes back")
        // This engine doesn't publish a fresh queue snapshot for every local
        // skip. Returning to the first track must still restart at the boundary.
        player.previous()
        player.previous()
        ok = check(ok, await wait(timeout: 20) { player.isPlaying && !player.isLoading && player.track?.uri == first.uri },
                   "double Previous after returning to the first song recovers its boundary")
        let returningFrames = player.core.takeStats().frames_rendered
        try? await Task.sleep(for: .seconds(2))
        ok = check(ok, player.isPlaying && !player.isLoading && player.core.takeStats().frames_rendered > returningFrames + 44_100,
                   "returning first-song boundary remains audible")
        say(String(format: "Transport footprint: %.1f MiB", MemoryFootprint.currentMB))
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

    /// Holds each visual scenario steady and reports Floe's CPU, frame rates and
    /// memory, then compares equalizer shapes on two songs. Brings the window to
    /// the front, since hidden windows barely draw. Restores every preference.
    private static func performance(player: PlayerModel, library: LibraryModel, navigator: Navigator,
                                    lyrics: LyricsModel, visualization: VisualizationModel,
                                    visuals: VisualSettings) async -> Bool {
        guard let page = try? await library.api.savedTracks(offset: 0), let profile = library.profile,
              let first = page.items.first?.track else { return false }
        // A second song by someone else, so the shapes have something to differ on.
        let second = page.items.map(\.track).first { $0.artistLine != first.artistLine } ?? first
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: "reduceMotion"), defaults.object(forKey: "nowPlayingLyrics"))
        let original = (visuals.showVisualizer, visuals.style, visuals.shape, visuals.liveBackground, navigator.surface)
        defer {
            visuals.showVisualizer = original.0; visuals.style = original.1; visuals.shape = original.2
            visuals.liveBackground = original.3; navigator.surface = original.4
            for (key, value) in [("reduceMotion", saved.0), ("nowPlayingLyrics", saved.1)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "reduceMotion")
        defaults.set(true, forKey: "nowPlayingLyrics")
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)

        func play(_ track: Track) async -> Bool {
            player.play(PlayRequest(contextURI: "spotify:user:\(profile.id):collection", startURI: track.uri), selectedTrack: track)
            return await wait(timeout: 20) { player.isPlaying && !player.isLoading && player.displayTrack?.uri == track.uri }
        }
        guard await play(first) else { return false }
        var ok = true
        // `-FloeSelfTestPerfOnly <name>` holds one scenario for 30 s, e.g. for `sample`.
        let only = defaults.string(forKey: "FloeSelfTestPerfOnly")
        var profiles: [(raw: [Float], adaptive: [Float])] = []
        for (index, track) in (only == nil ? [first, second] : []).enumerated() {
            if index > 0 { ok = check(ok, await play(track), "second song starts") }
            navigator.surface = .nowPlaying
            visuals.liveBackground = false; visuals.showVisualizer = true
            visuals.style = .circular; visuals.shape = .wave
            try? await Task.sleep(for: .seconds(6)) // let the levels adapt to this song
            profiles.append(await shape(of: visualization, song: index + 1))
            if defaults.bool(forKey: "FloeVisualTest") {
                lyrics.showVisualTestFixture()
                for (style, shape) in [(VisualSettings.Style.circular, VisualSettings.Shape.wave), (.circular, .bars)] {
                    visuals.style = style; visuals.shape = shape
                    for moment in 1...2 {
                        try? await Task.sleep(for: .milliseconds(700))
                        Snapshot.capture("song\(index + 1)-\(shape.rawValue)-\(moment)")
                    }
                }
            }
        }
        if profiles.count == 2 {
            say(String(format: "shape: songs' average outlines correlate %.2f raw vs %.2f adaptive",
                       correlation(profiles[0].raw, profiles[1].raw), correlation(profiles[0].adaptive, profiles[1].adaptive)))
        }

        struct Scenario { let name: String; let surface: Navigator.Surface; let visualizer: VisualSettings.Style?
                          let shape: VisualSettings.Shape; let background: Bool
                          var still = false; var lyrics = true; var changingLines = false }
        let scenarios = [
            Scenario(name: "library, effects off", surface: .library, visualizer: nil, shape: .bars, background: false),
            Scenario(name: "now playing, effects off", surface: .nowPlaying, visualizer: nil, shape: .bars, background: false),
            Scenario(name: "now playing, effects off, reduce motion", surface: .nowPlaying, visualizer: nil, shape: .bars,
                     background: false, still: true),
            Scenario(name: "now playing, effects off, no lyrics", surface: .nowPlaying, visualizer: nil, shape: .bars,
                     background: false, lyrics: false),
            Scenario(name: "now playing, lyrics changing", surface: .nowPlaying, visualizer: nil, shape: .bars,
                     background: false, changingLines: true),
            Scenario(name: "now playing, circular bars", surface: .nowPlaying, visualizer: .circular, shape: .bars, background: false),
            Scenario(name: "now playing, circular halo", surface: .nowPlaying, visualizer: .circular, shape: .wave, background: false),
            Scenario(name: "now playing, bottom beads", surface: .nowPlaying, visualizer: .normal, shape: .wave, background: false),
            Scenario(name: "library, live background", surface: .library, visualizer: nil, shape: .bars, background: true),
            Scenario(name: "now playing, circular bars + background", surface: .nowPlaying, visualizer: .circular, shape: .bars, background: true),
            Scenario(name: "lyrics view", surface: .lyrics, visualizer: nil, shape: .bars, background: false),
        ]
        for scenario in scenarios where only.map(scenario.name.contains) ?? true {
            navigator.surface = scenario.surface
            visuals.showVisualizer = scenario.visualizer != nil
            if let style = scenario.visualizer { visuals.style = style }
            visuals.shape = scenario.shape
            visuals.liveBackground = scenario.background
            defaults.set(scenario.still, forKey: "reduceMotion")
            defaults.set(scenario.lyrics, forKey: "nowPlayingLyrics")
            if scenario.changingLines {
                // Synthetic lines every 1.25 s, so every sample window sees line changes.
                lyrics.showVisualTestFixture(from: player.positionMs(at: Date()) / 1000 + 2, every: 1.25, count: 24)
            }
            try? await Task.sleep(for: .seconds(4))
            if scenario.surface == .nowPlaying && !scenario.still {
                ok = check(ok, await coverAndProgressMove(), "cover rim and progress playhead move while playing")
            }
            say("perf-begin \(Int(Date().timeIntervalSince1970)) \(scenario.name)")
            let sample = await usage(over: only == nil || scenarios.filter({ $0.name.contains(only!) }).count > 1 ? 10 : 30,
                                     visualization: visualization)
            say(String(format: "perf %@: %.1f%% CPU, %.0f analysis/s, %.0f background/s, %.0f MiB footprint",
                       scenario.name, sample.cpu, sample.analysis, sample.background, MemoryFootprint.currentMB))
        }
        player.pause()
        navigator.surface = .nowPlaying
        visuals.showVisualizer = true; visuals.style = .circular; visuals.liveBackground = true
        try? await Task.sleep(for: .seconds(4))
        ok = check(ok, !(await coverAndProgressMove()), "cover rim and progress playhead hold still while paused")
        say("perf-begin \(Int(Date().timeIntervalSince1970)) paused")
        let paused = await usage(over: 10, visualization: visualization)
        say(String(format: "perf paused, effects on: %.1f%% CPU, %.0f analysis/s, %.0f background/s, %.0f MiB footprint",
                   paused.cpu, paused.analysis, paused.background, MemoryFootprint.currentMB))
        return check(ok, paused.analysis == 0 && paused.background == 0, "effects stop while paused")
    }

    /// Searches and plays a result over and over, the way a listening session
    /// goes, and logs what the window holds after each round so anything that
    /// piles up (layers, views, timers, memory, main-thread time) shows.
    private static func searchSwitch(player: PlayerModel, navigator: Navigator, search: SearchModel,
                                     visualization: VisualizationModel) async -> Bool {
        let queries = ["september", "daft punk", "radiohead", "bonobo", "massive attack", "tame impala",
                       "aphex twin", "kendrick lamar", "fleetwood mac", "burial", "four tet", "portishead"]
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        func layers(_ layer: CALayer?) -> Int {
            guard let layer else { return 0 }
            return 1 + (layer.sublayers ?? []).reduce(0) { $0 + layers($1) }
        }
        func views(_ view: NSView?, _ counts: inout [String: Int]) {
            guard let view else { return }
            counts["all", default: 0] += 1
            let name = "\(type(of: view))"
            if ["VisualizerLayerView", "BackgroundMetalView", "CrawlingCoverView", "ProgressTrackView",
                "ScrubReadoutView"].contains(name) { counts[name, default: 0] += 1 }
            for child in view.subviews { views(child, &counts) }
        }
        for (round, query) in queries.enumerated() {
            navigator.select(.search)
            search.text = query
            guard await wait(timeout: 15, { !search.songs.isEmpty }) else {
                return check(false, false, "results for \(query)")
            }
            let song = search.songs[round % min(3, search.songs.count)]
            player.play(PlayRequest(tracks: search.songs.map(\.uri), startURI: song.uri), selectedTrack: song)
            _ = await wait(timeout: 20) { player.isPlaying && !player.isLoading && player.displayTrack?.uri == song.uri }
            try? await Task.sleep(for: .seconds(3))
            let root = NSApp.windows.first { $0.canBecomeMain }?.contentView?.superview
            var counts: [String: Int] = [:]
            views(root, &counts)
            let sample = await usage(over: 3, visualization: visualization)
            let lag = await mainThreadDelay(over: 2)
            let custom = counts.filter { $0.key != "all" }.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            say(String(format: "round %2d %@: %.1f%% CPU, main delay avg %.1f ms worst %.0f ms, %d layers, %d views, %.0f MiB | %@",
                       round + 1, query, sample.cpu, lag.average, lag.worst, layers(root?.layer),
                       counts["all"] ?? 0, MemoryFootprint.currentMB, custom))
        }
        return true
    }

    /// How long the main queue takes to pick up a block, sampled every frame.
    private static func mainThreadDelay(over seconds: Double) async -> (average: Double, worst: Double) {
        var delays: [Double] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let asked = Date()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            delays.append(Date().timeIntervalSince(asked) * 1000)
            try? await Task.sleep(for: .milliseconds(16))
        }
        return (delays.reduce(0, +) / Double(max(delays.count, 1)), delays.max() ?? 0)
    }

    /// Core Animation runs these, so snapshots can't show motion; compare the
    /// on-screen state half a second apart instead. The Now Playing playhead
    /// glides between ticks, so it moves within any half second of playback.
    private static func coverAndProgressMove() async -> Bool {
        func find<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
            guard let view else { return [] }
            if let match = view as? T { return [match] }
            return view.subviews.flatMap { find(type, in: $0) }
        }
        let root = NSApp.windows.first { $0.canBecomeMain }?.contentView
        let tracks = find(ProgressTrackView.self, in: root)
        guard let cover = find(CrawlingCoverView.self, in: root).first, !tracks.isEmpty else { return false }
        let before = (cover.crawlAngle, tracks.map(\.playheadOffset))
        try? await Task.sleep(for: .milliseconds(500))
        return cover.crawlAngle != before.0 && tracks.map(\.playheadOffset) != before.1
    }

    private static func usage(over seconds: Double, visualization: VisualizationModel) async
        -> (cpu: Double, analysis: Double, background: Double) {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let cpu = cpuSeconds(), start = Date()
        let analysis = visualization.framesAnalyzed, background = visualization.backgroundFramesDrawn
        try? await Task.sleep(for: .seconds(seconds))
        let wall = Date().timeIntervalSince(start)
        return ((cpuSeconds() - cpu) / wall * 100, Double(visualization.framesAnalyzed - analysis) / wall,
                Double(visualization.backgroundFramesDrawn - background) / wall)
    }

    /// Samples the ring for 10 s: how often the bass (top) group is the biggest,
    /// how much the outline moves frame to frame, and the average outline.
    private static func shape(of visualization: VisualizationModel, song: Int) async -> (raw: [Float], adaptive: [Float]) {
        func groups(_ values: [Float]) -> [Float] {
            stride(from: 0, to: values.count, by: 8).map { start in
                values[start..<min(values.count, start + 8)].reduce(0, +) / 8
            }
        }
        var raw = [Float](repeating: 0, count: 6), adaptive = raw
        var topRaw = 0, topAdaptive = 0, samples = 0
        var upperRaw: Float = 0, upperAdaptive: Float = 0
        var motionRaw: Float = 0, motionAdaptive: Float = 0
        var previous: (raw: [Float], adaptive: [Float])?
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            let frame = visualization.frame
            let r = groups(frame.bands), a = groups(frame.levels)
            if r.firstIndex(of: r.max()!) == 0 { topRaw += 1 }
            if a.firstIndex(of: a.max()!) == 0 { topAdaptive += 1 }
            // The ring's upper half draws the lower half of the spectrum.
            upperRaw += r[0..<3].reduce(0, +) / max(1e-6, r.reduce(0, +))
            upperAdaptive += a[0..<3].reduce(0, +) / max(1e-6, a.reduce(0, +))
            if let previous {
                motionRaw += zip(r, previous.raw).map { abs($0 - $1) }.reduce(0, +) / 6
                motionAdaptive += zip(a, previous.adaptive).map { abs($0 - $1) }.reduce(0, +) / 6
            }
            previous = (r, a)
            for i in 0..<6 { raw[i] += r[i]; adaptive[i] += a[i] }
            samples += 1
        }
        let n = Float(max(samples, 1))
        say(String(format: "shape song %d: upper half holds %.0f%% of the ring raw vs %.0f%% adaptive; "
                   + "bass group biggest in %.0f%% vs %.0f%% of frames; frame-to-frame motion %.3f vs %.3f", song,
                   upperRaw / n * 100, upperAdaptive / n * 100, Float(topRaw) / n * 100, Float(topAdaptive) / n * 100,
                   motionRaw / n, motionAdaptive / n))
        return (raw.map { $0 / n }, adaptive.map { $0 / n })
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let ma = a.reduce(0, +) / Float(a.count), mb = b.reduce(0, +) / Float(b.count)
        let cov = zip(a, b).map { ($0 - ma) * ($1 - mb) }.reduce(0, +)
        let va = a.map { ($0 - ma) * ($0 - ma) }.reduce(0, +), vb = b.map { ($0 - mb) * ($0 - mb) }.reduce(0, +)
        return cov / max(1e-9, (va * vb).squareRoot())
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
