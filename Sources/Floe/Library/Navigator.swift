import Foundation
import Observation

/// Where the content area is. Sidebar picks replace the stack; links push.
enum Route: Hashable {
    case home, search, songs
    case playlist(String), album(String), artist(String)
}

@MainActor
@Observable
final class Navigator {
    enum Surface: String, CaseIterable { case library, nowPlaying, lyrics }
    var surface: Surface = .library
    private(set) var stack: [Route] = [.home]

    var current: Route { stack[stack.count - 1] }
    var root: Route { stack[0] }
    var canGoBack: Bool { stack.count > 1 }

    /// What the sidebar highlights. Search opens over the page you were on, so
    /// while its results (or a page opened from them) show, Search is the section.
    var section: Route { stack.contains(.search) ? .search : root }

    /// Bumped each time Search is asked for (⌘F), so the sidebar field takes
    /// focus even when Search is already showing. Going Back to Search doesn't.
    private(set) var searchFocusRequest = 0
    /// The last request the field acted on.
    @ObservationIgnored var searchFocusHandled = 0

    /// Sidebar picks start a new stack. Search is the exception: it's a field,
    /// not a row, so asking for it focuses the field and shows the results.
    func select(_ route: Route) {
        surface = .library
        if route == .search {
            showSearch()
            searchFocusRequest += 1
        } else {
            stack = [route]
        }
    }

    func push(_ route: Route) {
        surface = .library
        if route != current { stack.append(route) }
    }

    func back() {
        if canGoBack { stack.removeLast() }
    }

    /// Shows the results over the current page, so Back (or Escape in the
    /// field) returns there. Search already in the stack is reused, not stacked.
    func showSearch() {
        surface = .library
        guard current != .search else { return }
        if let index = stack.lastIndex(of: .search) {
            stack.removeSubrange((index + 1)...)
        } else {
            stack.append(.search)
        }
    }

    /// Leaves the results for the page underneath, if Search opened over one.
    func closeSearch() {
        guard current == .search, canGoBack else { return }
        stack.removeLast()
    }

    /// Opens an artist/album/playlist from a `spotify:` URI.
    func open(uri: String) {
        let parts = uri.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return }
        switch parts[1] {
        case "artist": push(.artist(parts[2]))
        case "album": push(.album(parts[2]))
        case "playlist": push(.playlist(parts[2]))
        default: break
        }
    }
}
