import SwiftUI

/// Cover + two lines; used on Home, search and artist pages. Under the pointer
/// the artwork rises a few points with a deeper shadow and brightens slightly,
/// and, given `play`, a Play button rises into its corner. The whole card dips
/// on press. Play is also in the context menu and the VoiceOver actions, after
/// which come any extra `actions`.
struct Card: View {
    @ReducedMotion private var reduceMotion
    let images: [SpotifyImage]?
    let title: String
    /// Left out where the section already says what the items are (artists).
    var subtitle = ""
    var circle = false
    var size: CGFloat = 156
    var actions: [CardAction] = []
    let action: () -> Void
    /// Plays the item in place, without opening it.
    var play: (() -> Void)? = nil
    @ViewState private var hovering = false
    @ViewState private var pressed = false

    /// Artwork corners. The hover plate adds its inset, so the corners nest.
    static let radius: CGFloat = 8

    var body: some View {
        let lift: CGFloat = hovering && !reduceMotion ? -3 : 0
        let plate = RoundedRectangle(cornerRadius: Self.radius + Theme.plate, style: .continuous)
        Button(action: action) {
            VStack(alignment: circle ? .center : .leading, spacing: 8) {
                ArtworkView(images: images, size: size, cornerRadius: Self.radius, circle: circle)
                    .brightness(hovering ? 0.04 : 0)
                    .shadow(color: .black.opacity(hovering ? 0.5 : 0.3),
                            radius: hovering ? 16 : 9, y: hovering ? 11 : 5)
                    .offset(y: lift)
                VStack(alignment: circle ? .center : .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                .frame(width: size, alignment: circle ? .center : .leading)
            }
            .padding(Theme.plate)
            .background(Theme.hover.opacity(hovering ? 1 : 0), in: plate)
            .contentShape(plate)
        }
        .buttonStyle(CardPressStyle(pressed: $pressed))
        .overlay(alignment: .topLeading) {
            if let play, hovering {
                HoverPlayButton(diameter: min(max(size * 0.26, 34), 44), action: play)
                    .padding(8)
                    .frame(width: size, height: size, alignment: .bottomTrailing)
                    .offset(y: lift)
                    .padding(Theme.plate)
                    .transition(HoverPlayButton.transition(still: reduceMotion))
            }
        }
        .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .animation(reduceMotion ? FloeMotion.fade : FloeMotion.press(pressed), value: pressed)
        .modifier(PlayMenu(play: play, actions: actions))
    }
}

/// A context menu and VoiceOver action beyond Play.
struct CardAction: Identifiable {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    /// A card's actions differ in their symbols.
    var id: String { systemImage }
}

extension View {
    /// A hover plate that reaches `Theme.plate` past the content on every side
    /// without moving it, so the content stays on the page's guides. Its
    /// corners nest around content rounded to `radius`.
    func hoverPlate(_ visible: Bool, radius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius + Theme.plate, style: .continuous)
                .fill(Theme.hover)
                .padding(-Theme.plate)
                .opacity(visible ? 1 : 0)
        }
    }
}

/// The accent Play button that rises into a card or tile under the pointer.
struct HoverPlayButton: View {
    @Environment(\.coverPalette) private var palette
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
    static func transition(still: Bool) -> AnyTransition {
        let leave = AnyTransition.opacity.animation(.easeOut(duration: 0.12))
        guard !still else { return .asymmetric(insertion: .opacity, removal: leave) }
        return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: 6)),
                           removal: leave)
    }
}

/// Play without the pointer: in the context menu and as a VoiceOver action.
/// Any extra actions follow it in both.
struct PlayMenu: ViewModifier {
    let play: (() -> Void)?
    var actions: [CardAction] = []

    @ViewBuilder func body(content: Content) -> some View {
        if play != nil || !actions.isEmpty {
            content
                .contextMenu {
                    if let play { Button("Play", action: play) }
                    if play != nil && !actions.isEmpty { Divider() }
                    ForEach(actions) { item in
                        Button(item.title, systemImage: item.systemImage, action: item.action)
                    }
                }
                .accessibilityActions {
                    if let play { Button("Play", action: play) }
                    ForEach(actions) { item in Button(item.title, action: item.action) }
                }
        } else {
            content
        }
    }
}

/// Hands the press to the card, so the artwork, text and Play button dip together.
struct CardPressStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in pressed = isPressed }
    }
}

/// Horizontal shelf of cards. The strip runs under the panel's edges while the
/// first card's artwork rests on the page gutter, under the header. When it
/// overflows, arrows in the header page through it, so a mouse without
/// horizontal scrolling can still browse.
struct Shelf<Item: Identifiable, Content: View>: View {
    let title: LocalizedStringKey
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content
    @ReducedMotion private var reduceMotion
    @ViewState private var edges = ShelfEdges()
    @ViewState private var metrics = ShelfMetrics()
    @ViewState private var position = ScrollPosition()

    /// Cards bring their own plate inset, so the strip starts that much before the gutter.
    private static var margin: CGFloat { Theme.gutter - Theme.plate }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.headerGap - Theme.plate) {
                SectionHeader(title: title) {
                    if edges.back || edges.forward {
                        HStack(spacing: 4) {
                            IconButton(systemImage: "chevron.left", size: 12, help: "Scroll back") { page(-1) }
                                .disabled(!edges.back)
                            IconButton(systemImage: "chevron.right", size: 12, help: "Scroll forward") { page(1) }
                                .disabled(!edges.forward)
                        }
                        .centeredOnSectionTitle()
                        // The glyphs, not their hover wells, end on the gutter.
                        .padding(.trailing, -Theme.plate)
                        .transition(.opacity)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(items) { item in
                            // Cards ease in and out at the shelf's edges as it scrolls.
                            content(item).scrollTransition(.interactive, axis: .horizontal) { card, phase in
                                card.scaleEffect(phase.isIdentity ? 1 : 0.9).opacity(phase.isIdentity ? 1 : 0.5)
                            }
                        }
                    }
                    .padding(.horizontal, Self.margin)
                }
                .scrollPosition($position)
                .padding(.horizontal, -Theme.gutter)
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
            }
            // The cards' plates overhang the section below; the gap is measured to the text.
            .padding(.bottom, -Theme.plate)
            .floeState(value: edges, duration: 0.2)
        }
    }

    /// Pages by a screenful less one card, so the card at the edge stays in
    /// view, and lands with a card's artwork on the gutter. Cards in a shelf
    /// share a width, so positions follow from the content width.
    private func page(_ direction: Int) {
        let latest = metrics.latest
        let card = (latest.contentWidth - 2 * Self.margin) / CGFloat(items.count)
        guard card > 0 else { return }
        let first = Int((latest.offset / card).rounded())
        let step = max(Int((latest.width - 2 * Self.margin) / card) - 1, 1)
        let target = min(max(first + direction * step, 0), items.count - 1)
        let x = min(CGFloat(target) * card, max(latest.contentWidth - latest.width, 0))
        withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0)) {
            position.scrollTo(x: x)
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
