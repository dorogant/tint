import Foundation

/// Metadata for the loaded track, as reported by librespot.
struct TrackInfo: Equatable, Sendable {
    var uri: String
    var name: String
    var artists: [String]
    var album: String?
    var durationMs: Double
    var explicit: Bool
    var coverURL: URL?
}

/// Events from the Rust core. The JSON shapes are produced in
/// `core/src/lib.rs` (session) and `core/src/events.rs` (player).
enum CoreEvent: Sendable {
    case connecting
    case connected(username: String)
    /// Reusable librespot credentials (JSON) to keep in the Keychain.
    case credentials(Data)
    case loginFailed(String)
    case loggedOut
    case track(TrackInfo)
    case loading(positionMs: Double)
    case playing(positionMs: Double)
    case paused(positionMs: Double)
    case position(positionMs: Double)
    case stopped
    case endOfTrack
    case unavailable(uri: String)

    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        let position = (object["position_ms"] as? NSNumber)?.doubleValue ?? 0

        switch type {
        case "connecting":
            self = .connecting
        case "connected":
            self = .connected(username: object["username"] as? String ?? "")
        case "credentials":
            guard let credentials = object["credentials"] as? [String: Any],
                  let blob = try? JSONSerialization.data(withJSONObject: credentials)
            else { return nil }
            self = .credentials(blob)
        case "login_failed":
            self = .loginFailed(object["message"] as? String ?? "")
        case "logged_out":
            self = .loggedOut
        case "track":
            self = .track(TrackInfo(
                uri: object["uri"] as? String ?? "",
                name: object["name"] as? String ?? "",
                artists: object["artists"] as? [String] ?? [],
                album: object["album"] as? String,
                durationMs: (object["duration_ms"] as? NSNumber)?.doubleValue ?? 0,
                explicit: object["explicit"] as? Bool ?? false,
                coverURL: (object["cover_url"] as? String).flatMap(URL.init(string:))
            ))
        case "loading": self = .loading(positionMs: position)
        case "playing": self = .playing(positionMs: position)
        case "paused": self = .paused(positionMs: position)
        case "position": self = .position(positionMs: position)
        case "stopped": self = .stopped
        case "end_of_track": self = .endOfTrack
        case "unavailable": self = .unavailable(uri: object["uri"] as? String ?? "")
        default: return nil
        }
    }
}
