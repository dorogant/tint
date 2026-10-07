import Foundation
import Observation
import os

/// App-wide playback state: login, current track, play/pause and position.
@MainActor
@Observable
final class PlayerModel {
    enum Session: Equatable {
        case loggedOut
        case authorizing
        case connecting
        case connected(username: String)
        case failed(String)
    }

    private(set) var session: Session = .loggedOut
    private(set) var track: TrackInfo?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var lastError: String?

    var volume: Double = 0.8 {
        didSet { audio.volume = Float(volume) }
    }

    var isConnected: Bool {
        if case .connected = session { true } else { false }
    }

    /// Position is interpolated between core events instead of polled.
    private var anchorMs: Double = 0
    private var anchorDate = Date()

    @ObservationIgnored let core = FloeCore.shared
    @ObservationIgnored private let audio = AudioOutput()
    @ObservationIgnored private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "player")

    init() {
        audio.volume = Float(volume)
        core.onEvent = { [weak self] event in self?.handle(event) }
    }

    func positionMs(at date: Date) -> Double {
        let position = isPlaying ? anchorMs + date.timeIntervalSince(anchorDate) * 1000 : anchorMs
        return min(max(position, 0), track?.durationMs ?? .infinity)
    }

    // MARK: - Session

    /// Restores the previous session from the Keychain, if there is one.
    func restoreSession() async {
        let stored = await Task.detached { Keychain.read(Keychain.Account.playbackSession) }.value
        guard let stored, session == .loggedOut else { return }
        core.logIn(storedCredentials: stored)
    }

    func logIn() {
        Task {
            session = .authorizing
            do {
                let token = try await SpotifyOAuth.authorize(.playbackSession(clientID: core.sessionClientID))
                core.logIn(accessToken: token.accessToken)
            } catch is CancellationError {
                session = .loggedOut
            } catch {
                session = .failed(error.localizedDescription)
            }
        }
    }

    func logOut() {
        audio.pause()
        core.logOut()
        Task.detached { Keychain.delete(Keychain.Account.playbackSession) }
    }

    // MARK: - Playback

    @discardableResult
    func play(uri: String) -> Bool {
        lastError = nil
        guard core.load(uri, play: true) else {
            lastError = String(localized: "That isn't a playable Spotify track URI.")
            return false
        }
        audio.start()
        isLoading = true
        return true
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        core.pause()
        setAnchor(positionMs(at: Date()), playing: false)
        audio.pause()
    }

    func resume() {
        guard track != nil else { return }
        audio.start()
        core.play()
    }

    func seek(toMs ms: Double) {
        let clamped = min(max(ms, 0), track?.durationMs ?? ms)
        core.seek(toMs: UInt32(clamped))
        setAnchor(clamped, playing: isPlaying)
    }

    // MARK: - Events

    private func setAnchor(_ ms: Double, playing: Bool) {
        anchorMs = ms
        anchorDate = Date()
        isPlaying = playing
    }

    private func handle(_ event: CoreEvent) {
        switch event {
        case .connecting:
            session = .connecting
        case let .connected(username, _):
            session = .connected(username: username)
        case let .credentials(blob):
            Task.detached { Keychain.write(blob, account: Keychain.Account.playbackSession) }
        case let .loginFailed(message):
            log.error("Login failed: \(message, privacy: .public)")
            session = .failed(message)
        case .loggedOut:
            session = .loggedOut
            track = nil
            setAnchor(0, playing: false)
        case let .track(info):
            track = info
        case let .loading(ms):
            isLoading = true
            setAnchor(ms, playing: false)
        case let .playing(ms):
            isLoading = false
            setAnchor(ms, playing: true)
            audio.start()
        case let .paused(ms):
            isLoading = false
            setAnchor(ms, playing: false)
        case let .position(ms):
            setAnchor(ms, playing: isPlaying)
        case .stopped:
            isLoading = false
            setAnchor(0, playing: false)
        case .endOfTrack:
            setAnchor(track?.durationMs ?? 0, playing: false)
            // The last half second is still buffered; let it play out before idling.
            Task {
                try? await Task.sleep(for: .seconds(1))
                if !isPlaying { audio.pause() }
            }
        case let .unavailable(uri):
            isLoading = false
            lastError = String(localized: "This track isn't available in your region: \(uri)")
        }
    }
}
