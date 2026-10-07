import AppKit
import notify

/// Development aid: renders Floe's own window to PNG, so UI can be checked
/// without Screen Recording permission. Enabled with `-FloeSnapshotDir <dir>`;
/// `notifyutil -p com.antonchurchyn.floe.snapshot` takes one on demand.
/// Blur materials render flatter than on screen.
@MainActor
enum Snapshot {
    private static var directory: URL? {
        UserDefaults.standard.string(forKey: "FloeSnapshotDir").map { URL(fileURLWithPath: $0) }
    }

    static var canCapture: (() -> Bool)?

    private static var counter = 0
    private static var token: Int32 = 0

    static var isEnabled: Bool { directory != nil }

    static func installTrigger() {
        guard isEnabled, token == 0 else { return }
        notify_register_dispatch("com.antonchurchyn.floe.snapshot", &token, .main) { _ in
            MainActor.assumeIsolated {
                counter += 1
                capture("manual-\(counter)")
            }
        }
    }

    static func capture(_ name: String) {
        guard canCapture?() == true, let directory,
              let view = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = directory.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("[snapshot] \(url.path)")
        fflush(stdout)
    }
}
