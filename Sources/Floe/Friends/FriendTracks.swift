import Foundation

/// Spotify's own record of songs friends play, for the one song each card
/// leads with: its cover, its album and its artists as links. Asked one at a
/// time and kept, so a page of friends is at most one request per friend, once
/// per song. ListenBrainz is told nothing of it.
@MainActor
final class FriendTracks {
    static let shared = FriendTracks()

    private var known: [String: Track] = [:]
    private var order: [String] = []
    private var asking: [String: Task<Track?, Never>] = [:]
    /// The last request started; the next waits for it, so a page opening doesn't burst.
    private var last: Task<Track?, Never>?
    private static let capacity = 200

    func cached(_ id: String) -> Track? { known[id] }

    func track(_ id: String, api: WebAPI) async -> Track? {
        if let track = known[id] { return track }
        if let running = asking[id] { return await running.value }
        let task = Task { [last] in
            _ = await last?.value
            return try? await api.track(id)
        }
        asking[id] = task
        last = task
        let track = await task.value
        asking[id] = nil
        if let track {
            known[id] = track
            order.append(id)
            if order.count > Self.capacity { known[order.removeFirst()] = nil }
        }
        return track
    }
}
