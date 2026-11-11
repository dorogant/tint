import Foundation

@main struct PlaybackTransportTests {
    @MainActor static func main() async throws {
        let first = track("first"), preceding = track("preceding")
        let core = FloeCore.shared

        let navigationJSON = Data(#"{"type":"navigation","uri":"spotify:track:first","has_previous":false}"#.utf8)
        guard case let .navigation(uri, hasPrevious)? = CoreEvent(json: navigationJSON) else {
            preconditionFailure("Navigation wire event must decode")
        }
        precondition(uri == first.uri && !hasPrevious)
        precondition(CoreEvent(json: Data(#"{"type":"navigation","has_previous":false}"#.utf8)) == nil,
                     "Navigation without a track identity cannot be used for a boundary decision")
        print("PASS: navigation wire event decoding")

        guard case let .stopped(stoppedURI)? = CoreEvent(json: Data(#"{"type":"stopped","uri":"spotify:track:first"}"#.utf8)),
              case .deviceInactive? = CoreEvent(json: Data(#"{"type":"device_inactive"}"#.utf8)) else {
            preconditionFailure("Stopped and device-inactive wire events must decode")
        }
        precondition(stoppedURI == first.uri)
        guard case let .stopped(legacyURI)? = CoreEvent(json: Data(#"{"type":"stopped"}"#.utf8)) else {
            preconditionFailure("A legacy stopped event must still decode")
        }
        precondition(legacyURI == nil)
        print("PASS: stopped identity and remote device wire events")

        // At the beginning of a context, librespot can accept Previous without
        // emitting a load or state event. Repeating the command must not stop
        // the UI's playback clock or leave a permanent loading spinner.
        var model = playing(first, at: 800)
        let sampleDate = Date().addingTimeInterval(1)
        let before = model.positionMs(at: sampleDate)
        model.previous()
        model.previous()
        precondition(core.commands == [.previous, .previous])
        precondition(model.isPlaying && !model.isLoading,
                     "Double Previous at a context boundary must keep playback running")
        precondition(model.displayTrack == first && model.positionMs(at: sampleDate) == before,
                     "A transport command without an engine transition must preserve track and clock")
        print("PASS: double Previous at the first-track boundary")

        // The first press restarts a song beyond three seconds. A rapid second
        // press reaches Previous's boundary path before a seek event arrives.
        model = playing(first, at: 7500)
        model.previous()
        precondition(core.commands == [.seek(0)] && model.isPlaying && !model.isLoading)
        precondition(model.positionMs(at: Date()) < 1000)
        model.previous()
        precondition(core.commands == [.seek(0), .previous])
        precondition(model.isPlaying && !model.isLoading,
                     "Seek then Previous must not stall when there is no preceding track")
        core.deliver(.position(positionMs: 0))
        precondition(model.isPlaying && !model.isLoading && model.positionMs(at: Date()) < 1000,
                     "A delayed seek position must preserve running playback")
        print("PASS: restart followed immediately by Previous")

        model = playing(first, at: 0)
        core.deliver(.paused(positionMs: 1234))
        model.previous()
        model.previous()
        precondition(core.commands == [.previous, .previous])
        precondition(!model.isPlaying && !model.isLoading
                     && model.positionMs(at: Date().addingTimeInterval(10)) == 1234,
                     "Previous at a paused boundary must preserve the paused position")
        print("PASS: paused Previous boundary")

        // Next has the same event-driven boundary behavior at a context end.
        model = playing(first, at: 12000)
        let nextSampleDate = Date().addingTimeInterval(1)
        let nextBefore = model.positionMs(at: nextSampleDate)
        model.next()
        precondition(core.commands == [.next])
        precondition(model.isPlaying && !model.isLoading
                     && model.positionMs(at: nextSampleDate) == nextBefore,
                     "Next without an engine transition must not reset or stop playback")
        print("PASS: Next preserves playback until an engine transition")

        // A genuine skip still enters loading on the real event, publishes the
        // new track, then starts its clock at the engine-confirmed position.
        model = playing(first, at: 1500)
        model.previous()
        core.deliver(.loading(positionMs: 0))
        precondition(model.isLoading && !model.isPlaying && model.positionMs(at: Date()) == 0,
                     "A real load must show loading and pause interpolation")
        core.deliver(.track(preceding))
        precondition(model.displayTrack == preceding && model.isLoading)
        core.deliver(.playing(positionMs: 250))
        precondition(!model.isLoading && model.isPlaying && model.displayTrack == preceding)
        precondition(model.positionMs(at: Date()) >= 250 && model.positionMs(at: Date()) < 1250)
        print("PASS: real Previous loading, metadata and playback events")

        // A paused engine result also clears loading rather than leaving the
        // button waiting for a Playing event which will never arrive.
        model = playing(first, at: 1500)
        model.next()
        core.deliver(.loading(positionMs: 0))
        core.deliver(.track(preceding))
        core.deliver(.paused(positionMs: 400))
        precondition(!model.isLoading && !model.isPlaying && model.displayTrack == preceding
                     && model.positionMs(at: Date().addingTimeInterval(10)) == 400)
        print("PASS: paused engine result clears loading")

        // Queue metadata identifies a first song without relying on the visible
        // playlist order (which can differ under shuffle or a Connect transfer).
        model = playing(first, at: 800)
        core.deliver(.navigation(uri: first.uri, hasPrevious: false))
        model.previous()
        model.previous()
        precondition(core.commands == [.seek(0), .seek(0)]
                     && model.isPlaying && !model.isLoading && model.positionMs(at: Date()) < 1000,
                     "A confirmed first song must restart without issuing a Previous command")
        model = playing(first, at: 0)
        core.deliver(.paused(positionMs: 1234))
        core.deliver(.navigation(uri: first.uri, hasPrevious: false))
        model.previous()
        model.previous()
        precondition(core.commands == [.seek(0), .seek(0)]
                     && !model.isPlaying && !model.isLoading && model.positionMs(at: Date()) == 0,
                     "Restarting a confirmed first song must preserve paused playback")
        print("PASS: confirmed first-track restart preserves playing and paused states")

        model = playing(preceding, at: 800)
        core.deliver(.navigation(uri: first.uri, hasPrevious: false))
        model.previous()
        precondition(core.commands == [.previous] && model.isPlaying && !model.isLoading,
                     "Queue metadata for an older song must not suppress Previous on the current one")
        print("PASS: stale navigation metadata does not block Previous")

        model = playing(first, at: 800)
        core.deliver(.navigation(uri: first.uri, hasPrevious: true))
        model.previous()
        precondition(core.commands == [.previous] && model.isPlaying && !model.isLoading,
                     "Previous must reach the engine when queue history exists")
        print("PASS: known queue history allows Previous")

        model = playing(first, at: 800)
        core.deliver(.navigation(uri: first.uri, hasPrevious: false))
        core.deliver(.disconnected)
        core.deliver(.connected(username: "Synthetic listener"))
        core.deliver(.playing(positionMs: 800))
        model.previous()
        precondition(core.commands == [.previous],
                     "Disconnected sessions must discard their earlier queue metadata")
        model = playing(first, at: 800)
        core.deliver(.navigation(uri: first.uri, hasPrevious: false))
        core.deliver(.loggedOut)
        core.deliver(.connected(username: "Synthetic listener"))
        core.deliver(.track(first))
        core.deliver(.playing(positionMs: 800))
        model.previous()
        precondition(core.commands == [.previous],
                     "Logged-out sessions must discard their earlier queue metadata")
        print("PASS: disconnect and logout discard navigation metadata")

        model = playing(first, at: 800)
        core.deliver(.navigation(uri: first.uri, hasPrevious: false))
        model.play(PlayRequest(contextURI: "spotify:playlist:another", startURI: first.uri))
        core.deliver(.playing(positionMs: 800))
        model.previous()
        precondition(core.commands == [.previous],
                     "A different context must discard old queue metadata even on the same song")
        print("PASS: changing context discards navigation metadata")

        // Duplicate entries may carry the same URI at different queue positions.
        // Until new navigation metadata arrives, the earlier occurrence's
        // first-track status must not cause Previous to restart the duplicate.
        model = playing(first, at: 800)
        core.deliver(.navigation(uri: first.uri, hasPrevious: false))
        model.next()
        core.deliver(.track(first))
        core.deliver(.playing(positionMs: 800))
        model.previous()
        precondition(core.commands == [.next, .previous] && model.isPlaying && !model.isLoading,
                     "Next into a duplicate URI must not reuse the earlier occurrence's boundary")
        print("PASS: Next invalidates navigation for duplicate song entries")

        model = playing(first, at: 800)
        core.deliver(.navigation(uri: first.uri, hasPrevious: true))
        model.previous()
        core.deliver(.track(first))
        core.deliver(.playing(positionMs: 800))
        precondition(model.hasPreviousTrack == nil,
                     "Previous must leave the new queue position unknown until its metadata arrives")
        core.deliver(.navigation(uri: first.uri, hasPrevious: false))
        model.previous()
        precondition(core.commands == [.previous, .seek(0)],
                     "The new occurrence's boundary must replace the older history information")
        print("PASS: Previous invalidates navigation for duplicate song entries")

        model = playing(first, at: 800)
        core.deliver(.navigation(uri: first.uri, hasPrevious: false))
        core.deliver(.deviceInactive)
        core.deliver(.stopped(uri: first.uri))
        core.deliver(.playing(positionMs: 800))
        model.previous()
        precondition(core.commands == [.previous] && model.isPlaying && !model.isLoading,
                     "A Connect takeover must discard queue history even when the song URI is unchanged")
        print("PASS: Connect takeover discards navigation metadata")

        // Spirc sometimes discovers a first-track boundary only after handling
        // Previous and stopping the same song. This local outcome can be repaired
        // by restarting the current context, once, without losing its settings.
        model = playing(first, at: 800)
        model.play(PlayRequest(contextURI: "spotify:playlist:synthetic", startIndex: 7))
        core.deliver(.playing(positionMs: 800))
        model.previous()
        core.deliver(.stopped(uri: first.uri))
        precondition(core.loads.count == 2, "A matching local boundary stop must reload the current song once")
        let restarted = core.loads[1]
        precondition(restarted.contextURI == "spotify:playlist:synthetic"
                     && restarted.startURI == first.uri && restarted.startIndex == nil
                     && restarted.positionMs == 0 && restarted.startPlaying,
                     "Boundary recovery must preserve the selected context and running state")
        precondition(model.isLoading && !model.isPlaying)
        core.deliver(.loading(positionMs: 0))
        core.deliver(.playing(positionMs: 0))
        precondition(model.isPlaying && !model.isLoading && model.positionMs(at: Date()) < 1000)
        core.deliver(.stopped(uri: first.uri))
        precondition(core.loads.count == 2, "One local Previous must never cause repeated recovery loads")
        print("PASS: local boundary stop restarts the current context once")

        model = playing(first, at: 800)
        model.play(PlayRequest(contextURI: "spotify:playlist:synthetic", startURI: first.uri,
                               startPlaying: false))
        core.deliver(.paused(positionMs: 800))
        model.previous()
        core.deliver(.stopped(uri: first.uri))
        precondition(core.loads.count == 2 && !core.loads[1].startPlaying
                     && core.loads[1].positionMs == 0,
                     "A paused boundary recovery must restart at zero without starting playback")
        core.deliver(.paused(positionMs: 0))
        precondition(!model.isPlaying && !model.isLoading && model.positionMs(at: Date()) == 0)
        print("PASS: paused local boundary recovery remains paused")

        model = playing(first, at: 800)
        model.previous()
        core.deliver(.deviceInactive)
        core.deliver(.stopped(uri: first.uri))
        precondition(core.loads.isEmpty && !model.isPlaying && !model.isLoading,
                     "An inactive Connect device must not restart playback after a remote takeover")
        print("PASS: remote takeover cancels local boundary recovery")

        model = playing(first, at: 800)
        model.previous()
        core.deliver(.stopped(uri: preceding.uri))
        precondition(core.loads.isEmpty,
                     "A stop for a different song must not trigger Previous boundary recovery")
        print("PASS: mismatched track stop does not restart playback")

        model = playing(first, at: 800)
        model.previous()
        model.next()
        core.deliver(.stopped(uri: first.uri))
        precondition(core.commands == [.previous, .next] && core.loads.isEmpty,
                     "Next must cancel a pending Previous boundary recovery")
        print("PASS: Next cancels local Previous recovery")

        // A seek acknowledgement can arrive after the second Previous press.
        // It belongs to the earlier restart and must not erase the newer
        // boundary recovery intent before Spirc reports its matching stop.
        model = playing(first, at: 7500)
        model.previous()
        model.previous()
        core.deliver(.position(positionMs: 0))
        core.deliver(.stopped(uri: first.uri))
        precondition(core.commands == [.seek(0), .previous] && core.loads.count == 1,
                     "A delayed seek acknowledgement must not cancel the later Previous recovery")
        precondition(core.loads[0].tracks == [first.uri] && core.loads[0].startURI == first.uri
                     && core.loads[0].positionMs == 0 && core.loads[0].startPlaying)
        core.deliver(.playing(positionMs: 0))
        precondition(model.isPlaying && !model.isLoading)
        print("PASS: delayed seek acknowledgement preserves later Previous recovery")

        model = playing(first, at: 800)
        model.previous()
        core.deliver(.position(positionMs: 1500))
        core.deliver(.stopped(uri: first.uri))
        precondition(core.loads.count == 1 && core.loads[0].startURI == first.uri
                     && core.loads[0].positionMs == 0 && core.loads[0].startPlaying,
                     "An ordinary position correction must not cancel pending Previous recovery")
        print("PASS: position correction preserves pending Previous recovery")

        model = playing(first, at: 800)
        model.previous()
        try await Task.sleep(for: .milliseconds(2100))
        core.deliver(.stopped(uri: first.uri))
        precondition(core.loads.isEmpty,
                     "An expired local Previous must not restart a later unrelated stop")
        print("PASS: expired Previous does not restart a later stop")

        // The audio engine renders (and keeps the Mac awake) from `start()` until
        // an engine event pauses it. A Play that no event follows must not leave
        // it running for good.
        PlayerModel.unansweredPlay = .milliseconds(150)
        PlayerModel.unansweredLoad = .milliseconds(150)
        core.reset()
        model = PlayerModel()
        model.resume()
        precondition(core.commands.isEmpty && AudioOutput.latest?.isRunning == false,
                     "Play without a session must not start the audio engine")
        print("PASS: Play without a session leaves the audio engine stopped")

        model = playing(first, at: 800)
        core.deliver(.paused(positionMs: 900))
        model.resume()
        precondition(core.commands == [.play] && AudioOutput.latest?.isRunning == true)
        try await Task.sleep(for: .milliseconds(400))
        precondition(AudioOutput.latest?.isRunning == false && !model.isPlaying,
                     "A Play the engine ignores must give the audio engine back")
        model.resume()
        core.deliver(.playing(positionMs: 900))
        try await Task.sleep(for: .milliseconds(400))
        precondition(AudioOutput.latest?.isRunning == true && model.isPlaying,
                     "An answered Play must keep the audio engine running")
        print("PASS: an unanswered Play gives the audio engine back; an answered one keeps it")

        model = playing(first, at: 800)
        core.deliver(.paused(positionMs: 900))
        model.play(PlayRequest(tracks: [preceding.uri]))
        precondition(model.isLoading && AudioOutput.latest?.isRunning == true)
        try await Task.sleep(for: .milliseconds(400))
        precondition(AudioOutput.latest?.isRunning == false,
                     "A load the engine never answers must give the audio engine back")
        core.deliver(.playing(positionMs: 0))
        precondition(AudioOutput.latest?.isRunning == true && model.isPlaying && !model.isLoading,
                     "A slow load must start the audio engine again when playback begins")
        print("PASS: an unanswered load gives the audio engine back until playback starts")

        // A saved login Spotify turns down must not be tried again on a timer.
        guard case let .loginFailed(wireMessage, wireRefused)? = CoreEvent(json: Data(#"{"type":"login_failed","message":"bad","refused":true}"#.utf8)),
              case let .loginFailed(_, legacyRefused)? = CoreEvent(json: Data(#"{"type":"login_failed","message":"bad"}"#.utf8)) else {
            preconditionFailure("Login failures must decode, with and without the refused flag")
        }
        precondition(wireMessage == "bad" && wireRefused && !legacyRefused)
        model = playing(first, at: 800)
        core.deliver(.disconnected)
        core.deliver(.loginFailed("refused by Spotify", refused: true))
        precondition(model.session == .failed("refused by Spotify") && model.hasConnected,
                     "A refused saved login must stop the reconnect loop and ask for a new sign-in")
        print("PASS: a refused saved login stops reconnecting")
        print("PASS: 28 production playback transport regressions")
    }

    @MainActor private static func playing(_ track: TrackInfo, at position: Double) -> PlayerModel {
        FloeCore.shared.reset()
        let model = PlayerModel()
        FloeCore.shared.deliver(.connected(username: "Synthetic listener"))
        FloeCore.shared.deliver(.track(track))
        FloeCore.shared.deliver(.playing(positionMs: position))
        return model
    }

    private static func track(_ id: String) -> TrackInfo {
        TrackInfo(uri: "spotify:track:\(id)", name: "Synthetic \(id)", artists: [],
                  album: "Synthetic album", durationMs: 180000, explicit: false, coverURL: nil)
    }
}
