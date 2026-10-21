import Foundation

/// Settings for a harness that never reach ~/Library/Preferences. A suite named
/// by an absolute path is that plist, so each lives in this run's temporary
/// folder, which goes when the process exits, however it exits. A suite named
/// by a word, and `.standard`, write to the real preferences even under
/// CFFIXED_USER_HOME, and removing their domain still leaves the file behind.
enum TestDefaults {
    private static let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("floe-test-defaults-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestDefaults.folder) }
        return folder
    }()

    /// A new, empty set of settings.
    static func make() -> UserDefaults {
        UserDefaults(suiteName: folder.appendingPathComponent(UUID().uuidString).path)!
    }
}
