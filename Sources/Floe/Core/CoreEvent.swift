import Foundation

/// Metadata for the loaded track, as reported by librespot.
struct TrackInfo: Equatable, Sendable {
    struct Artist: Equatable, Sendable {
        var name: String
        var uri: String?
    }

    var uri: String
    var name: String
    var artists: [Artist]
    var album: String?
    var durationMs: Double
    var explicit: Bool
    var coverURL: URL?

    var artistLine: String { artists.map(\.name).joined(separator: ", ") }
}

extension TrackInfo {
    /// A row already has enough metadata to show the selection while audio loads.
    init(_ track: Track) {
        self.init(uri: track.uri, name: track.name,
                  artists: track.artists.map { Artist(name: $0.name, uri: $0.uri) },
                  album: track.album?.name, durationMs: Double(track.durationMs),
                  explicit: track.explicit ?? false,
                  coverURL: track.album?.images?.best(forPixels: 720))
    }
}

enum RepeatMode: Int, Sendable {
    case off = 0, context = 1, track = 2

    var next: RepeatMode {
        switch self {
        case .off: .context
        case .context: .track
        case .track: .off
        }
    }
}

/// Events from the Rust core. The JSON shapes are produced in
/// `core/src/lib.rs` (session) and `core/src/events.rs` (player).
enum CoreEvent: Sendable {
    case connecting
    /// Soloist is running and advertising on Spotify Connect, waiting for the user
    /// to select `deviceName` in a Spotify app to finish pairing.
    case awaitingPairing(deviceName: String)
    case connected(username: String)
    /// Reusable librespot credentials (JSON) to keep in `CredentialStore`.
    case credentials(Data)
    /// `refused`: Spotify turned the credentials down, so the same ones won't work later either.
    case loginFailed(String, refused: Bool)
    case disconnected
    case loggedOut
    case track(TrackInfo)
    case loading(positionMs: Double)
    case playing(positionMs: Double)
    case paused(positionMs: Double)
    case position(positionMs: Double)
    case stopped(uri: String?)
    /// Another Spotify Connect device took over; distinct from a queue boundary.
    case deviceInactive
    case endOfTrack
    case unavailable(uri: String)
    /// Playback history from the engine, scoped to its current track.
    case navigation(uri: String, hasPrevious: Bool)
    case shuffle(Bool)
    case repeatMode(RepeatMode)
    /// Spotify volume, 0…65535 (local or remote change).
    case volume(UInt16)

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
            self = .loginFailed(object["message"] as? String ?? "", refused: object["refused"] as? Bool ?? false)
        case "disconnected":
            self = .disconnected
        case "logged_out":
            self = .loggedOut
        case "track":
            let artists = (object["artists"] as? [[String: Any]] ?? []).map {
                TrackInfo.Artist(name: $0["name"] as? String ?? "", uri: $0["uri"] as? String)
            }
            self = .track(TrackInfo(
                uri: object["uri"] as? String ?? "",
                name: object["name"] as? String ?? "",
                artists: artists,
                album: object["album"] as? String,
                durationMs: (object["duration_ms"] as? NSNumber)?.doubleValue ?? 0,
                explicit: object["explicit"] as? Bool ?? false,
                coverURL: (object["cover_url"] as? String).flatMap(URL.init(string:))
            ))
        case "loading": self = .loading(positionMs: position)
        case "playing": self = .playing(positionMs: position)
        case "paused": self = .paused(positionMs: position)
        case "position": self = .position(positionMs: position)
        case "stopped": self = .stopped(uri: object["uri"] as? String)
        case "device_inactive": self = .deviceInactive
        case "end_of_track": self = .endOfTrack
        case "unavailable": self = .unavailable(uri: object["uri"] as? String ?? "")
        case "navigation":
            guard let uri = object["uri"] as? String,
                  let hasPrevious = object["has_previous"] as? Bool else { return nil }
            self = .navigation(uri: uri, hasPrevious: hasPrevious)
        case "shuffle": self = .shuffle(object["shuffle"] as? Bool ?? false)
        case "repeat": self = .repeatMode(RepeatMode(rawValue: object["mode"] as? Int ?? 0) ?? .off)
        case "volume": self = .volume(UInt16(clamping: object["volume"] as? Int ?? 0))
        default:
            return nil
        }
    }
}
