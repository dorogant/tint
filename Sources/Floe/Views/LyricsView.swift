import SwiftUI

struct LyricsView: View {
    @Environment(LyricsModel.self) private var lyrics
    @Environment(PlayerModel.self) private var player
    @ViewState private var follow = true

    var body: some View {
        ZStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // New content gets a fresh line clock; it never reuses the old lines.
                .id(phaseKey)
                .transition(.blurReplace)
        }
        // Synced lines rest at 40% of the height under a faded edge, so only
        // messages and untimed lyrics need this inset from the panel's top.
        .padding(.vertical, 24)
        .overlay(alignment: .bottom) {
            if !follow, case .loaded(.synced) = lyrics.state {
                Button { follow = true } label: {
                    Label("Follow lyrics", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.bottom, 48)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .floeAnimation(value: phaseKey, duration: 0.45)
        .floeAnimation(value: follow, duration: 0.3)
        .onChange(of: player.displayTrack?.uri) { follow = true }
    }

    @ViewBuilder private var content: some View {
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
                    Text(text).font(.system(size: 22, weight: .semibold, design: .rounded)).lineSpacing(10)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 24)
            }
        case let .loaded(.synced(lines)):
            SyncedLyricsView(lines: lines, follow: $follow)
        }
    }

    /// Cheap animation key: which song and which state, never the lyric text itself.
    private var phaseKey: String {
        let phase = switch lyrics.state {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded: "loaded"
        case .failed: "failed"
        }
        return "\(lyrics.trackURI ?? "")|\(phase)|\(lyrics.isSynthetic)"
    }
}

/// Wakes only when the next line is due, so SwiftUI updates once per line.
/// One frosted pill glides between lines while the list eases into place.
private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    @Binding var follow: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    @Namespace private var pill
    @ViewState private var active: Int?
    @ViewState private var position = ScrollPosition(idType: Int.self)

    /// Lines switch slightly early so the glide lands with the vocal.
    private static let lead: TimeInterval = 0.15
    /// The current line rests a little above the middle, leaving room to read ahead.
    private static let anchor = UnitPoint(x: 0.5, y: 0.4)
    private var still: Bool { reduceMotion || systemReduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let fontSize = min(34, max(22, geometry.size.width / 18))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        // Decoder rounding can report a position just before the tag when paused.
                        LyricRow(line: line, distance: distance(of: line), fontSize: fontSize,
                                 softened: follow && !still, still: still, playing: player.isPlaying, pill: pill) {
                            player.seek(toMs: line.time * 1000 + 50)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 12)
                .padding(.top, geometry.size.height * Self.anchor.y)
                .padding(.bottom, geometry.size.height * (1 - Self.anchor.y))
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            .mask(edgeFade)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { follow = false }
            }
            .onChange(of: follow) {
                guard follow, let active else { return }
                withAnimation(still ? nil : .easeInOut(duration: 0.35)) {
                    position.scrollTo(id: active, anchor: Self.anchor)
                }
            }
        }
        .task(id: player.playbackAnchor) { await followPlayback() }
    }

    private var edgeFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                               .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Clamped, so lines far from the current one don't redraw on every change.
    private func distance(of line: LyricLine) -> Int {
        guard let active else { return min(6, line.id + 1) }
        return max(-6, min(6, line.id - active))
    }

    private func followPlayback() async {
        var observedPlayback = false
        while !Task.isCancelled {
            let now = player.positionMs(at: Date()) / 1000 + Self.lead
            let index = LRC.activeIndex(in: lines, at: now)
            if index != active {
                // Neighbouring lines glide, including the natural arrival after
                // an intro. Initial positioning and long seeks still jump.
                let near = if let index, let active { abs(index - active) <= 8 }
                    else { observedPlayback && index != nil }
                advance(to: index, animated: near)
            }
            observedPlayback = true
            guard player.isPlaying else { return }
            let next = (index ?? -1) + 1
            guard next < lines.count else { return }
            // Seek, pause and playback corrections replace playbackAnchor and
            // restart this task. Long gaps need at most one wake per minute;
            // ordinary line timings need no polling between tags.
            let wait = min(max(lines[next].time - now, 0.02), 60)
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
        }
    }

    private func advance(to index: Int?, animated: Bool) {
        var transaction = Transaction(animation: animated && !still ? .easeInOut(duration: 0.35) : nil)
        transaction.disablesAnimations = !animated || still
        withTransaction(transaction) {
            active = index
            if follow, let index { position.scrollTo(id: index, anchor: Self.anchor) }
        }
    }
}

/// The current line sits on the frosted pill; the rest dim, shrink and soften with distance.
private struct LyricRow: View {
    let line: LyricLine
    /// 0 is the current line, negative already sung, positive upcoming.
    let distance: Int
    let fontSize: CGFloat
    let softened: Bool
    let still: Bool
    let playing: Bool
    let pill: Namespace.ID
    let seek: () -> Void
    @Environment(\.coverPalette) private var palette
    @ViewState private var hovering = false

    var body: some View {
        let current = distance == 0
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        // The sung line glows softly, tinted toward the cover.
        let glow = palette.highlight.mix(with: .white, by: 0.6)
        Button(action: seek) {
            label
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(opacity))
                .shadow(color: .white.opacity(current ? 0.35 : 0), radius: current ? 2 : 0)
                .shadow(color: glow.opacity(current ? 0.6 : 0), radius: current ? 12 : 0)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .scaleEffect(current || still ? 1 : 0.94, anchor: .leading)
                .blur(radius: blur)
                .background {
                    if current {
                        shape.fill(.white.opacity(0.1))
                            .overlay(shape.strokeBorder(.white.opacity(0.1)))
                            .matchedGeometryEffect(id: "pill", in: pill)
                    } else if hovering {
                        shape.fill(.white.opacity(0.035))
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(rowAnimation, value: distance)
        .floeAnimation(value: hovering, duration: 0.18)
        .help("Seek to this line")
    }

    @ViewBuilder private var label: some View {
        if line.text.isEmpty {
            Image(systemName: "ellipsis")
                .symbolEffect(.breathe, isActive: distance == 0 && playing && !still)
                .accessibilityLabel("Instrumental")
        } else {
            Text(line.text)
        }
    }

    private var opacity: Double {
        switch distance {
        case 0: 1
        case _ where hovering: 0.7
        case ..<0: 0.3
        default: max(0.32, 0.58 - Double(distance - 1) * 0.06)
        }
    }

    private var blur: CGFloat {
        guard softened, distance != 0, !hovering else { return 0 }
        return CGFloat(min(abs(distance), 4)) * 0.6
    }

    /// Keep the short cascade on a bounded curve: springs can still be settling
    /// when the next line arrives, extending full-list redraws into the next beat.
    private var rowAnimation: Animation? {
        still ? nil : .easeOut(duration: 0.3).delay(distance > 0 ? Double(min(distance, 3)) * 0.02 : 0)
    }
}
