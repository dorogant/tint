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
    /// Selected locally, before the engine confirms the loaded track.
    private(set) var pendingTrack: TrackInfo?
    var displayTrack: TrackInfo? { pendingTrack ?? track }
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
    @ObservationIgnored private var navigation: (uri: String, hasPrevious: Bool)?
    /// Spirc stops at an empty history. Recover only the just-issued local
    /// Previous for this exact track, without restarting after a Connect takeover.
    @ObservationIgnored private var previousRestart: (uri: String, request: PlayRequest, date: Date)?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    var isConnected: Bool {
        if case .connected = session { true } else { false }
    }

    var username: String? {
        if case let .connected(name) = session { name } else { nil }
    }

    /// Unknown until the engine reports history for the loaded track.
    var hasPreviousTrack: Bool? {
        guard let navigation, navigation.uri == track?.uri else { return nil }
        return navigation.hasPrevious
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

    /// Restores the previous session from `CredentialStore`, if there is one.
    func restoreSession() async {
        let stored = await Task.detached { CredentialStore.shared.read(.playbackSession) }.value
        guard let stored, session == .loggedOut else { return }
        storedCredentials = stored
        startSession(using: stored)
    }

    func logIn() {
        guard session != .authorizing else { return }
        previousRestart = nil
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
        previousRestart = nil
        navigation = nil
        reconnectTask?.cancel()
        pendingPlayback = nil
        storedCredentials = nil
        core.logOut()
        Task.detached { CredentialStore.shared.delete(.playbackSession) }
    }

    // MARK: - Transport

    /// Plays a context (playlist, album, artist, Liked Songs) or a track list,
    /// keeping the current shuffle and repeat settings.
    func play(_ request: PlayRequest, selectedTrack: Track? = nil) {
        previousRestart = nil
        var request = request
        request.shuffle = shuffle
        request.repeatMode = repeatMode.rawValue
        lastError = nil
        guard core.load(request) else {
            lastError = L10n.string("Couldn't start playback. Is Floe connected?")
            return
        }
        lastRequest = request
        navigation = nil
        contextURI = request.contextURI
        pendingTrack = selectedTrack.map(TrackInfo.init)
        isActiveDevice = true
        beginLoading(at: Double(request.positionMs ?? 0))
    }

    /// Starts a context with a deliberate shuffle state (page Play / Shuffle actions).
    func playContext(_ uri: String, shuffled: Bool) {
        if shuffle != shuffled { toggleShuffle() }
        play(PlayRequest(contextURI: uri))
    }

    func togglePlayPause() {
        isPlaying || isLoading ? pause() : resume()
    }

    func pause() {
        previousRestart = nil
        if isLoading { lastRequest?.startPlaying = false }
        core.pause()
        setAnchor(positionMs(at: Date()), playing: false)
    }

    func resume() {
        previousRestart = nil
        audio.start()
        if isActiveDevice && track != nil {
            core.play()
        } else {
            core.transferPlayback() // take over from the phone or another computer
            isActiveDevice = true
        }
    }

    func next() {
        guard isConnected else { return }
        pendingTrack = nil
        navigation = nil
        previousRestart = nil
        core.next()
        // A skip can be ignored at a context boundary or on an inactive device.
        // Only engine events establish loading and stop the playback clock.
    }

    /// Restart after 3 s or at the start of the playback history; otherwise go back.
    func previous() {
        guard isConnected else { return }
        if positionMs(at: Date()) >= 3000 || hasPreviousTrack == false {
            seek(toMs: 0)
        } else {
            pendingTrack = nil
            navigation = nil
            previousRestart = nil
            if isActiveDevice, !isLoading, let track {
                var request = lastRequest ?? PlayRequest(tracks: [track.uri])
                request.startURI = track.uri
                request.startIndex = nil
                request.positionMs = 0
                request.startPlaying = isPlaying
                previousRestart = (track.uri, request, Date())
            }
            core.previous()
        }
    }

    func seek(toMs ms: Double) {
        previousRestart = nil
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
        previousRestart = nil
        navigation = nil
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
        guard let track = displayTrack, pendingPlayback == nil else { return }
        var request = lastRequest ?? PlayRequest(tracks: [track.uri])
        request.startURI = track.uri
        request.positionMs = UInt32(clamping: Int(positionMs(at: Date())))
        request.startPlaying = isLoading ? request.startPlaying : isPlaying
        pendingPlayback = request
    }

    func dismissError() { lastError = nil }

    private var spotifyVolume: UInt16 { UInt16((volume * 65535).rounded()) }

    /// Perceptual curve over a 60 dB range, like librespot's default "log" mapping.
    private static func amplitude(_ x: Double) -> Float {
        x <= 0 ? 0 : Float((pow(1000, x) - 1) / 999)
    }

    // MARK: - Events

    private func beginLoading(at ms: Double) {
        isLoading = true
        setAnchor(ms, playing: false)
        idleTask?.cancel()
        audio.start()
    }

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
            Task.detached { CredentialStore.shared.write(blob, account: .playbackSession) }
        case let .loginFailed(message):
            log.error("Login failed: \(message, privacy: .public)")
            if hasConnected || reconnectAttempt > 0 { session = .connecting; scheduleReconnect() } else { session = .failed(message) }
        case .disconnected:
            rememberPlayback()
            log.notice("Session dropped; reconnecting")
            isActiveDevice = false
            navigation = nil
            previousRestart = nil
            session = .connecting
            isLoading = false
            setAnchor(positionMs(at: Date()), playing: false)
            scheduleReconnect()
        case .loggedOut:
            session = .loggedOut
            hasConnected = false
            track = nil
            pendingTrack = nil
            contextURI = nil
            navigation = nil
            previousRestart = nil
            isLoading = false
            setAnchor(0, playing: false)
        case let .track(info):
            previousRestart = nil
            track = info
            if pendingTrack?.uri == info.uri { pendingTrack = nil }
            nowPlaying.update()
        case let .loading(ms):
            previousRestart = nil
            isLoading = true
            setAnchor(ms, playing: false)
        case let .playing(ms):
            previousRestart = nil
            isLoading = false
            pendingTrack = nil
            isActiveDevice = true
            lastError = nil
            setAnchor(ms, playing: true)
        case let .paused(ms):
            previousRestart = nil
            isLoading = false
            pendingTrack = nil
            setAnchor(ms, playing: false)
        case let .position(ms):
            // A late correction can belong to a seek before a second Previous.
            // Explicit local seeks cancel intent when dispatched instead.
            setAnchor(ms, playing: isPlaying)
        case let .stopped(uri):
            let restart = previousRestart
            previousRestart = nil
            if let restart, isActiveDevice, restart.uri == uri, track?.uri == uri,
               Date().timeIntervalSince(restart.date) < 2 {
                isLoading = false
                isActiveDevice = false
                setAnchor(0, playing: false)
                play(restart.request)
                break
            }
            isLoading = false
            isActiveDevice = false
            navigation = nil
            pendingTrack = nil
            setAnchor(positionMs(at: Date()), playing: false)
        case .deviceInactive:
            previousRestart = nil
            navigation = nil
            isActiveDevice = false
        case .endOfTrack:
            break // Spirc moves on to the next track itself
        case .unavailable:
            previousRestart = nil
            isLoading = false
            pendingTrack = nil
            lastError = L10n.string("This track is unavailable. Try another song.")
        case let .navigation(uri, hasPrevious):
            navigation = (uri, hasPrevious)
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
