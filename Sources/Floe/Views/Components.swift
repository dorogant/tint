import SwiftUI

enum Theme {
    /// Default accent; cover palettes are inherited through the view environment.
    static let accent = Color(red: 0.12, green: 0.84, blue: 0.38)
    static let base = Color(red: 0.045, green: 0.05, blue: 0.06)
    static let panelStroke = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.06)
    static let selection = Color.white.opacity(0.1)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)
    static let corner: CGFloat = 18
    /// Placeholder blocks and quiet fills (skeletons, icon wells).
    static let well = Color.white.opacity(0.06)
}

/// Cover art is blurred once at thumbnail resolution, then stretched behind glass.
struct Backdrop: View {
    @Environment(\.coverPalette) private var palette
    @Environment(CoverAppearance.self) private var appearance
    @Environment(VisualSettings.self) private var visuals

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.base
                if let image = appearance.background {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped().opacity(0.45)
                        .id(appearance.backgroundURL)
                        .transition(.opacity)
                }
                if visuals.liveBackground { ReactiveBackground().allowsHitTesting(false) }
                RadialGradient(colors: [palette.accent.opacity(0.22), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 700)
                Color.black.opacity(0.28)
            }
            .floeAnimation(value: appearance.backgroundURL, duration: 0.45)
            .floeAnimation(value: palette.rgb, duration: 0.45)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension View {
    /// Frosted panel: a translucent tint over an already-soft backdrop, hairline edge.
    /// No live blur (`Material`): each live-blur layer costs memory and GPU time,
    /// and the cover backdrop is already blurred at thumbnail resolution.
    func glassPanel(cornerRadius: CGFloat = Theme.corner) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }
}

private struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    @AppStorage("glassOpacity") private var opacity = 0.62
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background(Color(white: 0.11).opacity(opacity), in: shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), Theme.panelStroke, .white.opacity(0.035)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}

extension View {
    /// Interactive Liquid Glass for small controls, optionally tinted. Development
    /// snapshots can't render glass, so they get a flat tint in its place.
    func glassControl(tint: Color? = nil, in shape: some Shape) -> some View {
        modifier(GlassControlModifier(tint: tint, shape: shape))
    }
}

private struct GlassControlModifier<S: Shape>: ViewModifier {
    var tint: Color?
    var shape: S
    @ViewBuilder func body(content: Content) -> some View {
        if Snapshot.isEnabled {
            content.background(tint ?? .white.opacity(0.1), in: shape)
        } else {
            content.glassEffect(.regular.tint(tint).interactive(), in: shape)
        }
    }
}

/// Accent-colored Play pill with contrast chosen from the cover palette. Its
/// accent glow deepens under the pointer.
struct PlayPill: View {
    @Environment(\.coverPalette) private var palette
    var title: LocalizedStringKey = "Play"
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .foregroundStyle(palette.onAccent)
                .glassControl(tint: palette.accent, in: .capsule)
                .shadow(color: palette.accent.opacity(hovering ? 0.42 : 0.18),
                        radius: hovering ? 14 : 8, y: hovering ? 5 : 3)
        }
        .buttonStyle(.floe)
        .onHover { hovering = $0 }
        .floeHover(hovering)
    }
}

/// Round, quiet icon button used in toolbars and the mini player. A soft well
/// grows in under the pointer; the symbol bounces on press and morphs when it
/// changes. Shuffle gets a crossover kick. `help` doubles as the VoiceOver label.
struct IconButton: View {
    @Environment(\.coverPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @ReducedMotion private var reduceMotion
    let systemImage: String
    var size: CGFloat = 15
    var active = false
    var help: LocalizedStringKey? = nil
    let action: () -> Void
    @ViewState private var hovering = false
    @ViewState private var presses = 0

    private var animatedShuffle: Bool {
        systemImage == "shuffle" && !reduceMotion
    }

    var body: some View {
        let lit = hovering && enabled
        Button {
            presses += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.4), value: reduceMotion || systemImage == "shuffle" ? 0 : presses)
                .foregroundStyle(active ? palette.highlight : (lit ? .white : Theme.secondary))
                .modifier(ShufflePressFeedback(trigger: presses, enabled: animatedShuffle,
                                               diameter: size * 2.1, tint: palette.highlight))
                .frame(width: size * 2.1, height: size * 2.1)
                .background {
                    Circle()
                        .fill(active ? palette.accent.opacity(0.16) : Color.white.opacity(0.09))
                        .scaleEffect(lit || reduceMotion ? 1 : 0.82)
                        .opacity(lit ? 1 : 0)
                }
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.floe)
        .onHover { hovering = $0 }
        .floeHover(lit)
        .floeState(value: active, duration: 0.18)
        .modifier(HelpLabel(text: help))
    }
}

