import CFloeCore
import Foundation

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
            if case .playing = event, self.tapWanted, let pid = self.soloist.processIdentifier {
                self.soloistTap.start(pid: pid)
            }
            self.onEvent?(event)
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
        soloistTap.stop()
        soloist.stop()
    }

    func setSoloistTapRunning(_ running: Bool) {
        tapWanted = running
        guard running, engine == .soloist, let pid = soloist.processIdentifier else {
            soloistTap.stop()
            return
        }
        soloistTap.start(pid: pid)
    }

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
            return soloist.load(request)
        case .librespot:
            guard let json = try? JSONEncoder().encode(request) else { return false }
            return floe_load(String(decoding: json, as: UTF8.self))
        }
    }

    func play() {
        switch engine {
        case .soloist: soloist.play()
        case .librespot: floe_play()
        }
    }

    func pause() {
        switch engine {
        case .soloist: soloist.pause()
        case .librespot: floe_pause()
        }
    }

    func next() {
        switch engine {
        case .soloist: soloist.next()
        case .librespot: floe_next()
        }
    }

    func previous() {
        switch engine {
        case .soloist: soloist.previous()
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
