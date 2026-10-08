import SwiftUI

struct SidebarView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    NavRow(title: "Home", systemImage: "house.fill", route: .home)
                    NavRow(title: "Search", systemImage: "magnifyingglass", route: .search)
                    NavRow(title: "Songs", systemImage: "star.fill", route: .songs)

                    if !library.pinnedPlaylists.isEmpty {
                        GroupTitle(title: "Pinned Playlists", systemImage: "pin.fill")
                        ForEach(library.pinnedPlaylists) { PlaylistRow(playlist: $0) }
                    }
                    GroupTitle(title: "All Playlists", systemImage: "music.note.list")
                    ForEach(library.playlists) { PlaylistRow(playlist: $0) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            Rectangle().fill(Theme.panelStroke).frame(height: 1)
            AccountRow().padding(12)
        }
    }
}

private struct GroupTitle: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }
}

private struct NavRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let route: Route
    @Environment(Navigator.self) private var navigator
    @ViewState private var hovering = false

    var body: some View {
        let selected = navigator.root == route
        Button { navigator.select(route) } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selected ? Theme.selection : (hovering ? Theme.hover : .clear),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.floe)
        .onHover { hovering = $0 }
        .floeAnimation(value: hovering, duration: 0.16)
        .floeAnimation(value: selected, duration: 0.2)
    }
}

private struct PlaylistRow: View {
    @Environment(\.coverPalette) private var palette
    let playlist: PlaylistRef
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @ViewState private var hovering = false

    var body: some View {
        let selected = navigator.root == .playlist(playlist.id)
        let playing = player.contextURI == playlist.uri && player.isPlaying
        Button { navigator.select(.playlist(playlist.id)) } label: {
            HStack(spacing: 10) {
                ArtworkView(images: playlist.images, size: 30, cornerRadius: 4)
                Text(playlist.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(playing ? palette.highlight : (selected ? .white : Theme.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if playing {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(palette.highlight)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Theme.selection : (hovering ? Theme.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.floe)
        .onHover { hovering = $0 }
        .floeAnimation(value: hovering, duration: 0.16)
        .floeAnimation(value: selected, duration: 0.2)
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
        HStack(spacing: 10) {
            ArtworkView(images: library.profile?.images, size: 30, circle: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(library.profile?.displayName ?? player.username ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
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
        }
    }

    private var statusColor: Color {
        player.isConnected ? palette.accent : .orange
    }

    private var statusText: LocalizedStringKey {
        player.isConnected ? "Connected" : "Reconnecting…"
    }
}
