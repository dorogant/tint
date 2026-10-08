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

    /// Bumped each time Search is chosen (sidebar or ⌘F), so the field takes
    /// focus even when Search is already showing. Going Back to Search doesn't.
    private(set) var searchFocusRequest = 0
    /// The last request the field acted on.
    @ObservationIgnored var searchFocusHandled = 0

    func select(_ route: Route) {
        surface = .library
        stack = [route]
        if route == .search { searchFocusRequest += 1 }
    }

    func push(_ route: Route) {
        surface = .library
        if route != current { stack.append(route) }
    }

    func back() {
        if canGoBack { stack.removeLast() }
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
