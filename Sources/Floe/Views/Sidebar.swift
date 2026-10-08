import SwiftUI

struct SidebarView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(LibraryModel.self) private var library
    /// One selection indicator, shared by every row, so it glides between them.
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    NavRow(title: "Home", systemImage: "house.fill", route: .home, selection: selection)
                    NavRow(title: "Songs", systemImage: "star.fill", route: .songs, selection: selection)

                    if !library.pinnedPlaylists.isEmpty {
                        GroupTitle(title: "Pinned Playlists", systemImage: "pin.fill")
                        ForEach(library.pinnedPlaylists) {
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
                .padding([.horizontal, .bottom], SidebarMetrics.inset)
                .padding(.top, SidebarMetrics.inset - 1)
            }
            // Clear of the toolbar's edge, as the page's scroll view is (see MainView).
            .padding(.top, 1)
            .floeGlide(value: navigator.section)
            Rectangle().fill(Theme.panelStroke).frame(height: 1)
            AccountRow()
                .padding(.horizontal, SidebarMetrics.inset + SidebarMetrics.padding)
                .padding(.vertical, 12)
        }
    }
}

/// The sidebar's guides. Plates sit 8 pt in from the panel's edges and round
/// to the panel's radius less that, so their corners nest in the panel's.
/// Inside, every icon, cover and avatar shares one 28 pt column and every
/// title starts on the same line after it.
private enum SidebarMetrics {
    static let inset = Theme.plate
    static let padding: CGFloat = 4
    static let column: CGFloat = 28
    static let spacing: CGFloat = 8
    static let radius = Theme.corner - inset
    /// Covers nest inside a row's plate.
    static let coverRadius = radius - padding
}

private struct GroupTitle: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: SidebarMetrics.spacing) {
            Image(systemName: systemImage).frame(width: SidebarMetrics.column)
            Text(title).tracking(0.5).textCase(.uppercase)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, SidebarMetrics.padding)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The selected row's backdrop: a soft accent wash with a hairline edge. Rows
/// share one through `matchedGeometryEffect`, so selection glides.
private struct SelectionIndicator: View {
    @Environment(\.coverPalette) private var palette
    let namespace: Namespace.ID

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous)
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous)
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
    @ViewState private var hovering = false

    var body: some View {
        let selected = navigator.section == route
        Button { navigator.select(route) } label: {
            HStack(spacing: SidebarMetrics.spacing) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? palette.highlight : (hovering ? .white : Theme.secondary))
                    .frame(width: SidebarMetrics.column)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected || hovering ? .white : Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SidebarMetrics.padding)
            .frame(height: 32)
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
    @ViewState private var hovering = false

    var body: some View {
        let selected = navigator.section == .playlist(playlist.id)
        let playing = player.contextURI == playlist.uri && player.isPlaying
        Button { navigator.select(.playlist(playlist.id)) } label: {
            HStack(spacing: SidebarMetrics.spacing) {
                ArtworkView(images: playlist.images, size: SidebarMetrics.column, cornerRadius: SidebarMetrics.coverRadius)
                    .shadow(color: .black.opacity(hovering || selected ? 0.35 : 0), radius: 4, y: 2)
                Text(playlist.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(playing ? palette.highlight : (selected || hovering ? .white : Theme.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if playing {
                    PlayingSymbol(pointSize: 10, color: palette.highlight, animating: !reduceMotion)
                        .padding(.trailing, SidebarMetrics.padding)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(SidebarMetrics.padding)
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

    var body: some View {
        HStack(spacing: SidebarMetrics.spacing) {
            ArtworkView(images: library.profile?.images, size: SidebarMetrics.column, circle: true)
                .overlay(alignment: .bottomTrailing) {
                    // Connection status sits on the avatar, like a presence dot.
                    Circle().fill(statusColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(white: 0.12), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(library.profile?.displayName ?? player.username ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(statusText).font(.system(size: 11)).foregroundStyle(Theme.secondary)
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
