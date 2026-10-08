import SwiftUI

struct LyricsView: View {
    @Environment(LyricsModel.self) private var lyrics
    @Environment(PlayerModel.self) private var player
    @ViewState private var follow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Lyrics").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                if !follow {
                    Button("Follow lyrics") { follow = true }
                        .buttonStyle(.plain).font(.system(size: 12))
                }
            }
            switch lyrics.state {
            case .idle: MessageView(systemImage: "text.quote", message: L10n.string("Pick a song to see its lyrics."))
            case .loading: LoadingView()
            case let .failed(message):
                VStack {
                    MessageView(systemImage: "wifi.exclamationmark", message: message)
                    Button("Try Again") { Task { await lyrics.load(player.displayTrack) } }
                }
            case .loaded(.instrumental):
                MessageView(systemImage: "pianokeys", message: L10n.string("Instrumental"))
            case .loaded(.missing):
                MessageView(systemImage: "text.quote", message: L10n.string("No lyrics found for this song."))
            case let .loaded(.plain(text)):
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("These lyrics have no timing.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        Text(text).font(.system(size: 22, weight: .medium)).lineSpacing(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.horizontal, 12)
                }
            case let .loaded(.synced(lines)):
                SyncedLyricsView(lines: lines, follow: $follow)
            }
            Spacer(minLength: 0)
            if case .loaded = lyrics.state {
                Link("Lyrics from LRCLIB", destination: URL(string: "https://lrclib.net")!)
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(24)
        .onChange(of: player.displayTrack?.uri) { follow = true }
    }
}

/// Poll the playback clock cheaply; SwiftUI only updates when a line changes.
private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    @Binding var follow: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    @ViewState private var active: Int?

    var body: some View {
        content
            .task(id: player.playbackAnchor) {
                repeat {
                    let index = LRC.activeIndex(in: lines, at: player.positionMs(at: Date()) / 1000)
                    if active != index { active = index }
                    guard player.isPlaying else { return }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                } while !Task.isCancelled
            }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(lines) { line in
                            let current = line.id == active
                            // Decoder rounding can report a position just before the tag when paused.
                            Button { player.seek(toMs: line.time * 1000 + 50) } label: {
                                Text(line.text.isEmpty ? "···" : line.text)
                                    .font(.system(size: 24, weight: current ? .bold : .medium))
                                    .foregroundStyle(current ? .white : .white.opacity(line.id < (active ?? -1) ? 0.3 : 0.5))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(current ? .white.opacity(0.1) : .clear,
                                                in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(current ? Theme.panelStroke : .clear))
                            }
                            .buttonStyle(.plain).id(line.id)
                            .help("Seek to this line")
                        }
                    }
                    .padding(.vertical, geometry.size.height * 0.4)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { follow = false }
                }
                .onChange(of: active) { scroll(proxy, to: active) }
                .onChange(of: follow) { if follow { scroll(proxy, to: active) } }
                .onAppear { if let active { proxy.scrollTo(active, anchor: .center) } }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to active: Int?) {
        guard follow, let active else { return }
        withAnimation(reduceMotion || systemReduceMotion ? nil : .easeInOut(duration: 0.45)) {
            proxy.scrollTo(active, anchor: .center)
        }
    }
}
