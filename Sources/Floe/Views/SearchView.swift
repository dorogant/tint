import AppKit
import SwiftUI

/// Results for the toolbar's search field.
struct SearchView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(SearchModel.self) private var search
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.sectionGap) {
            if let error = search.error {
                MessageView(systemImage: "exclamationmark.triangle", message: error, tint: .orange)
            }
            if let results = search.results {
                if !search.songs.isEmpty {
                    VStack(alignment: .leading, spacing: scale.headerGap) {
                        SectionHeader(title: "Songs") {
                            if search.canLoadMoreSongs {
                                ShowMoreButton(busy: search.isLoadingMore) {
                                    Task { await search.loadMoreSongs(library.api) }
                                }
                            }
                        }
                        let entries = search.songs.enumerated().map { TrackEntry(id: $0, track: $1) }
                        TrackListView(entries: entries) { entry in
                            // Play the results as a list so next/previous move through them.
                            player.play(PlayRequest(tracks: search.songs.map(\.uri), startURI: entry.track.uri), selectedTrack: entry.track)
                        }
                    }
                    .reveal("songs")
                }
                Shelf(title: "Artists", items: results.artists?.items ?? []) { artist in
                    Card(images: artist.images, title: artist.name, circle: true, size: 128) {
                        navigator.push(.artist(artist.id))
                    } play: {
                        player.play(PlayRequest(contextURI: artist.uri))
                    }
                }
                .reveal("artists", order: 1)
                Shelf(title: "Albums", items: results.albums?.items ?? []) { album in
                    Card(images: album.images, title: album.name,
                         subtitle: album.artists?.map(\.name).joined(separator: ", ") ?? "") {
                        navigator.push(.album(album.id))
                    } play: {
                        player.play(PlayRequest(contextURI: album.uri))
                    }
                }
                .reveal("albums", order: 2)
                Shelf(title: "Playlists", items: results.playlists?.items ?? []) { playlist in
                    Card(images: playlist.images, title: playlist.name,
                         subtitle: playlist.owner.displayName ?? "") {
                        navigator.push(.playlist(playlist.id))
                    } play: {
                        player.play(PlayRequest(contextURI: playlist.uri))
                    }
                }
                .reveal("playlists", order: 3)
            } else if search.isSearching {
                LoadingView()
            } else {
                MessageView(systemImage: "magnifyingglass", message: L10n.string("Search for songs, artists, albums and playlists."))
                    .padding(.top, scale(96))
            }
        }
        .revealScope()
        .task(id: search.text) { await search.search(library.api) }
    }
}

/// Search lives in the toolbar, as in Music and Finder, so it's reachable from
/// Now Playing and Lyrics too. It's the system's search field: it collapses to
/// a button when the window is narrow and grows when focused.
///
/// Typing (or ⌘F) shows the results over the page you were on, switching back
/// to Library first. Escape or the clear button empties it and goes back to that
/// page; deleting the query by hand stays on Search, ready for another. Opening
/// a result hands the keyboard back, so Space plays and pauses again.
struct ToolbarSearch: ViewModifier {
    @Environment(Navigator.self) private var navigator
    @Environment(SearchModel.self) private var search
    @FocusState private var focused: Bool
    /// False just after the window opens, when AppKit hands its keyboard focus
    /// to the first text field it finds. Search only takes focus when asked.
    @ViewState private var acceptsFocus = false

    func body(content: Content) -> some View {
        @Bindable var search = search
        content
            .searchable(text: $search.text, placement: .toolbar, prompt: Text("Search"))
            .searchFocused($focused)
            .onSubmit(of: .search) { showResults() }
            .onChange(of: search.text) { old, new in
                if focused { showResults() }
                if !old.isEmpty, new.isEmpty, !Self.deletedByHand { navigator.closeSearch() }
            }
            .onChange(of: focused) {
                if focused && !acceptsFocus { focused = false } else if focused { showResults() }
            }
            .onChange(of: navigator.current) { if navigator.current != .search { focused = false } }
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                acceptsFocus = true
            }
            .task(id: navigator.searchFocusRequest) { await takeRequestedFocus() }
    }

    private func showResults() {
        if !search.text.trimmingCharacters(in: .whitespaces).isEmpty { navigator.showSearch() }
    }

    /// Backspace or forward-delete emptied the field, rather than Escape or ✕.
    private static var deletedByHand: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.keyCode == 51 || event.keyCode == 117
    }

    /// Only explicit requests (⌘F) take focus; re-renders and Back never do.
    /// The window may be bringing Library back at the same moment, so keep
    /// asking for a few frames until focus sticks.
    private func takeRequestedFocus() async {
        guard navigator.searchFocusRequest != navigator.searchFocusHandled else { return }
        navigator.searchFocusHandled = navigator.searchFocusRequest
        acceptsFocus = true
        if focused {
            // Asked again while typing: select the query, ready to replace.
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
            return
        }
        for _ in 0..<12 where !Task.isCancelled && !focused {
            focused = true
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

/// A quiet capsule beside the Songs header; dims while the next page loads.
private struct ShowMoreButton: View {
    let busy: Bool
    let action: () -> Void
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Show more")
                .floeFont(size: 12, weight: .semibold)
                .foregroundStyle(hovering ? .white : Theme.secondary)
                .padding(.horizontal, scale(12))
                .padding(.vertical, scale(6))
                .background(.white.opacity(hovering ? 0.12 : 0.07), in: Capsule())
        }
        .buttonStyle(.floe)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .onHover { hovering = $0 }
        .floeHover(hovering)
    }
}