/// Tooltip plus VoiceOver label for icon-only controls.
private struct HelpLabel: ViewModifier {
    let text: LocalizedStringKey?
    @ViewBuilder func body(content: Content) -> some View {
        if let text { content.help(text).accessibilityLabel(text) } else { content }
    }
}

/// Small uppercase badge, e.g. "PLAYLIST".
struct Badge: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.9)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.06)))
            .foregroundStyle(Theme.secondary)
    }
}

/// Section title with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.3)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title: title) { EmptyView() }
    }
}

/// Cover + two lines; used on Home, search and artist pages. Under the pointer
/// the artwork rises a few points with a deeper shadow and brightens slightly,
/// and, given `play`, a Play button rises into its corner. The whole card dips
/// on press. Play is also in the context menu and the VoiceOver actions.
struct Card: View {
    @Environment(\.coverPalette) private var palette
    @ReducedMotion private var reduceMotion
    let images: [SpotifyImage]?
    let title: String
    let subtitle: String
    var circle = false
    var size: CGFloat = 156
    let action: () -> Void
    /// Plays the item in place, without opening it.
    var play: (() -> Void)? = nil
    @ViewState private var hovering = false
    @ViewState private var pressed = false

    var body: some View {
        let lift: CGFloat = hovering && !reduceMotion ? -3 : 0
        Button(action: action) {
            VStack(alignment: circle ? .center : .leading, spacing: 10) {
                ArtworkView(images: images, size: size, cornerRadius: 10, circle: circle)
                    .brightness(hovering ? 0.04 : 0)
                    .shadow(color: .black.opacity(hovering ? 0.5 : 0.3),
                            radius: hovering ? 16 : 9, y: hovering ? 11 : 5)
                    .offset(y: lift)
                VStack(alignment: circle ? .center : .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                .frame(width: size, alignment: circle ? .center : .leading)
            }
            .padding(10)
            .background(Theme.hover.opacity(hovering ? 1 : 0),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(CardPressStyle(pressed: $pressed))
        .overlay(alignment: .topLeading) {
            if let play, hovering {
                playButton(play)
                    .padding(8)
                    .frame(width: size, height: size, alignment: .bottomTrailing)
                    .offset(y: lift)
                    .padding(10)
                    .transition(playTransition)
            }
        }
        .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .animation(reduceMotion ? FloeMotion.fade : FloeMotion.press(pressed), value: pressed)
        .contextMenu {
            if let play { Button("Play", action: play) }
        }
        .accessibilityActions {
            if let play { Button("Play", action: play) }
        }
    }

    private func playButton(_ play: @escaping () -> Void) -> some View {
        let diameter = min(max(size * 0.26, 34), 44)
        return Button(action: play) {
            Image(systemName: "play.fill")
                .font(.system(size: diameter * 0.36, weight: .bold))
                .foregroundStyle(palette.onAccent)
                .offset(x: diameter * 0.03) // optical centre of the triangle
                .frame(width: diameter, height: diameter)
                .glassControl(tint: palette.accent, in: .circle)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.floe)
        .help("Play")
    }

    /// Rises in from just below and slightly small; leaves faster than it came.
    private var playTransition: AnyTransition {
        let leave = AnyTransition.opacity.animation(.easeOut(duration: 0.12))
        guard !reduceMotion else { return .asymmetric(insertion: .opacity, removal: leave) }
        return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: 6)),
                           removal: leave)
    }
}

/// Hands the press to the card, so the artwork, text and Play button dip together.
private struct CardPressStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in pressed = isPressed }
    }
}

