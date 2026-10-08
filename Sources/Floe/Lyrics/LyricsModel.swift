import Foundation
import Observation

@MainActor
@Observable
final class LyricsModel {
    enum State: Equatable {
        case idle, loading, loaded(LyricsService.Content), failed(String)
    }
    private(set) var trackURI: String?
    private(set) var isSynthetic = false
    private(set) var state: State = .idle
    @ObservationIgnored private let service: LyricsService
    @ObservationIgnored private var revision = 0

    init(service: LyricsService = LyricsService()) { self.service = service }

    func load(_ track: TrackInfo?) async {
        guard !Task.isCancelled else { return }
        trackURI = track?.uri
        isSynthetic = false
        revision += 1
        let revision = revision
        guard let track else { state = .idle; return }
        state = .loading
        do {
            let content = try await service.lyrics(for: .init(track))
            guard !Task.isCancelled, revision == self.revision else { return }
            state = .loaded(content)
        } catch {
            guard !Task.isCancelled, revision == self.revision else { return }
            state = .failed((error as? LyricsService.Failure)?.localizedDescription
                ?? L10n.string("Couldn't load lyrics. Try again later."))
        }
    }
    /// Synthetic content only for the opt-in visual self-test. Never export real lyrics.
    func showVisualTestFixture() {
        guard UserDefaults.standard.bool(forKey: "FloeVisualTest") else { return }
        revision += 1
        isSynthetic = true
        state = .loaded(.synced(LRC.parse("""
        [00:00] A quiet start
        [00:04] Colors drift across the glass
        [00:08] A little rhythm in the light
        [00:12] Follow the sound
        [00:16] Another synthetic line
        [00:20]
        [00:24] The shapes move slowly
        [00:28] And settle when we pause
        """)))
    }

}
