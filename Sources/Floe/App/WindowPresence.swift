import AppKit
import Observation

/// Whether any of Tint's windows shows at least a pixel. `scenePhase` stays
/// active while the window is covered by other apps, minimized or on another
/// Space, so the live effects kept drawing at full rate with nobody watching.
@MainActor
@Observable
final class WindowPresence {
    private(set) var isVisible = true
    @ObservationIgnored private nonisolated(unsafe) var watchers: [Task<Void, Never>] = []

    init() {
        // Minimizing doesn't post an occlusion change, so it's asked about separately.
        let window: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                           NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                           NSApplication.didHideNotification, NSApplication.didUnhideNotification]
        watchers = window.map { watch($0, on: .default) }
            + [watch(NSWorkspace.activeSpaceDidChangeNotification, on: NSWorkspace.shared.notificationCenter)]
    }

    deinit {
        for watcher in watchers { watcher.cancel() }
    }

    private func watch(_ name: Notification.Name, on center: NotificationCenter) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in center.notifications(named: name) { self?.refresh() }
        }
    }

    private func refresh() {
        let visible = NSApp.windows.contains {
            $0.canBecomeMain && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
        if visible != isVisible { isVisible = visible }
    }
}
