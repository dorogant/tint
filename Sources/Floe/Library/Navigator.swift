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
    private(set) var stack: [Route] = [.home]

    var current: Route { stack[stack.count - 1] }
    var root: Route { stack[0] }
    var canGoBack: Bool { stack.count > 1 }

    func select(_ route: Route) { stack = [route] }

    func push(_ route: Route) {
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
