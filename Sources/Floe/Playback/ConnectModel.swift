import Foundation
import Observation

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

/// Requests run only while their panel is open. Remote queue ordering stays Spotify's.
@MainActor
@Observable
final class ConnectModel {
    private(set) var queue: [Track] = []
    private(set) var devices: [ConnectDevice] = []
    private(set) var current: Track?
    private(set) var needsPermission = false
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var transferring = false
    @ObservationIgnored private let api: any PlaybackAPI
    @ObservationIgnored private var generation = 0

    init(api: any PlaybackAPI) { self.api = api }

    func refresh(queue: Bool) async {
        generation += 1
        let epoch = generation
        isLoading = true
        error = nil
        defer { if epoch == generation { isLoading = false } }
        let permitted = await api.hasPlaybackPermission
        guard epoch == generation, !Task.isCancelled else { return }
        needsPermission = !permitted
        guard permitted else { return }
        do {
            if queue {
                let result = try await api.playbackQueue()
                guard !Task.isCancelled, epoch == generation else { return }
                self.queue = Array(result.queue.prefix(100))
                current = result.currentlyPlaying
            } else {
                let result = try await api.playbackDevices()
                guard !Task.isCancelled, epoch == generation else { return }
                devices = result.filter { $0.id != nil }
            }
        } catch is CancellationError {} catch {
            guard epoch == generation else { return }
            self.error = Self.message(error)
        }
    }

    func connect(queue: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        do {
            try await api.authorizePlaybackControls()
            isLoading = false
            await refresh(queue: queue)
        } catch is CancellationError { isLoading = false }
        catch { isLoading = false; self.error = Self.message(error) }
    }

    func transfer(_ device: ConnectDevice) async {
        guard let id = device.id, !device.isRestricted, !transferring else { return }
        transferring = true
        let epoch = generation
        error = nil
        defer { transferring = false }
        do {
            try await api.transfer(to: id)
            if epoch == generation { await refresh(queue: false) }
        }
        catch { self.error = Self.message(error) }
    }

    private static func message(_ error: Error) -> String {
        if error is TokenError { return L10n.string("Spotify authorization expired. Reconnect Queue and Devices.") }
        if let failure = error as? WebAPI.Failure, failure.status == 403 {
            return L10n.string("Spotify refused access. Reconnect Queue and Devices, or check your developer app's permissions.")
        }
        return error.localizedDescription
    }
}
