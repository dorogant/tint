import SwiftUI

struct LyricsView: View {
    @Environment(LyricsModel.self) private var lyrics
    @Environment(PlayerModel.self) private var player
    @ViewState private var follow = true
    @ReducedMotion private var still

    var body: some View {
        ZStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // New content gets a fresh line clock; it never reuses the old lines.
                .id(phaseKey)
                .transition(still ? .opacity : AnyTransition(.blurReplace))
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
                .transition(still ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .floeAnimation(value: phaseKey, duration: 0.3)
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
    @ReducedMotion private var still
    @Namespace private var pill
    @ViewState private var active: Int?
    @ViewState private var position = ScrollPosition(idType: Int.self)

    /// Lines switch slightly early so the glide lands with the vocal.
    private static let lead: TimeInterval = 0.15
    /// The current line rests a little above the middle, leaving room to read ahead.
    private static let anchor = UnitPoint(x: 0.5, y: 0.4)

    var body: some View {
        GeometryReader { geometry in
            let fontSize = min(34, max(22, geometry.size.width / 18))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        // Decoder rounding can report a position just before the tag when paused.
                        // Only a gap's "…" cares whether music plays. Equatable rows
                        // skip their body when nothing they show changed.
                        LyricRow(line: line, distance: distance(of: line), fontSize: fontSize,
                                 softened: follow && !still, still: still,
                                 playing: line.text.isEmpty && player.isPlaying, pill: pill) {
                            player.seek(toMs: line.time * 1000 + 50)
                        }
                        .equatable()
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
        // Open on the current line, so a newly shown list never lands on line 0
        // and then jumps mid-transition.
        .onAppear {
            let now = player.positionMs(at: Date()) / 1000 + Self.lead
            advance(to: LRC.activeIndex(in: lines, at: now), animated: false)
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
/// Under the pointer a line previews itself: it sharpens, brightens, grows a
/// little toward the current line's size and shows the time it seeks to.
private struct LyricRow: View, Equatable {
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

    /// `seek` is left out: it only ever seeks to `line`, and a closure never
    /// compares equal, which made every visible row redraw on each line change.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.line == b.line && a.distance == b.distance && a.fontSize == b.fontSize && a.softened == b.softened
            && a.still == b.still && a.playing == b.playing && a.pill == b.pill
    }

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
                .scaleEffect(current || still ? 1 : (hovering ? 0.955 : 0.94), anchor: .leading)
                .blur(radius: blur)
                .background {
                    if current {
                        shape.fill(.white.opacity(0.1))
                            .overlay(shape.strokeBorder(.white.opacity(0.1)))
                            .matchedGeometryEffect(id: "pill", in: pill)
                    } else if hovering {
                        shape.fill(.white.opacity(0.045))
                            .overlay(shape.strokeBorder(.white.opacity(0.05)))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        seekTime
                            .padding(.top, 11 + max(0, fontSize * 1.2 - 22) / 2)
                            .padding(.trailing, 12)
                            .transition(.opacity.combined(with: .offset(x: still ? 0 : -4)))
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(LyricPressStyle(still: still))
        .onHover { hovering = $0 }
        .animation(rowAnimation, value: distance)
        .animation(still ? .easeOut(duration: 0.15) : .spring(duration: hovering ? 0.16 : 0.24, bounce: 0),
                   value: hovering)
        .help("Seek to this line")
    }

    /// Where a click lands, so the row reads as a way to seek.
    private var seekTime: some View {
        let seconds = Int(line.time)
        return Label(String(format: "%d:%02d", seconds / 60, seconds % 60), systemImage: "play.fill")
            .labelStyle(SeekTimeLabelStyle())
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.black.opacity(0.28), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var label: some View {
        if line.text.isEmpty {
            // AppKit runs the breathing, so a gap doesn't re-lay out the window every
            // frame. The still SwiftUI symbol only sizes the row, exactly as before;
            // the row's dimming reaches AppKit through `opacity`, not the foreground style.
            Image(systemName: "ellipsis").hidden().overlay {
                LoopingSymbol.instrumental(pointSize: fontSize, running: distance == 0 && playing && !still)
                    .opacity(opacity)
            }
        } else {
            Text(line.text)
        }
    }

    private var opacity: Double {
        switch distance {
        case 0: 1
        case _ where hovering: 0.78
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

/// A slight press toward the leading edge, released on a short spring.
private struct LyricPressStyle: ButtonStyle {
    let still: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !still ? 0.98 : 1, anchor: .leading)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(still ? .easeOut(duration: 0.15)
                       : .spring(duration: configuration.isPressed ? 0.14 : 0.3, bounce: configuration.isPressed ? 0 : 0.15),
                       value: configuration.isPressed)
    }
}

private struct SeekTimeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7, weight: .bold))
            configuration.title
        }
    }
}
