import CFloeCore
import Foundation
import os

/// What to play; encoded as the JSON `floe_load` expects (see `LoadSpec` in core/src/lib.rs).
struct PlayRequest: Encodable, Sendable {
    var contextURI: String?
    var tracks: [String]?
    var startURI: String?
    var startIndex: Int?
    var shuffle = false
    var repeatMode = 0
    var positionMs: UInt32?
    var startPlaying = true

    enum CodingKeys: String, CodingKey {
        case contextURI = "context_uri", tracks, startURI = "start_uri"
        case startIndex = "start_index", shuffle, repeatMode = "repeat", positionMs = "position_ms", startPlaying = "start_playing"
    }
}

extension PlaybackStart {
    init?(_ request: PlayRequest) {
        self.init(contextURI: request.contextURI, tracks: request.tracks, startURI: request.startURI,
                  startIndex: request.startIndex, positionMs: request.positionMs.map(Int.init))
    }
}

/// Swift face of Tint's playback engines: Spotify Soloist (default, official
/// headless Connect client over local WebSocket) and librespot (optional Rust
/// fallback). Every call returns immediately; outcomes arrive as `CoreEvent`s on
/// the main actor through `onEvent`.
@MainActor
final class FloeCore {
    static let shared = FloeCore()

    var onEvent: ((CoreEvent) -> Void)?
    var engine: PlaybackEngine = .soloist
    /// True only for `librespot`, which hands PCM to Tint's `AVAudioEngine`.
    /// Spotify Soloist outputs directly to Core Audio.
    var usesLocalAudioOutput: Bool { engine == .librespot }

    private let soloist = SoloistBackend()
    private let soloistTap = SoloistAudioTap()
    private var tapWanted = false

    /// The equalizer, which only Soloist needs help with: it plays its own
    /// sound, so Tint takes that over through the tap while this is on.
    var equalizer = Equalizer() {
        didSet {
            equalizerOutput.equalizer = equalizer
            guard equalizer.isOn != oldValue.isOn else { return }
            equalizerWanted = equalizer.isOn && soloistPlaying
            outputGaveUp = false
            updateTap()
        }
    }
    private let equalizerOutput = EqualizerOutput()
    /// Soloist's last word on whether it's playing.
    private var soloistPlaying = false
    /// Soloist is playing, or was just told to or just stopped: the times the
    /// equalizer holds its sound.
    private var equalizerWanted = false
    private var equalizerRelease: Task<Void, Never>?
    private var equalizerWatch: Task<Void, Never>?
    /// Tint's output stopped asking for sound and two fresh starts didn't
    /// help, so Soloist keeps its own voice until the equalizer is switched
    /// again, the output device changes or Soloist restarts.
    private var outputGaveUp = false
    /// The tap has delivered Soloist's sound, so muting Soloist won't leave
    /// silence. Without the System Audio Recording permission the tap still
    /// starts but hears nothing, and the system offers no way to ask which it
    /// is. Kept across launches, and dropped if the tap goes deaf again.
    private var tapHearsSoloist = UserDefaults.standard.bool(forKey: "soloistTapHeard") {
        didSet { if tapHearsSoloist != oldValue { UserDefaults.standard.set(tapHearsSoloist, forKey: "soloistTapHeard") } }
    }

