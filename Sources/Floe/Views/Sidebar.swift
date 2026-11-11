import SwiftUI

struct SidebarView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(LibraryModel.self) private var library
    @Environment(\.interfaceScale) private var scale
    /// One selection indicator, shared by every row, so it glides between them.
    @Namespace private var selection

    var body: some View {
        let metrics = SidebarMetrics(scale)
        let pinned = library.pinnedPlaylists
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                // Lazy, so only rows on screen exist: with hundreds of playlists every
                // row's buttons were AppKit views that each mouse move and window
                // update walked, slowing scrolling everywhere in the window.
                LazyVStack(alignment: .leading, spacing: scale(2)) {
                    NavRow(title: "Home", systemImage: "house.fill", route: .home, selection: selection)
                    NavRow(title: "Songs", systemImage: "star.fill", route: .songs, selection: selection)

                    if !pinned.isEmpty {
                        GroupTitle(title: "Pinned Playlists", systemImage: "pin.fill")
                        ForEach(pinned) {
                            PlaylistRow(playlist: $0, selection: selection, showsSelection: true)
                        }
                    }
                    GroupTitle(title: "All Playlists", systemImage: "music.note.list")
                    ForEach(library.playlists) { playlist in
                        // A pinned playlist is listed twice; only its pinned row carries the indicator.
                        PlaylistRow(playlist: playlist, selection: selection,
                                    showsSelection: !library.isPinned(playlist.id))
                    }
                }
                // The first plate nests in the panel's corner: the same inset on top as at the sides.
                .padding([.horizontal, .bottom], metrics.inset)
                .padding(.top, metrics.inset - 1)
            }
            // Clear of the toolbar's edge, as the page's scroll view is (see MainView).
            .padding(.top, 1)
            .floeGlide(value: navigator.section)
            // A pin makes room for its row instead of the list jumping.
            .floeGlide(value: library.pinnedIDs)
            Rectangle().fill(Theme.panelStroke).frame(height: 1)
            AccountRow()
                .padding(.horizontal, metrics.inset + metrics.padding)
                .padding(.vertical, scale(12))
        }
    }
}

/// The sidebar's guides. Plates sit a plate's inset (8 pt in Compact) in from
/// the panel's edges and round to the panel's radius less that, so their
/// corners nest in the panel's. Inside, every icon, cover and avatar shares one
/// column (28 pt in Compact) and every title starts on the same line after it.
private struct SidebarMetrics {
    let inset: CGFloat
    let padding: CGFloat
    let column: CGFloat
    let spacing: CGFloat
    let radius: CGFloat
    /// Covers nest inside a row's plate.
    let coverRadius: CGFloat

    init(_ scale: InterfaceScale) {
        inset = scale.plate
        padding = scale(4)
        column = scale(28)
        spacing = scale(8)
        radius = scale.corner - inset
        coverRadius = radius - padding
    }
}

private struct GroupTitle: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let metrics = SidebarMetrics(scale)
        HStack(spacing: metrics.spacing) {
            Image(systemName: systemImage).frame(width: metrics.column)
            Text(title).tracking(0.5).textCase(.uppercase)
        }
        .floeFont(size: 10.5, weight: .semibold)
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, metrics.padding)
        .padding(.top, scale(20))
        .padding(.bottom, scale(4))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The selected row's backdrop: a soft accent wash with a hairline edge. Rows
/// share one through `matchedGeometryEffect`, so selection glides.
private struct SelectionIndicator: View {
    @Environment(\.coverPalette) private var palette
    @Environment(\.interfaceScale) private var scale
    let namespace: Namespace.ID

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics(scale).radius, style: .continuous)
        shape
            .fill(Theme.selection)
            .overlay(shape.fill(LinearGradient(colors: [palette.accent.opacity(0.2), palette.accent.opacity(0.03)],
                                               startPoint: .leading, endPoint: .trailing)))
            .overlay(shape.strokeBorder(.white.opacity(0.06)))
            .floeMatched("selection", in: namespace)
    }
}

/// Hover highlight, or the shared selection indicator when selected.
private struct RowBackground: View {
    let selected: Bool
    let hovering: Bool
    let namespace: Namespace.ID
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SidebarMetrics(scale).radius, style: .continuous)
                .fill(Theme.hover)
                .opacity(hovering && !selected ? 1 : 0)
            if selected { SelectionIndicator(namespace: namespace) }
        }
    }
}

