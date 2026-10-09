import AppKit
import notify

/// Development aid: renders Tint's own window to PNG, so UI can be checked
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
              let content = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        // The toolbar lives in the titlebar, outside the content view; draw it on top.
        if let titlebar = content.superview?.subviews.first(where: { "\(type(of: $0))".contains("Titlebar") }),
           let bar = titlebar.bitmapImageRepForCachingDisplay(in: titlebar.bounds),
           let context = NSGraphicsContext(bitmapImageRep: rep) {
            titlebar.cacheDisplay(in: titlebar.bounds, to: bar)
            let origin = content.convert(content.bounds, to: nil).origin
            let frame = titlebar.convert(titlebar.bounds, to: nil).offsetBy(dx: -origin.x, dy: -origin.y)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            bar.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        let url = directory.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("[snapshot] \(url.path)")
        fflush(stdout)
    }
}
