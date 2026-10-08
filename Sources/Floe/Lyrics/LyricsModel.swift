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
    /// By default the lines start at 0:00, 4 s apart; the performance test starts
    /// them at the current position and spaces them closer so lines keep changing.
    func showVisualTestFixture(from start: TimeInterval = 0, every spacing: TimeInterval = 4, count: Int = 8) {
        guard UserDefaults.standard.bool(forKey: "FloeVisualTest") else { return }
        let texts = ["A quiet start", "Colors drift across the glass", "A little rhythm in the light",
                     "Follow the sound", "Another synthetic line", "", "The shapes move slowly",
                     "And settle when we pause"]
        revision += 1
        isSynthetic = true
        state = .loaded(.synced((0..<count).map { index in
            LyricLine(id: index, time: start + Double(index) * spacing, text: texts[index % texts.count])
        }))
    }

}
