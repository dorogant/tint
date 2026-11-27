import SwiftUI

/// Every saved album, newest first as Spotify lists them. Home shows them as
/// one strip that holds about seven at a time, which read as "seven albums" to
/// someone with a large collection; this is where all of them are.
struct AlbumsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let albums = library.savedAlbums
        VStack(alignment: .leading, spacing: scale.sectionGap) {
            VStack(alignment: .leading, spacing: scale(6)) {
                Text("Albums")
                    .floeFont(size: 32, weight: .heavy)
                    .tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)
                if !albums.isEmpty {
                    Text(L10n.string("\(albums.count) albums")).floeFont(size: 13).foregroundStyle(Theme.secondary)
                }
            }
            .reveal("title")
            if !albums.isEmpty {
                // Cards keep one size, so covers are decoded once whatever the
                // window's width; the columns share out the room that's left.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: scale(Self.cover) + 2 * scale.plate), spacing: 0, alignment: .topLeading)],
                          alignment: .leading, spacing: scale(12)) {
                    ForEach(albums) { album in
                        Card(images: album.images, title: album.name,
                             subtitle: album.artists?.map(\.name).joined(separator: ", ") ?? "", size: Self.cover) {
                            navigator.push(.album(album.id))
                        } play: {
                            player.play(PlayRequest(contextURI: album.uri))
                        }
                    }
                }
                // Cards bring their own plate inset: the covers, not the plates, start on the gutter.
                .padding(.horizontal, -scale.plate)
                .reveal("albums", order: 1)
            } else {
                switch library.savedAlbumsState {
                case .loading:
                    LoadingView()
                case .loaded:
                    MessageView(systemImage: "square.stack", message: L10n.string("Albums you save in Spotify show here."),
                                title: "No saved albums yet")
                case .failed:
                    MessageView(systemImage: "exclamationmark.triangle", message: L10n.string("Your albums couldn't be loaded."), tint: .orange,
                                actionTitle: "Try Again") { Task { await library.refresh() } }
                }
            }
        }
        .revealScope()
    }

    /// The cover's side in Compact points, as on Home's shelves.
    private static let cover: CGFloat = 156
}