/// Horizontal shelf of cards. When it overflows, arrows in the header page
/// through it, so a mouse without horizontal scrolling can still browse.
struct Shelf<Item: Identifiable, Content: View>: View {
    let title: LocalizedStringKey
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content
    @ReducedMotion private var reduceMotion
    @ViewState private var position = ScrollPosition(edge: .leading)
    @ViewState private var edges = ShelfEdges()
    @ViewState private var metrics = ShelfMetrics()

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: title) {
                    if edges.back || edges.forward {
                        HStack(spacing: 2) {
                            IconButton(systemImage: "chevron.left", size: 12, help: "Scroll back") { page(-1) }
                                .disabled(!edges.back)
                            IconButton(systemImage: "chevron.right", size: 12, help: "Scroll forward") { page(1) }
                                .disabled(!edges.forward)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 10)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(items) { item in
                            // Cards ease in and out at the shelf's edges as it scrolls.
                            content(item).scrollTransition(.interactive, axis: .horizontal) { card, phase in
                                card.scaleEffect(phase.isIdentity ? 1 : 0.9).opacity(phase.isIdentity ? 1 : 0.5)
                            }
                        }
                    }
                }
                .scrollPosition($position)
                // Only the arrows' enabled state is view state; it changes at the ends.
                .onScrollGeometryChange(for: ShelfEdges.self) { geometry in
                    ShelfEdges(back: geometry.contentOffset.x > 1,
                               forward: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1)
                } action: { _, new in
                    edges = new
                }
                .onScrollGeometryChange(for: ShelfMetrics.Snapshot.self) { geometry in
                    ShelfMetrics.Snapshot(offset: geometry.contentOffset.x, width: geometry.containerSize.width,
                                          contentWidth: geometry.contentSize.width)
                } action: { _, new in
                    metrics.latest = new
                }
                .floeState(value: edges, duration: 0.2)
            }
        }
    }

    /// Pages by most of a screenful, keeping a card's width of context.
    private func page(_ direction: CGFloat) {
        let latest = metrics.latest
        let step = max(latest.width - 160, 160)
        let limit = max(latest.contentWidth - latest.width, 0)
        let target = min(max(latest.offset + direction * step, 0), limit)
        withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0)) {
            position.scrollTo(x: target)
        }
    }
}

private struct ShelfEdges: Equatable {
    var back = false
    var forward = false
}

/// Scroll geometry kept outside view state: it changes on every scrolled frame,
/// but only the arrow actions read it, so it mustn't trigger a redraw.
@MainActor
private final class ShelfMetrics {
    struct Snapshot: Equatable {
        var offset: CGFloat = 0
        var width: CGFloat = 0
        var contentWidth: CGFloat = 0
    }
    var latest = Snapshot()
}

/// Header block shared by playlist, album, artist and Liked Songs pages: cover,
/// kind badge, a large title, an optional byline (e.g. the album's artists),
/// a description and a quieter detail line, then the actions.
struct PageHeader<Cover: View, Byline: View, Actions: View>: View {
    let badge: LocalizedStringKey
    let title: String
    let subtitle: String
    let detail: String
    let cover: Cover
    let byline: Byline
    let actions: Actions

    init(badge: LocalizedStringKey, title: String, subtitle: String = "", detail: String = "",
         @ViewBuilder cover: () -> Cover, @ViewBuilder byline: () -> Byline,
         @ViewBuilder actions: () -> Actions) {
        self.badge = badge
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.cover = cover()
        self.byline = byline()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            cover
            VStack(alignment: .leading, spacing: 0) {
                Badge(text: badge)
                Text(title)
                    .font(.system(size: 40, weight: .heavy))
                    .tracking(-0.8)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)
                if Byline.self != EmptyView.self {
                    byline
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 6)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .padding(.top, 8)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .padding(.top, subtitle.isEmpty ? 8 : 4)
                }
                HStack(spacing: 10) { actions }
                    .padding(.top, 18)
            }
            Spacer(minLength: 0)
        }
    }
}