private struct NavRow: View {
    @Environment(\.coverPalette) private var palette
    let title: LocalizedStringKey
    let systemImage: String
    let route: Route
    let selection: Namespace.ID
    @Environment(Navigator.self) private var navigator
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        let selected = navigator.section == route
        let metrics = SidebarMetrics(scale)
        Button { navigator.select(route) } label: {
            HStack(spacing: metrics.spacing) {
                // Dimmed by opacity, not by colour: a colour animating under the
                // pointer draws the text again on every frame, an opacity fades its layer.
                Image(systemName: systemImage)
                    .floeFont(size: 13, weight: .medium)
                    .foregroundStyle(selected ? palette.highlight : .white)
                    .opacity(selected || hovering ? 1 : 0.62)
                    .frame(width: metrics.column)
                Text(title)
                    .floeFont(size: 13, weight: selected ? .semibold : .medium)
                    .foregroundStyle(.white)
                    .opacity(selected || hovering ? 1 : 0.62)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.padding)
            .frame(height: scale(32))
            .background(RowBackground(selected: selected, hovering: hovering, namespace: selection))
            .contentShape(Rectangle())
        }
        .buttonStyle(.floeRow)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PlaylistRow: View {
    @Environment(\.coverPalette) private var palette
    @ReducedMotion private var reduceMotion
    let playlist: PlaylistRef
    let selection: Namespace.ID
    let showsSelection: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        let selected = navigator.section == .playlist(playlist.id)
        let playing = player.contextURI == playlist.uri && player.isPlaying
        let metrics = SidebarMetrics(scale)
        Button { navigator.select(.playlist(playlist.id)) } label: {
            HStack(spacing: metrics.spacing) {
                // The shadow sits behind the cover, only while it shows: rows at
                // rest carry no shadow layer.
                ArtworkView(images: playlist.images, size: metrics.column, cornerRadius: metrics.coverRadius)
                    .background {
                        if hovering || selected {
                            RoundedRectangle(cornerRadius: metrics.coverRadius).fill(Color(white: 0.11))
                                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                                .transition(.opacity)
                        }
                    }
                Text(playlist.name)
                    .floeFont(size: 12.5, weight: selected ? .semibold : .regular)
                    .foregroundStyle(playing ? palette.highlight : .white)
                    .opacity(playing || selected || hovering ? 1 : 0.62)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if playing {
                    LoopingSymbol.playing(pointSize: scale.text(10), color: palette.highlight, running: !reduceMotion)
                        .padding(.trailing, metrics.padding)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(metrics.padding)
            .background(RowBackground(selected: selected && showsSelection, hovering: hovering, namespace: selection))
            .contentShape(Rectangle())
        }
        .buttonStyle(.floeRow)
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .floeState(value: playing, duration: 0.3)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Play") { player.play(PlayRequest(contextURI: playlist.uri)) }
            Button(library.isPinned(playlist.id) ? "Unpin" : "Pin to Sidebar") {
                library.togglePin(playlist.id)
            }
        }
    }
}

private struct AccountRow: View {
    @Environment(\.coverPalette) private var palette
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let metrics = SidebarMetrics(scale)
        HStack(spacing: metrics.spacing) {
            ArtworkView(images: library.profile?.images, size: metrics.column, circle: true)
                .overlay(alignment: .bottomTrailing) {
                    // Connection status sits on the avatar, like a presence dot.
                    Circle().fill(statusColor)
                        .frame(width: scale(9), height: scale(9))
                        .overlay(Circle().strokeBorder(Color(white: 0.12), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: scale(1)) {
                Text(library.profile?.displayName ?? player.username ?? "")
                    .floeFont(size: 12.5, weight: .semibold)
                    .lineLimit(1)
                Text(statusText).floeFont(size: 11).foregroundStyle(Theme.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Reload Library") { Task { await library.refresh() } }
                Divider()
                Button("Disconnect Library") { Task { await library.disconnect() } }
                Button("Log Out of Spotify") {
                    player.logOut()
                    Task { await library.disconnect() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Account")
            .accessibilityLabel("Account")
        }
        .floeState(value: player.isConnected, duration: 0.3)
        .accessibilityElement(children: .contain)
    }

    private var statusColor: Color {
        player.isConnected ? palette.accent : .orange
    }

    private var statusText: LocalizedStringKey {
        player.isConnected ? "Connected" : "Reconnecting…"
    }
}
