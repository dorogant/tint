import Foundation
import Observation

/// Whether a newer Tint is out, and moving to it when asked. It asks GitHub at
/// most once a day, and only when the app comes to the front: no timer runs
/// for it. Nothing is downloaded or replaced until the person says so.
@MainActor
@Observable
final class UpdateModel {
    enum Activity: Equatable {
        case idle, checking, downloading, installing
        /// The new copy is in place and Tint is about to quit into it.
        case reopening
    }

    /// Only copies made for others update themselves (`scripts/build-app.sh
    /// --public` marks them): one built from source would be replaced by the
    /// public build, which has no Spotify client ID and another signature.
    let isEnabled: Bool
    let version: AppVersion
    private(set) var activity = Activity.idle
    /// A release newer than this copy, kept between launches so the offer
    /// doesn't vanish until the next daily check.
    private(set) var release: UpdateRelease?
    private(set) var problem: UpdateProblem?
    private(set) var lastChecked: Date?
    var automatic: Bool { didSet { defaults.set(automatic, forKey: Keys.automatic) } }
    /// Quits into the new copy; set by the app, absent in tests.
    @ObservationIgnored var reopen: (UpdateInstaller.Installed) -> Void = { _ in }

    static let interval: TimeInterval = 24 * 3600
    /// After a check that failed, so a Mac that's offline isn't asked on every activation.
    static let retry: TimeInterval = 3600

    private enum Keys {
        static let automatic = "updateAutomatic", lastChecked = "updateLastChecked", release = "updateRelease"
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let feed: UpdateFeed
    @ObservationIgnored private let installer: UpdateInstaller?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastAttempt: Date?
    /// The check `checkIfDue` started, for tests to wait on.
    @ObservationIgnored private(set) var due: Task<Void, Never>?

    init(isEnabled: Bool, version: AppVersion, feed: UpdateFeed, installer: UpdateInstaller?,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.isEnabled = isEnabled
        self.version = version
        self.feed = feed
        self.installer = installer
        self.defaults = defaults
        self.now = now
        automatic = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = (defaults.object(forKey: Keys.lastChecked) as? Double).map(Date.init(timeIntervalSince1970:))
        // An offer for the version now running is the update that was just installed.
        if let known = defaults.data(forKey: Keys.release).flatMap({ try? JSONDecoder().decode(UpdateRelease.self, from: $0) }), known.version > version {
            release = known
        } else {
            defaults.removeObject(forKey: Keys.release)
        }
    }

    /// The running copy: its version and place from the bundle, updates on if the build says so.
    convenience init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) ?? AppVersion("0")!
        var feed = UpdateFeed()
        feed.userAgent = "Tint/\(version)"
        let installer = bundle.bundleIdentifier.map { UpdateInstaller(app: bundle.bundleURL, bundleIdentifier: $0, running: version) }
        self.init(isEnabled: info["FloeUpdates"] as? Bool == true && installer != nil, version: version, feed: feed, installer: installer)
    }

    /// The daily check, when it's due. Called as the app comes to the front.
    func checkIfDue() {
        let now = now()
        guard isEnabled, automatic, activity == .idle else { return }
        if let lastChecked, now.timeIntervalSince(lastChecked) < Self.interval { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retry { return }
        due = Task { await check() }
    }

    func check() async {
        guard isEnabled, activity == .idle else { return }
        activity = .checking
        problem = nil
        lastAttempt = now()
        defer { activity = .idle }
        do {
            let latest = try await feed.latest()
            release = latest.flatMap { $0.version > version ? $0 : nil }
            lastChecked = now()
            defaults.set(lastChecked?.timeIntervalSince1970, forKey: Keys.lastChecked)
            defaults.set(release.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.release)
        } catch {
            problem = error
        }
    }

    /// Downloads the offered release, proves it is Tint's and puts it in this
    /// copy's place, then hands over to `reopen`.
    func install() async {
        guard isEnabled, activity == .idle, let installer, let release, let archive = release.archive, let signature = release.signature else { return }
        activity = .downloading
        problem = nil
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tint-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do throws(UpdateProblem) {
            // Before the download: no point fetching what can't be put in place.
            try installer.preflight()
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { throw .notWritable }
            let file = folder.appendingPathComponent(UpdateFeed.archiveName)
            let signed = try await feed.signature(at: signature)
            try await feed.download(archive, to: file)
            activity = .installing
            let installed = try await installer.install(archive: file, signature: signed)
            activity = .reopening
            reopen(installed)
        } catch {
            problem = error
            activity = .idle
        }
    }
}
