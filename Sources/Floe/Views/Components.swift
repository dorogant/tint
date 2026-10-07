import SwiftUI

enum Theme {
    /// Default accent (Spotify-like green); Phase 3 adds "accent from cover".
    static let accent = Color(red: 0.12, green: 0.84, blue: 0.38)
    static let base = Color(red: 0.045, green: 0.05, blue: 0.06)
    static let panelStroke = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.06)
    static let selection = Color.white.opacity(0.1)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.4)
    static let corner: CGFloat = 18
}

/// Static backdrop behind the glass panels. Phase 3 replaces it with the blurred,
/// per-song cover art.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.base
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color(red: 0.1, green: 0.35, blue: 0.5).opacity(0.25), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 800)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Frosted panel: a translucent tint over an already-soft backdrop, hairline edge.
    /// No live blur (`Material`): each live-blur layer costs memory and GPU time,
    /// and over a smooth (or pre-blurred, Phase 3) backdrop it looks the same.
    func glassPanel(cornerRadius: CGFloat = Theme.corner) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Color(white: 0.11).opacity(0.62), in: shape)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.panelStroke)
            )
    }
}

/// The green "Play" pill from the reference UI.
struct PlayPill: View {
    var title: LocalizedStringKey = "Play"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .foregroundStyle(.black)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Round, quiet icon button used in toolbars and the mini player.
struct IconButton: View {
    let systemImage: String
    var size: CGFloat = 15
    var active = false
    var help: LocalizedStringKey = ""
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? Theme.accent : (hovering ? .white : Theme.secondary))
                .frame(width: size * 2.1, height: size * 2.1)
                .background(hovering ? Theme.hover : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
            ? String(localized: "\(minutes / 60) hr \(minutes % 60) min")
            : String(localized: "\(minutes) min")
    }

    /// Playlist descriptions arrive as HTML snippets.
    static func plainText(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">"]
        return entities.reduce(stripped) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}
