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

/// Swift face of the Rust playback core. Every call returns immediately;
/// outcomes arrive as `CoreEvent`s on the main actor through `onEvent`.
@MainActor
final class FloeCore {
    static let shared = FloeCore()

    var onEvent: ((CoreEvent) -> Void)?

    private init() {
        floe_init(floeEventCallback, nil)
    }

    /// Spotify's own client ID, which librespot's session login requires
    /// (the app's Web API client ID can't log a playback session in).
    var sessionClientID: String { String(cString: floe_session_client_id()) }

    func logIn(accessToken: String, volume: UInt16) { floe_login_token(accessToken, volume) }

    func logIn(storedCredentials: Data, volume: UInt16) {
        floe_login_stored(String(decoding: storedCredentials, as: UTF8.self), volume)
    }

    func logOut() { floe_logout() }

    func configure(_ configuration: PlaybackConfiguration) {
        floe_configure_playback(UInt16(clamping: configuration.bitrate), configuration.normalization, configuration.gapless)
    }

    /// Returns false for a malformed request or when no session is up.
    @discardableResult
    func load(_ request: PlayRequest) -> Bool {
        guard let json = try? JSONEncoder().encode(request) else { return false }
        return floe_load(String(decoding: json, as: UTF8.self))
    }

    func play() { floe_play() }
    func pause() { floe_pause() }
    func next() { floe_next() }
    func previous() { floe_previous() }
    func seek(toMs ms: UInt32) { floe_seek(ms) }
    func setShuffle(_ on: Bool) { floe_set_shuffle(on) }
    func setRepeat(_ mode: RepeatMode) { floe_set_repeat(UInt8(mode.rawValue)) }
    func setVolume(_ volume: UInt16) { floe_set_volume(volume) }
    func transferPlayback() { floe_transfer() }
    @discardableResult func addToQueue(_ uri: String) -> Bool { floe_add_to_queue(uri) }

    func takeStats() -> FloeStats {
        var stats = FloeStats()
        floe_take_stats(&stats)
        return stats
    }

    func deliver(_ event: CoreEvent) {
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
