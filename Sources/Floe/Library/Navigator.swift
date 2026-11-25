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
    /// How the current page was reached. A page opened by a click is new and
    /// makes an entrance; one returned to (Back) or reached from the keyboard
    /// (search) is simply there.
    enum Arrival { case fresh, instant }
    /// Set before the stack changes, so the view that sees the new page sees this too.
    @ObservationIgnored private(set) var arrival = Arrival.fresh

    var current: Route { stack[stack.count - 1] }
    var root: Route { stack[0] }
    var canGoBack: Bool { stack.count > 1 }

    /// What the sidebar highlights. Search opens over the page you were on, so
    /// while its results (or a page opened from them) show, Search is the
    /// section and no sidebar row is lit.
    var section: Route { stack.contains(.search) ? .search : root }

    /// Bumped each time Search is asked for (⌘F), so the toolbar field takes
    /// focus even when Search is already showing. Going Back to Search doesn't.
    private(set) var searchFocusRequest = 0
    /// The last request the field acted on.
    @ObservationIgnored var searchFocusHandled = 0

    /// Sidebar picks start a new stack. Search is the exception: it's the
    /// toolbar's field, so asking for it (from any surface) focuses the field
    /// and shows the results over the current page.
    func select(_ route: Route) {
        surface = .library
        if route == .search {
            showSearch()
            searchFocusRequest += 1
        } else {
            arrival = .fresh
            stack = [route]
        }
    }

    private static let maxStackDepth = 64

    func push(_ route: Route) {
        surface = .library
        arrival = .fresh
        guard route != current else { return }
        stack.append(route)
        if stack.count > Self.maxStackDepth {
            // Keep the root route so sidebar section highlighting stays intact.
            stack.remove(at: 1)
        }
    }

    func back() {
        arrival = .instant
        if canGoBack { stack.removeLast() }
    }

    /// Shows the results over the current page, so Back (or Escape in the
    /// field) returns there. Search already in the stack is reused, not stacked.
    func showSearch() {
        surface = .library
        guard current != .search else { return }
        arrival = .instant
        if let index = stack.lastIndex(of: .search) {
            stack.removeSubrange((index + 1)...)
        } else {
            stack.append(.search)
        }
    }

    /// Leaves the results for the page underneath, if Search opened over one.
    func closeSearch() {
        guard current == .search, canGoBack else { return }
        arrival = .instant
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
