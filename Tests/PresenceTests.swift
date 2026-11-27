import AppKit
import Foundation

/// `WindowPresence` against a stand-in AppKit: what it reports must be what
/// AppKit says after every notification, at once, however fast they come and
/// whichever one was missed. Being wrong here is not cosmetic: while it says
/// "not in front", the audio tap, the visualizer and the live background stay off.
@main
@MainActor
struct PresenceTests {
    static var checks = 0

    static func main() async {
        let center = NotificationCenter(), workspace = NotificationCenter()
        let world = World()
        let presence = WindowPresence(center: center, workspace: workspace) { world.state }
        func matches() -> Bool { presence.isActive == world.state.isActive && presence.isVisible == world.state.isVisible }

        check(presence.isActive && presence.isVisible, "before AppKit has said anything, Tint counts as in front and visible")

        // Each change is known by the time the post returns.
        world.state.isActive = false
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        check(!presence.isActive && presence.isVisible, "leaving the front must be known as the notification is posted")
        world.state.isVisible = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        check(!presence.isActive && !presence.isVisible, "a covered window must be known as the notification is posted")
        world.state = .init(isActive: true, isVisible: true)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        check(matches(), "coming back must restore both, though only one notification came")

        // Quick switching between apps, as fast as notifications can come.
        var wrong = 0
        for turn in 0..<2000 {
            let front = turn % 2 == 1
            world.state.isActive = front
            center.post(name: front ? NSApplication.didBecomeActiveNotification : NSApplication.didResignActiveNotification, object: nil)
            if turn % 3 == 0 {
                world.state.isVisible = front
                center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            }
            if !matches() { wrong += 1 }
        }
        check(wrong == 0, "after each of 2000 quick switches the state must be AppKit's (\(wrong) were not)")
        check(presence.isActive && world.state.isActive, "and the last one must leave Tint in front")

        // The two that say it themselves win over a reading taken mid-change.
        world.state = .init(isActive: true, isVisible: true)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        check(!presence.isActive, "\"resigned\" must count even while AppKit still reads active")
        world.state.isActive = false
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        check(presence.isActive, "\"became active\" must count even while AppKit still reads inactive")
        world.state.isActive = true

        // A change nobody announced is caught by whatever comes next.
        for name in WindowPresence.triggers {
            world.state = .init(isActive: true, isVisible: true)
            center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            world.state = .init(isActive: name == NSApplication.didBecomeActiveNotification, isVisible: false)
            center.post(name: name, object: nil)
            check(matches(), "\(name.rawValue) must bring the state up to date")
        }
        world.state = .init(isActive: true, isVisible: true)
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        check(matches(), "a change of Space must bring the state up to date")
        world.state.isVisible = false
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        check(presence.isVisible, "a Space change is only listened for on the workspace's centre")
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        check(matches(), "and there it must count")

        // Posted off the main thread, it still arrives.
        world.state = .init(isActive: false, isVisible: true)
        await Task.detached { center.post(name: NSWindow.didBecomeKeyNotification, object: nil) }.value
        for _ in 0..<50 where !matches() { try? await Task.sleep(for: .milliseconds(10)) }
        check(matches(), "a notification from another thread must still be acted on")

        // Observers only hear of real changes.
        let counter = Counter()
        counter.watch(presence)
        var changes: Int { counter.changes }
        for _ in 0..<20 { center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil) }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        check(changes == 0, "notifications that change nothing must not wake the views (\(changes))")
        world.state.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(20))
        check(changes == 1, "a real change must wake them once (\(changes))")

        // Gone means gone: a released presence leaves no observer behind.
        var short: WindowPresence? = WindowPresence(center: center, workspace: workspace) { world.state }
        weak let released = short
        short = nil
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        check(released == nil, "a released presence must not be kept alive by its observers")

        // Without an application object (a harness), nothing is hidden.
        check(WindowPresence.appKit() == .init(isActive: true, isVisible: true) || NSApp != nil, "with no app object, Tint counts as in front")

        print("PASS: \(checks) presence checks (each notification, 2000 quick switches, missed changes, other threads, observers)")
    }

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}

/// What the stand-in AppKit would answer.
@MainActor
final class World {
    var state = WindowPresence.State(isActive: true, isVisible: true)
}

/// Counts the times Observation reports a change in a presence.
@MainActor
final class Counter {
    var changes = 0

    func watch(_ presence: WindowPresence) {
        withObservationTracking { _ = presence.isActive; _ = presence.isVisible } onChange: { [weak self] in
            Task { @MainActor in
                self?.changes += 1
                self?.watch(presence)
            }
        }
    }
}