    /// Starts a request on the Connect device of that name through the Web API
    /// (`PlaybackStarter`), for what Soloist's one-URI `play` can't say: a
    /// playlist or album from a chosen song, and a list of songs. The app sets it.
    var startRemotely: (@Sendable (PlaybackStart, String) async throws -> Void)?
    private var remoteStart: Task<Void, Never>?
    /// Bumped by every load, so an answer to an earlier one is dropped.
    private var loadGeneration = 0
    /// Pause arrived while the Web API was still starting the song.
    private var pausedWhileStarting = false
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "core")

    /// Room for about a hundred songs at 320 kbps (a four-minute one is ~10 MB). A song
    /// in the cache starts without asking the CDN for its address or downloading
    /// anything, and seeking in it never waits for the network.
    private static let audioCacheBytes: UInt64 = 1 << 30

    private init() {
        floe_init(floeEventCallback, nil)
        // In Caches, beside the covers: macOS may empty it when the disk fills, and it stays out of backups.
        let audio = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.antonchurchyn.floe/Audio")
        floe_set_audio_cache(audio.path, Self.audioCacheBytes)
        soloist.onEvent = { [weak self] event in
            guard let self, self.engine == .soloist else { return }
            self.followSoloist(event)
            self.onEvent?(event)
        }
        equalizerOutput.onConfigurationChange = { [weak self] in
            // New headphones may run at another rate: take the sound over afresh.
            self?.outputGaveUp = false
            self?.soloistTap.stop()
            self?.updateTap()
        }
    }

    /// Spotify's own client ID, which librespot's session login requires
    /// (the app's Web API client ID can't log a playback session in).
    var sessionClientID: String { String(cString: floe_session_client_id()) }

    func startSoloist(apiKey: String, volume: UInt16) {
        floe_logout()
        engine = .soloist
        soloist.start(apiKey: apiKey, volume: volume)
    }

    func stopSoloist() {
        remoteStart?.cancel()
        remoteStart = nil
        loadGeneration += 1
        soloistPlaying = false
        outputGaveUp = false
        releaseEqualizer(after: nil)
        soloistTap.stop()
        soloist.stop()
    }

    func setSoloistTapRunning(_ running: Bool) {
        tapWanted = running
        updateTap()
    }

    // MARK: - The tap on Soloist: for the visuals, and for the equalizer

    private func followSoloist(_ event: CoreEvent) {
        switch event {
        case .playing:
            soloistPlaying = true
            holdEqualizer()
            // Also the moment the visuals' tap can start, if Soloist had no audio device before.
            updateTap()
        case .paused, .stopped, .deviceInactive:
            soloistPlaying = false
            // Not at once: the last of the sound is still on its way out, and a
            // pause between two songs shouldn't hand the sound back and forth.
            releaseEqualizer(after: .seconds(3))
        case .disconnected, .loggedOut, .loginFailed:
            soloistPlaying = false
            releaseEqualizer(after: nil)
        default:
            break
        }
    }

    /// Takes the sound for the equalizer before Soloist is told to play, so the
    /// song doesn't open unshaped and then switch a moment later. If Soloist
    /// never starts, it is let go again.
    private func prepareEqualizerForPlaying() {
        guard engine == .soloist, equalizer.isOn else { return }
        holdEqualizer()
        updateTap()
        if !soloistPlaying { releaseEqualizer(after: .seconds(10)) }
    }

    private func holdEqualizer() {
        equalizerRelease?.cancel()
        equalizerRelease = nil
        equalizerWanted = equalizer.isOn
    }

    private func releaseEqualizer(after delay: Duration?) {
        equalizerRelease?.cancel()
        equalizerRelease = nil
        guard let delay, equalizerWanted else {
            equalizerWanted = false
            updateTap()
            return
        }
        equalizerRelease = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self, !self.soloistPlaying else { return }
            self.equalizerRelease = nil
            self.equalizerWanted = false
            self.updateTap()
        }
    }

    /// One tap serves both. While the equalizer holds the sound, the tap mutes
    /// Soloist and feeds `equalizerOutput`; otherwise it only listens, and only
    /// while the visuals want it.
    private func updateTap() {
        guard engine == .soloist, let pid = soloist.processIdentifier else {
            soloistTap.stop()
            equalizerOutput.stop()
            watchEqualizer(false)
            EqualizerStatus.shared.state = .idle
            return
        }
        let wanted = equalizer.isOn && equalizerWanted
        if wanted, tapHearsSoloist, !outputGaveUp, takeOver(pid: pid) {
            EqualizerStatus.shared.state = .shaping
        } else {
            equalizerOutput.stop()
            // Until the tap is known to hear Soloist, it listens with Soloist
            // still audible, and the watch below takes over once sound arrives.
            if tapWanted || (wanted && !tapHearsSoloist) {
                soloistTap.start(pid: pid, takingOver: nil)
            } else {
                soloistTap.stop()
            }
            EqualizerStatus.shared.state = wanted ? .listening : .idle
        }
        watchEqualizer(wanted)
    }

    private func takeOver(pid: pid_t) -> Bool {
        if soloistTap.isTakingOver, equalizerOutput.start(sampleRate: soloistTap.sampleRate) { return true }
        guard soloistTap.start(pid: pid, takingOver: equalizerOutput.ring) == .started else { return false }
        if equalizerOutput.start(sampleRate: soloistTap.sampleRate) { return true }
        // No output to play it through: give Soloist its voice back.
        soloistTap.stop()
        return false
    }

    /// Once a second while the equalizer is wanted, the two ways muting Soloist
    /// could leave silence are checked, and Soloist gets its voice back if
    /// either holds:
    ///
    /// - Has the tap heard anything? The first sound through a listening tap
    ///   proves it can be trusted with the mute. Ten seconds of nothing while
    ///   Soloist says it's playing means it can't (the permission was taken away).
    /// - Is Tint's output still asking for the sound? If the tap delivers and
    ///   nothing reads for two seconds (an engine left stopped by sleep or a
    ///   vanished device), the output is rebuilt, and after two tries given up on.
    private func watchEqualizer(_ on: Bool) {
        guard on else {
            equalizerWatch?.cancel()
            equalizerWatch = nil
            return
        }
        guard equalizerWatch == nil else { return }
        equalizerWatch = Task { [weak self] in
            var heard = self?.heardSoFar ?? 0
            var silentSeconds = 0
            var turns = self?.equalizerOutput.ring.readerTurns ?? 0
            var stalledSeconds = 0, rebuilds = 0, healthySeconds = 0
            while (try? await Task.sleep(for: .seconds(1))) != nil, let self {
                let now = self.heardSoFar
                let turnsNow = self.equalizerOutput.ring.readerTurns
                if self.soloistTap.isTakingOver, turnsNow == turns {
                    stalledSeconds += 1
                    healthySeconds = 0
                    if stalledSeconds >= 2 {
                        stalledSeconds = 0
                        rebuilds += 1
                        self.log.notice("The equalizer's output stopped asking for sound (\(rebuilds)); \(rebuilds > 2 ? "leaving Soloist to play" : "starting it afresh", privacy: .public)")
                        self.soloistTap.stop()
                        self.equalizerOutput.discard()
                        if rebuilds > 2 { self.outputGaveUp = true }
                        self.updateTap()
                    }
                } else {
                    stalledSeconds = 0
                    healthySeconds += 1
                    if healthySeconds >= 30 { rebuilds = 0 }
                }
                turns = turnsNow
                if now != heard {
                    heard = now
                    silentSeconds = 0
                    if !self.tapHearsSoloist {
                        self.tapHearsSoloist = true
                        self.updateTap()
                    }
                } else if self.soloistPlaying, self.soloistTap.isTakingOver {
                    silentSeconds += 1
                    if silentSeconds >= 10 {
                        self.log.notice("The tap went silent while Soloist plays; unmuting Soloist")
                        self.tapHearsSoloist = false
                        silentSeconds = 0
                        self.updateTap()
                    }
                } else {
                    silentSeconds = 0
                }
            }
        }
    }

    /// Deliveries with sound in them, whichever way the tap is running.
    private var heardSoFar: Int { soloistTap.soundingDeliveries }

    func logIn(accessToken: String, volume: UInt16) {
        stopSoloist()
        engine = .librespot
        floe_login_token(accessToken, volume)
    }

    func logIn(storedCredentials: Data, volume: UInt16) {
        stopSoloist()
        engine = .librespot
        floe_login_stored(String(decoding: storedCredentials, as: UTF8.self), volume)
    }

    func logOut() {
        releaseEqualizer(after: nil)
        soloistTap.stop()
        switch engine {
        case .soloist: soloist.logOut()
        case .librespot: floe_logout()
        }
    }

    func configure(_ configuration: PlaybackConfiguration) {
        floe_configure_playback(UInt16(clamping: configuration.bitrate), configuration.normalization, configuration.gapless)
    }

    /// Returns false for a malformed request or when no session is up.
    @discardableResult
    func load(_ request: PlayRequest) -> Bool {
        switch engine {
        case .soloist:
            return loadSoloist(request)
        case .librespot:
            guard let json = try? JSONEncoder().encode(request) else { return false }
            return floe_load(String(decoding: json, as: UTF8.self))
        }
    }

    /// Through the Web API when the request needs more than one URI and the
    /// user allowed playback control; otherwise, and if Spotify refuses,
    /// Soloist plays the song (or the context) by itself.
    private func loadSoloist(_ request: PlayRequest) -> Bool {
        remoteStart?.cancel()
        remoteStart = nil
        loadGeneration += 1
        pausedWhileStarting = false
        guard soloist.isReady else { return false }
        if request.startPlaying { prepareEqualizerForPlaying() }
        guard let startRemotely, let playback = PlaybackStart(request) else { return soloist.load(request) }
        let generation = loadGeneration
        soloist.prepare(for: request)
        remoteStart = Task {
            do {
                try await startRemotely(playback, SoloistBackend.deviceName)
                guard generation == loadGeneration else { return }
                if !request.startPlaying || pausedWhileStarting { soloist.pause() }
            } catch {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                log.notice("Web API start failed (\(String(describing: error), privacy: .public)); playing the song alone")
                var alone = request
                if pausedWhileStarting { alone.startPlaying = false }
                soloist.load(alone)
            }
            remoteStart = nil
        }
        return true
    }

    func play() {
        switch engine {
        case .soloist:
            pausedWhileStarting = false
            prepareEqualizerForPlaying()
            soloist.play()
        case .librespot: floe_play()
        }
    }

    func pause() {
        switch engine {
        case .soloist:
            if remoteStart != nil { pausedWhileStarting = true }
            soloist.pause()
        case .librespot: floe_pause()
        }
    }

    func next() {
        switch engine {
        case .soloist:
            prepareEqualizerForPlaying()
            soloist.next()
        case .librespot: floe_next()
        }
    }

    func previous() {
        switch engine {
        case .soloist:
            prepareEqualizerForPlaying()
            soloist.previous()
        case .librespot: floe_previous()
        }
    }

    func seek(toMs ms: UInt32) {
        switch engine {
        case .soloist: soloist.seek(toMs: ms)
        case .librespot: floe_seek(ms)
        }
    }

    func setShuffle(_ on: Bool) {
        switch engine {
        case .soloist: soloist.setShuffle(on)
        case .librespot: floe_set_shuffle(on)
        }
    }

    func setRepeat(_ mode: RepeatMode) {
        switch engine {
        case .soloist: soloist.setRepeat(mode)
        case .librespot: floe_set_repeat(UInt8(mode.rawValue))
        }
    }

    func setVolume(_ volume: UInt16) {
        switch engine {
        case .soloist: soloist.setVolume(volume)
        case .librespot: floe_set_volume(volume)
        }
    }

    func transferPlayback() {
        switch engine {
        case .soloist: soloist.transferPlayback()
        case .librespot: floe_transfer()
        }
    }

    @discardableResult func addToQueue(_ uri: String) -> Bool {
        switch engine {
        case .soloist: soloist.addToQueue(uri)
        case .librespot: floe_add_to_queue(uri)
        }
    }

    func takeStats() -> FloeStats {
        var stats = FloeStats()
        floe_take_stats(&stats)
        return stats
    }

    func deliver(_ event: CoreEvent) {
        guard engine == .librespot else { return }
        onEvent?(event)
    }
}

/// Called by Rust on a tokio worker thread. Decode there, deliver in order on main:
/// the main queue keeps FIFO order (a Task per event wouldn't) and runs on the main actor.
private func floeEventCallback(_ context: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>) {
    let data = Data(bytes: json, count: strlen(json))
    guard let event = CoreEvent(json: data) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { FloeCore.shared.deliver(event) }
    }
}
