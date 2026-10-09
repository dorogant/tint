import AppKit
import MediaPlayer

/// Publishes the current track to Control Center / the menu-bar Now Playing widget
/// and routes media keys (and AirPods controls) back to the player.
@MainActor
final class NowPlayingController {
    private weak var model: PlayerModel?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    init(model: PlayerModel) {
        self.model = model
        let commands = MPRemoteCommandCenter.shared()
        bind(commands.playCommand) { $0.resume() }
        bind(commands.pauseCommand) { $0.pause() }
        bind(commands.togglePlayPauseCommand) { $0.togglePlayPause() }
        bind(commands.nextTrackCommand) { $0.next() }
        bind(commands.previousTrackCommand) { $0.previous() }
        commands.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.model?.seek(toMs: seconds * 1000) }
            return .success
        }
    }

    /// Handlers hop to the main actor: MediaPlayer doesn't promise which thread calls them.
    private func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerModel) -> Void) {
        command.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                if let model = self?.model { action(model) }
            }
            return .success
        }
    }

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let model, let track = model.displayTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyPlaybackDuration: track.durationMs / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.positionMs(at: Date()) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: model.isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if track.coverURL == artworkURL, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            loadArtwork(track.coverURL)
        }
        center.nowPlayingInfo = info
        center.playbackState = model.isPlaying ? .playing : .paused
    }

    private func loadArtwork(_ url: URL?) {
        if url == artworkURL, artworkTask != nil { return }
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = url
        artwork = nil
        guard let url else { return }
        artworkTask = Task {
            // The size Now Playing already decoded (CoverAppearance), not a second 1 MB copy.
            let image = await ArtworkCache.shared.image(for: url, pixels: 720)
            guard !Task.isCancelled, artworkURL == url else { return }
            artworkTask = nil
            guard let image else { return }
            artwork = Self.makeArtwork(image)
            update()
        }
    }

    /// Built outside the main actor on purpose: MediaPlayer calls the request
    /// handler on its own queue, and a main-actor-isolated closure traps there.
    private nonisolated static func makeArtwork(_ image: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: image.width, height: image.height)
        let nsImage = NSImage(cgImage: image, size: size)
        return MPMediaItemArtwork(boundsSize: size) { _ in nsImage }
    }
}
