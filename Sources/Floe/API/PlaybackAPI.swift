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
}

