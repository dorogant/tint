import Foundation
import Observation

enum ConnectSection: String, CaseIterable, Identifiable {
    case queue, devices
    var id: Self { self }
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

    func refresh(_ section: ConnectSection) async {
        let epoch = beginRequest()
        defer { if epoch == generation { isLoading = false } }
        let permitted = await api.hasPlaybackPermission
        guard isCurrentRequest(epoch) else { return }
        needsPermission = !permitted
        guard permitted else { return }
        do {
            switch section {
            case .queue:
                let result = try await api.playbackQueue()
                guard isCurrentRequest(epoch) else { return }
                self.queue = Array(result.queue.prefix(100))
                current = result.currentlyPlaying
            case .devices:
                let result = try await api.playbackDevices()
                guard isCurrentRequest(epoch) else { return }
                devices = result.filter { $0.id != nil }
            }
        } catch is CancellationError {} catch {
            guard isCurrentRequest(epoch) else { return }
            self.error = Self.message(error)
        }
    }

    func connect(_ section: ConnectSection) async {
        guard !isLoading else { return }
        let epoch = beginRequest()
        defer { if epoch == generation { isLoading = false } }
        do {
            try await api.authorizePlaybackControls()
            guard isCurrentRequest(epoch) else { return }
            await refresh(section)
        } catch is CancellationError {} catch {
            guard isCurrentRequest(epoch) else { return }
            self.error = Self.message(error)
        }
    }

    func transfer(_ device: ConnectDevice) async {
        guard let id = device.id, !device.isRestricted, !transferring else { return }
        transferring = true
        let epoch = generation
        error = nil
        defer { transferring = false }
        do {
            try await api.transfer(to: id)
            guard isCurrentRequest(epoch) else { return }
            await refresh(.devices)
        } catch is CancellationError {} catch {
            guard isCurrentRequest(epoch) else { return }
            self.error = Self.message(error)
        }
    }

    private func beginRequest() -> Int {
        generation += 1
        isLoading = true
        error = nil
        return generation
    }

    private func isCurrentRequest(_ epoch: Int) -> Bool {
        epoch == generation && !Task.isCancelled
    }

    private static func message(_ error: Error) -> String {
        if error is TokenError { return L10n.string("Spotify authorization expired. Reconnect Queue and Devices.") }
        if let failure = error as? WebAPI.Failure, failure.status == 403 {
            return L10n.string("Spotify refused access. Reconnect Queue and Devices, or check your developer app's permissions.")
        }
        return error.localizedDescription
    }
}
