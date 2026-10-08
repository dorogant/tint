import Foundation
import Observation
import os

/// App-wide playback state: session, current track, transport, shuffle/repeat, volume.
/// Floe is a Spotify Connect device, so state can also change from other devices.
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
    /// True once a session came up; reconnects after that keep the main UI.
    private(set) var hasConnected = false
    private(set) var track: TrackInfo?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    /// Slider position 0…1 (Spotify's volume / 65535).
    private(set) var volume: Double
    /// The context Floe last started, e.g. `spotify:playlist:…`, for highlighting.
    private(set) var contextURI: String?
    private(set) var lastError: String?
    private(set) var activeConfiguration: PlaybackConfiguration?
    @ObservationIgnored private var requestedConfiguration = PlaybackConfiguration.default
    @ObservationIgnored private var connectingConfiguration: PlaybackConfiguration?
    @ObservationIgnored private var pendingPlayback: PlayRequest?
    @ObservationIgnored private var lastRequest: PlayRequest?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    var isConnected: Bool {
        if case .connected = session { true } else { false }
    }

    var username: String? {
        if case let .connected(name) = session { name } else { nil }
    }

    /// Position is interpolated between core events instead of polled.
    private var anchorMs: Double = 0
    private var anchorDate = Date()

    @ObservationIgnored let core = FloeCore.shared
    @ObservationIgnored private let audio = AudioOutput()
    @ObservationIgnored private lazy var nowPlaying = NowPlayingController(model: self)
    @ObservationIgnored private var storedCredentials: Data?
    @ObservationIgnored private var reconnectAttempt = 0
    /// False once another device took over, so Play transfers playback back.
    @ObservationIgnored private var isActiveDevice = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "player")

    init() {
        volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.7
        audio.volume = Self.amplitude(volume)
        core.onEvent = { [weak self] event in self?.handle(event) }
    }

    func positionMs(at date: Date) -> Double {
        let position = isPlaying ? anchorMs + date.timeIntervalSince(anchorDate) * 1000 : anchorMs
        return min(max(position, 0), track?.durationMs ?? .infinity)
    }

    /// Changes on pause, resume, seek and position correction. Lyrics use it to
    /// restart their clock without redrawing the whole list on every timer tick.
    var playbackAnchor: Date { anchorDate }

    // MARK: - Session

    /// Restores the previous session from the Keychain, if there is one.
    func restoreSession() async {
        let stored = await Task.detached { Keychain.read(Keychain.Account.playbackSession) }.value
        guard let stored, session == .loggedOut else { return }
        storedCredentials = stored
        startSession(using: stored)
    }

    func logIn() {
        guard session != .authorizing else { return }
        reconnectTask?.cancel()
        rememberPlayback()
        Task {
            session = .authorizing
            do {
                let token = try await SpotifyOAuth.authorize(.playbackSession(clientID: core.sessionClientID))
                connectingConfiguration = requestedConfiguration
                core.logIn(accessToken: token.accessToken, volume: spotifyVolume)
            } catch is CancellationError {
                session = .loggedOut
            } catch {
                session = .failed(error.localizedDescription)
            }
        }
    }

    func logOut() {
        reconnectTask?.cancel()
        pendingPlayback = nil
        storedCredentials = nil
        core.logOut()
        Task.detached { Keychain.delete(Keychain.Account.playbackSession) }
    }

    // MARK: - Transport

    /// Plays a context (playlist, album, artist, Liked Songs) or a track list,
    /// keeping the current shuffle and repeat settings.
    func play(_ request: PlayRequest) {
        var request = request
        request.shuffle = shuffle
        request.repeatMode = repeatMode.rawValue
        lastError = nil
        guard core.load(request) else {
            lastError = L10n.string("Couldn't start playback. Is Floe connected?")
            return
        }
        lastRequest = request
        contextURI = request.contextURI
        isActiveDevice = true
        isLoading = true
        audio.start()
    }

    /// Starts a context with a deliberate shuffle state (page Play / Shuffle actions).
    func playContext(_ uri: String, shuffled: Bool) {
        if shuffle != shuffled { toggleShuffle() }
        play(PlayRequest(contextURI: uri))
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        core.pause()
        setAnchor(positionMs(at: Date()), playing: false)
    }

    func resume() {
        audio.start()
        if isActiveDevice && track != nil {
            core.play()
        } else {
            core.transferPlayback() // take over from the phone or another computer
            isActiveDevice = true
        }
    }

    func next() { core.next() }

    /// Like other players: restart the track if past 3 s, else go back.
    func previous() {
        if positionMs(at: Date()) > 3000 {
            seek(toMs: 0)
        } else {
            core.previous()
        }
    }

    func seek(toMs ms: Double) {
        let clamped = min(max(ms, 0), track?.durationMs ?? ms)
        core.seek(toMs: UInt32(clamped))
        setAnchor(clamped, playing: isPlaying)
    }

    func toggleShuffle() {
        shuffle.toggle()
        core.setShuffle(shuffle)
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        core.setRepeat(repeatMode)
    }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        audio.volume = Self.amplitude(volume)
        UserDefaults.standard.set(volume, forKey: "volume")
        core.setVolume(spotifyVolume)
    }

    func addToQueue(_ uri: String) {
        if !core.addToQueue(uri) { lastError = L10n.string("Couldn't add this song to the queue.") }
    }

    func configurePlayback(_ configuration: PlaybackConfiguration) {
        requestedConfiguration = configuration
        core.configure(configuration)
    }

    /// Rebuild the playback session to apply codec settings, preserving context and position.
    func reconnectPlayback() {
        guard let credentials = storedCredentials else { logIn(); return }
        reconnectTask?.cancel()
        rememberPlayback()
        core.pause()
        setAnchor(positionMs(at: Date()), playing: false)
        isLoading = false
        session = .connecting
        startSession(using: credentials)
    }

    private func startSession(using credentials: Data) {
        connectingConfiguration = requestedConfiguration
        core.logIn(storedCredentials: credentials, volume: spotifyVolume)
    }

    private func rememberPlayback() {
        guard let track, pendingPlayback == nil else { return }
        var request = lastRequest ?? PlayRequest(tracks: [track.uri])
        request.startURI = track.uri
        request.positionMs = UInt32(clamping: Int(positionMs(at: Date())))
        request.startPlaying = isPlaying
        pendingPlayback = request
    }

    func dismissError() { lastError = nil }

    private var spotifyVolume: UInt16 { UInt16((volume * 65535).rounded()) }

    /// Perceptual curve over a 60 dB range, like librespot's default "log" mapping.
    private static func amplitude(_ x: Double) -> Float {
        x <= 0 ? 0 : Float((pow(1000, x) - 1) / 999)
    }

    // MARK: - Events

    private func setAnchor(_ ms: Double, playing: Bool) {
        anchorMs = ms
        anchorDate = Date()
        if isPlaying != playing { isPlaying = playing }
        if playing {
            idleTask?.cancel()
            audio.start()
        } else {
            scheduleIdle()
        }
        nowPlaying.update()
    }

    /// Stops the audio engine shortly after playback stops (≈0% CPU when idle);
    /// the delay lets buffered audio play out and avoids churn on quick toggles.
    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !isPlaying else { return }
            audio.pause()
        }
    }

    private func handle(_ event: CoreEvent) {
        switch event {
        case .connecting:
            if !isConnected { session = .connecting }
        case let .connected(username):
            reconnectAttempt = 0
            hasConnected = true
            session = .connected(username: username)
            activeConfiguration = connectingConfiguration ?? requestedConfiguration
            if let request = pendingPlayback {
                pendingPlayback = nil
                play(request)
            }
        case let .credentials(blob):
            storedCredentials = blob
            Task.detached { Keychain.write(blob, account: Keychain.Account.playbackSession) }
        case let .loginFailed(message):
            log.error("Login failed: \(message, privacy: .public)")
            if hasConnected || reconnectAttempt > 0 { session = .connecting; scheduleReconnect() } else { session = .failed(message) }
        case .disconnected:
            rememberPlayback()
            log.notice("Session dropped; reconnecting")
            isActiveDevice = false
            session = .connecting
            isLoading = false
            setAnchor(positionMs(at: Date()), playing: false)
            scheduleReconnect()
        case .loggedOut:
            session = .loggedOut
            hasConnected = false
            track = nil
            contextURI = nil
            setAnchor(0, playing: false)
        case let .track(info):
            track = info
            nowPlaying.update()
        case let .loading(ms):
            isLoading = true
            setAnchor(ms, playing: false)
        case let .playing(ms):
            isLoading = false
            isActiveDevice = true
            lastError = nil
            setAnchor(ms, playing: true)
        case let .paused(ms):
            isLoading = false
            setAnchor(ms, playing: false)
        case let .position(ms):
            setAnchor(ms, playing: isPlaying)
        case .stopped:
            // Spirc stops the player when another device takes over.
            isLoading = false
            isActiveDevice = false
            setAnchor(positionMs(at: Date()), playing: false)
        case .endOfTrack:
            break // Spirc moves on to the next track itself
        case .unavailable:
            isLoading = false
            lastError = L10n.string("This track is unavailable. Try another song.")
        case let .shuffle(on):
            shuffle = on
        case let .repeatMode(mode):
            repeatMode = mode
        case let .volume(raw):
            volume = Double(raw) / 65535
            audio.volume = Self.amplitude(volume)
        }
    }

    /// Back-off: 2, 4, 8, 16, 30, 30… seconds.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        guard let credentials = storedCredentials else {
            session = .loggedOut
            return
        }
        reconnectAttempt += 1
        let delay = min(pow(2, Double(reconnectAttempt)), 30)
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, session == .connecting else { return }
            startSession(using: credentials)
        }
    }
}
