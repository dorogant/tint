import Foundation
import Observation
import SwiftUI

// Deliberately isolated from auth, the audio core and the lyrics service.
// The benchmark compiles the production view against a synthetic playback clock.
@MainActor @Observable final class PlayerModel {
    struct Track { let uri: String }
    let displayTrack: Track? = Track(uri: "synthetic:lyrics-rendering")
    var isPlaying = true
    private(set) var playbackAnchor = Date()
    private var offset = 0.0
    @ObservationIgnored private(set) var positionReads = 0

    func positionMs(at date: Date) -> Double {
        positionReads += 1
        return offset + (isPlaying ? date.timeIntervalSince(playbackAnchor) * 1_000 : 0)
    }

    func seek(toMs milliseconds: Double) {
        offset = milliseconds
        playbackAnchor = Date()
    }
}

@MainActor @Observable final class LyricsModel {
    enum Content: Equatable { case instrumental, missing, plain(String), synced([LyricLine]) }
    enum State: Equatable { case idle, loading, loaded(Content), failed(String) }
    let trackURI: String? = "synthetic:lyrics-rendering"
    let isSynthetic = true
    var state: State = .idle
    func load(_ track: PlayerModel.Track?) async {}

    func fixture(from start: TimeInterval, every spacing: TimeInterval) {
        let text = ["A quiet start", "Colors drift across the glass", "A little rhythm in the light",
                    "Follow the sound", "Another synthetic line", "", "The shapes move slowly",
                    "And settle when we pause"]
        state = .loaded(.synced((0..<80).map {
            LyricLine(id: $0, time: start + Double($0) * spacing, text: text[$0 % text.count])
        }))
    }
}

enum Theme {
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)
}
enum L10n { static func string(_ text: String) -> String { text } }
struct CoverPalette { let highlight = Color(red: 0.25, green: 0.7, blue: 0.95) }
private struct CoverPaletteKey: EnvironmentKey { static let defaultValue = CoverPalette() }
extension EnvironmentValues {
    var coverPalette: CoverPalette {
        get { self[CoverPaletteKey.self] }
        set { self[CoverPaletteKey.self] = newValue }
    }
}
struct LoadingView: View { var body: some View { ProgressView() } }
struct MessageView: View {
    let systemImage: String
    let message: String
    var body: some View { Label(message, systemImage: systemImage) }
}
