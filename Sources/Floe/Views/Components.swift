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

/// Accent-colored Play pill with contrast chosen from the cover palette.
struct PlayPill: View {
    @Environment(\.coverPalette) private var palette
    var title: LocalizedStringKey = "Play"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .foregroundStyle(palette.onAccent)
                .glassControl(tint: palette.accent, in: .capsule)
        }
        .buttonStyle(.floe)
    }
}

/// Round, quiet icon button used in toolbars and the mini player. The symbol
/// bounces on press and morphs when it changes, like the system's own controls.
struct IconButton: View {
    @Environment(\.coverPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var reduceMotion = false
    let systemImage: String
    var size: CGFloat = 15
    var active = false
    var help: LocalizedStringKey = ""
    let action: () -> Void
    @ViewState private var hovering = false
    @ViewState private var presses = 0

    var body: some View {
        Button {
            presses += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.4), value: reduceMotion || systemReduceMotion ? 0 : presses)
                .foregroundStyle(active ? palette.highlight : (hovering ? .white : Theme.secondary))
                .frame(width: size * 2.1, height: size * 2.1)
                .background(hovering ? Theme.hover : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.floe)
        .onHover { hovering = $0 }
        .floeAnimation(value: hovering, duration: 0.18)
        .help(help)
    }
}

/// Small uppercase badge, e.g. "PLAYLIST".
struct Badge: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.1), in: Capsule())
            .foregroundStyle(Theme.secondary)
    }
}

/// Section title with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .bold))
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

/// Cover + two lines; used on Home, search and artist pages.
struct Card: View {
    let images: [SpotifyImage]?
    let title: String
    let subtitle: String
    var circle = false
    var size: CGFloat = 156
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: circle ? .center : .leading, spacing: 8) {
                ArtworkView(images: images, size: size, cornerRadius: 10, circle: circle)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                VStack(alignment: circle ? .center : .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                .frame(width: size, alignment: circle ? .center : .leading)
            }
            .padding(10)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.floe)
        .onHover { hovering = $0 }
        .floeAnimation(value: hovering, duration: 0.18)
    }
}

/// Horizontal shelf of cards.
struct Shelf<Item: Identifiable, Content: View>: View {
    let title: LocalizedStringKey
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title).padding(.horizontal, 10)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(items) { content($0) }
                    }
                }
            }
        }
    }
}

/// Header block shared by playlist, album, artist and Liked Songs pages.
struct PageHeader<Cover: View, Actions: View>: View {
    let badge: LocalizedStringKey
    let title: String
    let subtitle: String
    @ViewBuilder var cover: Cover
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: 22) {
            cover.shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            VStack(alignment: .leading, spacing: 10) {
                Badge(text: badge)
                Text(title)
                    .font(.system(size: 34, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                HStack(spacing: 10) { actions }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }
}

struct LoadingView: View {
    var body: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
    }
}

struct MessageView: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 28)).foregroundStyle(Theme.tertiary)
            Text(message).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding()
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
