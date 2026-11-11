import SwiftUI

enum Theme {
    static let base = Color(red: 0.045, green: 0.05, blue: 0.06)
    static let panelStroke = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.06)
    static let selection = Color.white.opacity(0.1)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)
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
                if visuals.liveBackground {
                    // The album's own colours, even when the interface uses a fixed accent.
                    let cover = appearance.coverURL == nil ? palette : appearance.palette
                    ReactiveBackground(colors: cover.colors, neutral: cover.isNeutral)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                RadialGradient(colors: [palette.accent.opacity(0.22), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 700)
                Color.black.opacity(0.28)
            }
            .floeAnimation(value: appearance.backgroundURL, duration: 0.45)
            .floeAnimation(value: palette.rgb, duration: 0.45)
            // The light show fades in and out like every other change to the backdrop.
            .floeAnimation(value: visuals.liveBackground, duration: 0.45)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension View {
    /// Frosted panel: a translucent tint over an already-soft backdrop, hairline edge.
    /// No live blur (`Material`): each live-blur layer costs memory and GPU time,
    /// and the cover backdrop is already blurred at thumbnail resolution.
    /// Rounds to the interface size's `corner` unless given a radius.
    func glassPanel(cornerRadius: CGFloat? = nil) -> some View {
        modifier(GlassPanelModifier(radius: cornerRadius))
    }
}

private struct GlassPanelModifier: ViewModifier {
    var radius: CGFloat?
    @AppStorage("glassOpacity") private var opacity = 0.62
    @Environment(\.interfaceScale) private var scale

    private static let edge = LinearGradient(colors: [.white.opacity(0.14), Theme.panelStroke, .white.opacity(0.035)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)

    func body(content: Content) -> some View {
        let cornerRadius = radius ?? scale.corner
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background(Color(white: 0.11).opacity(opacity), in: shape)
            .overlay {
                // One gradient across the panel, drawn as eight pieces of its edge.
                ZStack {
                    ForEach(PanelEdge.Piece.allCases, id: \.self) { piece in
                        PanelEdge(cornerRadius: cornerRadius, piece: piece).fill(Self.edge)
                    }
                }
                .allowsHitTesting(false)
            }
    }
}

/// A piece of a panel's 1 pt edge, exactly where `strokeBorder` draws it.
/// SwiftUI draws a gradient-filled shape into a bitmap the size of the shape's
/// bounds, so the whole hairline cost a panel-sized backing store (19 MB for
/// the page at 1710×1000, 24 MB for Now Playing); cut into corners and sides,
/// it costs a few kilobytes.
private struct PanelEdge: Shape {
    enum Piece: CaseIterable { case topLeading, top, topTrailing, trailing, bottomTrailing, bottom, bottomLeading, leading }

    let cornerRadius: CGFloat
    let piece: Piece

    func path(in rect: CGRect) -> Path {
        // Continuous corners blend into the sides over about 1.53 radii.
        let corner = min((cornerRadius * 1.6).rounded(.up), rect.width / 2, rect.height / 2)
        let (x0, x1, x2) = (rect.minX, rect.minX + corner, rect.maxX - corner)
        let (y0, y1, y2) = (rect.minY, rect.minY + corner, rect.maxY - corner)
        let middle = (width: max(x2 - x1, 0), height: max(y2 - y1, 0))
        let clip = switch piece {
        case .topLeading: CGRect(x: x0, y: y0, width: corner, height: corner)
        case .top: CGRect(x: x1, y: y0, width: middle.width, height: corner)
        case .topTrailing: CGRect(x: x2, y: y0, width: corner, height: corner)
        case .trailing: CGRect(x: x2, y: y1, width: corner, height: middle.height)
        case .bottomTrailing: CGRect(x: x2, y: y2, width: corner, height: corner)
        case .bottom: CGRect(x: x1, y: y2, width: middle.width, height: corner)
        case .bottomLeading: CGRect(x: x0, y: y2, width: corner, height: corner)
        case .leading: CGRect(x: x0, y: y1, width: corner, height: middle.height)
        }
        let edge = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).inset(by: 0.5)
            .path(in: rect).strokedPath(StrokeStyle(lineWidth: 1))
        return edge.intersection(Path(clip))
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
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "play.fill")
                .floeFont(size: 14, weight: .semibold)
                .padding(.horizontal, scale(20))
                .padding(.vertical, scale(9))
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
    @Environment(\.interfaceScale) private var scale
    @ReducedMotion private var reduceMotion
    let systemImage: String
    /// The symbol's size in Compact points; the button scales it.
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
        let diameter = scale(size * 2.1)
        Button {
            presses += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .floeFont(size: size, weight: .medium)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.4), value: reduceMotion || systemImage == "shuffle" ? 0 : presses)
                .foregroundStyle(active ? palette.highlight : (lit ? .white : Theme.secondary))
                .modifier(ShufflePressFeedback(trigger: presses, enabled: animatedShuffle,
                                               diameter: diameter, tint: palette.highlight))
                .frame(width: diameter, height: diameter)
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
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        Text(text)
            .floeFont(size: 10, weight: .bold)
            .tracking(0.9)
            .textCase(.uppercase)
            .padding(.horizontal, scale(8))
            .padding(.vertical, scale(3.5))
            .background(.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.06)))
            .foregroundStyle(Theme.secondary)
    }
}

/// Section title with an optional trailing accessory. Text accessories sit on
/// the title's baseline; symbol buttons use `centeredOnSectionTitle()`.
struct SectionHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .floeFont(size: 20, weight: .bold)
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

extension View {
    /// Centres a symbol button on a section title's capitals (half the cap
    /// height above its baseline) inside `SectionHeader`'s baseline-aligned row.
    func centeredOnSectionTitle() -> some View {
        modifier(SectionTitleCentering())
    }
}

private struct SectionTitleCentering: ViewModifier {
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        // 7 pt is half the cap height of the 20 pt title; it grows with the title.
        let lift = 7 * scale.text(20) / 20
        content.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
    }
}

/// Small spinner for loads of unknown shape. It waits a moment before showing,
/// so quick loads don't flash.
struct LoadingView: View {
    @Environment(\.interfaceScale) private var scale
    @ViewState private var visible = false

    var body: some View {
        ProgressView().controlSize(.small)
            .opacity(visible ? 1 : 0)
            .frame(maxWidth: .infinity, minHeight: scale(120))
            .task {
                guard (try? await Task.sleep(for: .milliseconds(180))) != nil else { return }
                withAnimation(FloeMotion.fade) { visible = true }
            }
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
    @Environment(\.interfaceScale) private var scale
    @ReducedMotion private var reduceMotion
    @ViewState private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage)
                .floeFont(size: 21, weight: .medium)
                .foregroundStyle(tint ?? Theme.secondary)
                .frame(width: scale(52), height: scale(52))
                .background((tint ?? .white).opacity(0.1), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.07)))
            if let title {
                Text(title)
                    .floeFont(size: 15, weight: .semibold)
                    .padding(.top, scale(14))
            }
            Text(message)
                .floeFont(size: 13)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: scale(380))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, scale(title == nil ? 14 : 6))
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .floeFont(size: 12.5, weight: .semibold)
                        .padding(.horizontal, scale(14))
                        .padding(.vertical, scale(6))
                        .glassControl(in: .capsule)
                }
                .buttonStyle(.floe)
                .padding(.top, scale(14))
            }
        }
        .frame(maxWidth: .infinity, minHeight: scale(160))
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
