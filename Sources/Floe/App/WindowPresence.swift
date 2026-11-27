import AppKit
import Observation

/// Whether Tint is the app in front, and whether any of its windows shows at
/// least a pixel. Clocks, the audio tap and the live effects run only while
/// both hold.
///
/// Both are read from AppKit each time something that could change them
/// happens, so a missed or reordered notification is put right by the next
/// one. They used to come from elsewhere: "in front" from SwiftUI's
/// `scenePhase`, which stayed inactive after a few quick switches between
/// apps, so the visualizer and the live background stood still until Tint was
/// restarted (the tap's last start in the system log was eleven minutes before
/// the report, with Tint in front and playing since); and the notifications
/// through async sequences, which hand them over later and one by one.
@MainActor
@Observable
final class WindowPresence {
    struct State: Equatable, Sendable {
        var isActive: Bool
        var isVisible: Bool
    }

    private(set) var isActive = true
    private(set) var isVisible = true
    @ObservationIgnored private let truth: @MainActor () -> State
    @ObservationIgnored private nonisolated(unsafe) var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    /// Everything after which the answer may differ. More than strictly needed:
    /// each costs one comparison, and each is another chance to notice.
    static let triggers: [Notification.Name] = [
        NSApplication.didFinishLaunchingNotification,
        NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        NSWindow.didChangeOcclusionStateNotification,
        // Minimizing doesn't post an occlusion change, so it's asked about separately.
        NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
    ]

    init(center: NotificationCenter = .default, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         truth: @escaping @MainActor () -> State = WindowPresence.appKit) {
        self.truth = truth
        for name in Self.triggers { observe(name, on: center) }
        observe(NSWorkspace.activeSpaceDidChangeNotification, on: workspace)
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    /// No queue: the block runs where the notification is posted, which for
    /// all of these is the main thread, so the state is right before the
    /// poster's next line.
    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
            let name = notification.name
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh(after: name) }
            } else {
                Task { @MainActor in self?.refresh(after: name) }
            }
        }
        observers.append((center, token))
    }

    func refresh(after name: Notification.Name? = nil) {
        var state = truth()
        // The two that say it themselves are taken at their word, whatever
        // `isActive` reads while AppKit is still in the middle of the change.
        if name == NSApplication.didBecomeActiveNotification { state.isActive = true }
        if name == NSApplication.didResignActiveNotification { state.isActive = false }
        if state.isActive != isActive { isActive = state.isActive }
        if state.isVisible != isVisible { isVisible = state.isVisible }
    }

    static func appKit() -> State {
        guard let app = NSApp else { return State(isActive: true, isVisible: true) }
        return State(isActive: app.isActive, isVisible: app.windows.contains {
            $0.canBecomeMain && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        })
    }
}