extension PageHeader where Byline == EmptyView {
    init(badge: LocalizedStringKey, title: String, subtitle: String = "", detail: String = "",
         @ViewBuilder cover: () -> Cover, @ViewBuilder actions: () -> Actions) {
        self.init(badge: badge, title: title, subtitle: subtitle, detail: detail,
                  cover: cover, byline: { EmptyView() }, actions: actions)
    }
}

extension View {
    /// Page covers sit on a soft shadow tinted from the artwork itself, so each
    /// page carries its own colour. Greyscale art keeps a neutral shadow.
    func coverGlow(_ images: [SpotifyImage]?) -> some View {
        modifier(CoverGlow(url: images?.best(forPixels: 48), fixed: nil))
    }

    /// The same glow in a known colour, for generated covers.
    func coverGlow(color: Color) -> some View {
        modifier(CoverGlow(url: nil, fixed: color))
    }
}

private struct CoverGlow: ViewModifier {
    let url: URL?
    let fixed: Color?
    @ViewState private var extracted: Color?

    func body(content: Content) -> some View {
        let tint = fixed ?? extracted
        content
            .shadow(color: (tint ?? .clear).opacity(0.38), radius: 34, y: 14)
            .shadow(color: .black.opacity(0.42), radius: 12, y: 8)
            .floeState(value: tint, duration: 0.45)
            .task(id: url) {
                guard let url, let image = await ArtworkCache.shared.image(for: url, pixels: 48) else { return }
                extracted = CoverColorExtractor.extract(of: image).map { Color(red: $0.r, green: $0.g, blue: $0.b) }
            }
    }
}

/// Small spinner for loads of unknown shape. It waits a moment before showing,
/// so quick loads don't flash.
struct LoadingView: View {
    @ViewState private var visible = false

    var body: some View {
        ProgressView().controlSize(.small)
            .opacity(visible ? 1 : 0)
            .frame(maxWidth: .infinity, minHeight: 120)
            .task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(FloeMotion.fade) { visible = true }
            }
            .accessibilityLabel("Loading")
    }
}

/// Page-shaped stand-in while a playlist, album or artist loads: quiet blocks
/// where the cover, title and actions will land, so the header arrives in place.
struct PagePlaceholder: View {
    var circle = false
    @ViewState private var visible = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            Group {
                if circle { Circle().fill(Theme.well) } else { RoundedRectangle(cornerRadius: 12).fill(Theme.well) }
            }
            .frame(width: 200, height: 200)
            .overlay { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 0) {
                Capsule().fill(Theme.well).frame(width: 64, height: 17)
                RoundedRectangle(cornerRadius: 7).fill(Theme.well).frame(width: 300, height: 36).padding(.top, 12)
                RoundedRectangle(cornerRadius: 4).fill(Theme.well).frame(width: 190, height: 12).padding(.top, 12)
                Capsule().fill(Theme.well).frame(width: 92, height: 36).padding(.top, 20)
            }
            Spacer(minLength: 0)
        }
        .opacity(visible ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(FloeMotion.fade) { visible = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// Empty, error and hint states: the symbol in a soft well, an optional title,
/// the message, and an optional action such as Try Again. Settles in briefly
/// when it first appears.
struct MessageView: View {
    let systemImage: String
    let message: String
    var title: LocalizedStringKey? = nil
    /// Tints the symbol, e.g. orange for errors.
    var tint: Color? = nil
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil
    @ReducedMotion private var reduceMotion
    @ViewState private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(tint ?? Theme.secondary)
                .frame(width: 52, height: 52)
                .background((tint ?? .white).opacity(0.1), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.07)))
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 14)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, title == nil ? 14 : 6)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .glassControl(in: .capsule)
                }
                .buttonStyle(.floe)
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding()
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .onAppear {
            withAnimation(reduceMotion ? FloeMotion.fade : .spring(duration: 0.32, bounce: 0)) { appeared = true }
        }
    }
}

enum Format {
    static func duration(ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "1 hr 12 min" / "48 min".
    static func total(ms: Int) -> String {
        let minutes = ms / 60_000
        return minutes >= 60
            ? L10n.string("\(minutes / 60) hr \(minutes % 60) min")
            : L10n.string("\(minutes) min")
    }

    /// Playlist descriptions arrive as HTML snippets.
    static func plainText(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">"]
        return entities.reduce(stripped) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}
