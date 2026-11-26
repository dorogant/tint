import Foundation

struct ConnectDevice: Decodable, Identifiable, Sendable {
    let id: String?
    let name: String
    let type: String
    let isActive: Bool
    let isRestricted: Bool
    let volumePercent: Int?
    let supportsVolume: Bool?
}

struct PlaybackQueue: Decodable, Sendable {
    let currentlyPlaying: Track?
    let queue: [Track]
    enum CodingKeys: String, CodingKey { case currentlyPlaying, queue }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentlyPlaying = (try? c.decodeIfPresent(Track.self, forKey: .currentlyPlaying)) ?? nil
        queue = (try c.decodeIfPresent([Lossy<Track>].self, forKey: .queue) ?? []).compactMap(\.value)
    }
}

protocol PlaybackAPI: Sendable {
    var hasPlaybackPermission: Bool { get async }
    func authorizePlaybackControls() async throws
    func playbackQueue() async throws -> PlaybackQueue
    func playbackDevices() async throws -> [ConnectDevice]
    func transfer(to id: String) async throws
    func startPlayback(_ playback: PlaybackStart, on deviceID: String) async throws
}

/// What `PUT me/player/play` starts: a context at one of its songs, or a list
/// of songs at one of them. Spotify Soloist's own `play` takes a single URI, so
/// it can do neither: a song chosen in a playlist played alone, with whatever
/// the queue held after it.
struct PlaybackStart: Encodable, Equatable, Sendable {
    struct Offset: Encodable, Equatable, Sendable {
        var uri: String?
        var position: Int?
    }

    var contextURI: String?
    var uris: [String]?
    var offset: Offset?
    var positionMs: Int?

    enum CodingKeys: String, CodingKey {
        case contextURI = "context_uri", uris, offset, positionMs = "position_ms"
    }

    /// A list keeps this many songs, at most `listBefore` of them ahead of the
    /// one that starts: the request stays small and Previous still has somewhere to go.
    static let listLimit = 200
    static let listBefore = 50

    /// nil when one URI says it all (a whole context, a single song) or when
    /// the song to start isn't among `tracks`.
    init?(contextURI: String?, tracks: [String]?, startURI: String?, startIndex: Int?, positionMs: Int? = nil) {
        if let contextURI, let startURI, Self.takesOffset(contextURI) {
            self.contextURI = contextURI
            offset = Offset(uri: startURI)
        } else if let tracks, tracks.count > 1, startURI != nil || contextURI == nil {
            let index: Int
            if let startURI {
                // The index says which of two copies of a song was chosen.
                if let startIndex, tracks.indices.contains(startIndex), tracks[startIndex] == startURI {
                    index = startIndex
                } else if let found = tracks.firstIndex(of: startURI) {
                    index = found
                } else {
                    return nil
                }
            } else {
                index = min(max(startIndex ?? 0, 0), tracks.count - 1)
            }
            let window = Self.window(of: tracks, around: index)
            uris = window.uris
            offset = Offset(position: window.position)
        } else {
            return nil
        }
        self.positionMs = positionMs.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The Web API takes an offset only for albums and playlists; for an artist
    /// it answers 400 ("Can't have offset for context type: ARTIST").
    static func takesOffset(_ contextURI: String) -> Bool {
        contextURI.hasPrefix("spotify:album:") || contextURI.hasPrefix("spotify:playlist:")
    }

    static func window(of tracks: [String], around index: Int) -> (uris: [String], position: Int) {
        guard tracks.count > listLimit else { return (tracks, index) }
        let lower = min(max(0, index - listBefore), tracks.count - listLimit)
        return (Array(tracks[lower..<lower + listLimit]), index - lower)
    }
}

/// Starts playback on Tint's own Connect device through the Web API. The device
/// is found by name once and remembered until Spotify stops knowing its ID.
actor PlaybackStarter {
    enum Failure: Error { case notPermitted, deviceNotFound }

    private let api: any PlaybackAPI
    private var device: (name: String, id: String)?

    init(api: any PlaybackAPI) { self.api = api }

    func start(_ playback: PlaybackStart, onDeviceNamed name: String) async throws {
        guard await api.hasPlaybackPermission else { throw Failure.notPermitted }
        if let device, device.name == name {
            do {
                return try await api.startPlayback(playback, on: device.id)
            } catch let failure as WebAPI.Failure where failure.status == 404 {
                self.device = nil
            }
        }
        let named = try await api.playbackDevices().filter { $0.name == name && $0.id != nil && !$0.isRestricted }
        // Two Macs can both run Tint; the one that's playing is this one more often than not.
        guard let id = (named.first(where: \.isActive) ?? named.first)?.id else { throw Failure.deviceNotFound }
        try await api.startPlayback(playback, on: id)
        device = (name, id)
    }
}

extension WebAPI: PlaybackAPI {
    var hasPlaybackPermission: Bool { get async { await user.hasPlaybackControls } }
    func authorizePlaybackControls() async throws { try await user.authorize(playbackControls: true) }
    func playbackQueue() async throws -> PlaybackQueue { try await get("me/player/queue") }
    func playbackDevices() async throws -> [ConnectDevice] {
        struct Response: Decodable { let devices: [ConnectDevice] }
        let response: Response = try await get("me/player/devices")
        return response.devices
    }
    func transfer(to id: String) async throws {
        struct Transfer: Encodable { let device_ids: [String]; let play = false }
        try await send("PUT", "me/player", body: JSONEncoder().encode(Transfer(device_ids: [id])))
    }
    func startPlayback(_ playback: PlaybackStart, on deviceID: String) async throws {
        try await send("PUT", "me/player/play", ["device_id": deviceID], body: JSONEncoder().encode(playback))
    }
}

