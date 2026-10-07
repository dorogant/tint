import SwiftUI

/// Phase 1 window: log in, play a track URI, pause/seek, volume, RAM readout.
/// The real UI (Library, Now Playing, Lyrics) replaces this from Phase 2 on.
struct PlayerView: View {
    /// Rick Astley – Never Gonna Give You Up. Any track URI or share link works.
    static let defaultTrack = "spotify:track:4cOdK2wGLETKBW3PvgPWqT"

    @Bindable var model: PlayerModel
    @ViewState private var trackInput = PlayerView.defaultTrack
    @ViewState private var scrubMs: Double?
    @ViewState private var memoryMB: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            account
            Divider()
            trackField
            nowPlaying
            progress
            controls
            Divider()
            diagnostics
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Sections

    private var account: some View {
        HStack {
            switch model.session {
            case .loggedOut:
                Label("Not logged in", systemImage: "person.crop.circle.badge.xmark")
                Spacer()
                Button("Log in with Spotify", action: model.logIn).buttonStyle(.borderedProminent)
            case .authorizing:
                ProgressView().controlSize(.small)
                Text("Finish logging in in your browser…")
                Spacer()
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting to Spotify…")
                Spacer()
            case let .connected(username):
                Label {
                    Text("Connected as \(username)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Log out", action: model.logOut)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Spacer()
                Button("Try again", action: model.logIn)
            }
        }
    }

    private var trackField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Track URI or share link", text: $trackInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(playInput)
                Button("Play", action: playInput)
                    .disabled(!model.isConnected)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.track?.name ?? String(localized: "Nothing playing"))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        guard let track = model.track else { return " " }
        return ([track.artists.joined(separator: ", ")] + [track.album].compactMap { $0 })
            .joined(separator: " · ")
    }

    private var progress: some View {
        let duration = max(model.track?.durationMs ?? 0, 1)
        // Once a second, and only while playing: redraws dominate CPU during playback.
        return TimelineView(.animation(minimumInterval: 1, paused: !model.isPlaying)) { context in
            let position = scrubMs ?? model.positionMs(at: context.date)
            VStack(spacing: 2) {
                Slider(
                    value: Binding(get: { position }, set: { scrubMs = $0 }),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        if !editing, let target = scrubMs {
                            model.seek(toMs: target)
                            scrubMs = nil
                        }
                    }
                )
                .disabled(model.track == nil)
                HStack {
                    Text(Self.time(position))
                    Spacer()
                    Text(Self.time(model.track?.durationMs ?? 0))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button(action: model.togglePlayPause) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 20)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.track == nil)
            .help(model.isPlaying ? "Pause" : "Play")

            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: $model.volume, in: 0...1).frame(width: 140)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }

    private var diagnostics: some View {
        HStack {
            if let memoryMB {
                Text("Memory: \(memoryMB, format: .number.precision(.fractionLength(1))) MB")
            } else {
                Text("Memory: –")
            }
            Spacer()
            Button("Measure") { memoryMB = MemoryFootprint.currentMB }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    private func playInput() {
        guard let uri = SpotifyLink.uri(from: trackInput) else {
            model.play(uri: trackInput) // reports the error
            return
        }
        model.play(uri: uri)
    }

    private static func time(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
