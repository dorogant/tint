import CFloeCore
import Foundation

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

    func logIn(accessToken: String) { floe_login_token(accessToken) }

    func logIn(storedCredentials: Data) {
        floe_login_stored(String(decoding: storedCredentials, as: UTF8.self))
    }

    func logOut() { floe_logout() }

    /// Returns false for an invalid URI or when no session is up.
    @discardableResult
    func load(_ uri: String, play: Bool = true, positionMs: UInt32 = 0) -> Bool {
        floe_load(uri, play, positionMs)
    }

    func play() { floe_play() }
    func pause() { floe_pause() }
    func seek(toMs ms: UInt32) { floe_seek(ms) }
    func stop() { floe_stop() }

    func takeStats() -> FloeStats {
        var stats = FloeStats()
        floe_take_stats(&stats)
        return stats
    }

    fileprivate func deliver(_ event: CoreEvent) {
        onEvent?(event)
    }
}

/// Called by Rust on a tokio worker thread. Decode there, deliver in order on main.
private func floeEventCallback(_ context: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>) {
    let data = Data(bytes: json, count: strlen(json))
    guard let event = CoreEvent(json: data) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { FloeCore.shared.deliver(event) }
    }
}
