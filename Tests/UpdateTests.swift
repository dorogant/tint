import CryptoKit
import Foundation

/// The updater without GitHub or the real app: versions, the feed's answers,
/// and the whole install on stand-in app bundles in a temporary folder, zipped
/// and signed here the way a release is. Each way an archive can be wrong must
/// leave the installed copy exactly as it was.
@main
@MainActor
struct UpdateTests {
    static var checks = 0
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("tint-update-tests-\(getpid())")
    static let key = Curve25519.Signing.PrivateKey()
    static var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    static func main() async {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        versionChecks()
        await feedChecks()
        await installerChecks()
        await relaunchChecks()
        await modelChecks()
        print("PASS: \(checks) update checks (versions, GitHub's answers, signatures, the swap and every refusal, reopening, the daily check)")
    }

    // MARK: - Versions

    static func versionChecks() {
        func v(_ text: String) -> AppVersion {
            guard let version = AppVersion(text) else { fail("\(text) must be a version") }
            return version
        }
        check(v("0.4.1") > v("0.4.0") && v("0.4.10") > v("0.4.9") && v("0.10") > v("0.9.9") && v("1") > v("0.99.99"), "versions must compare number by number")
        check(v("v0.4.1") == v("0.4.1") && v("0.4") == v("0.4.0") && v(" 1.0.0\n") == v("1"), "a tag's v, trailing zeros and spaces must not matter")
        check(!(v("0.4.0") < v("0.4")) && !(v("0.4") < v("0.4.0")), "0.4 and 0.4.0 must be the same version")
        check(v("0.4").description == "0.4.0" && v("v1.2.3.4").description == "1.2.3.4" && v("2").description == "2.0.0", "a version must read as at least three numbers")
        for text in ["", "v", "0.5.0-beta", "1..2", "a.b", "1.2.3.4.5", "-1", "1.x", "nightly", "１.0", "1.0 beta", "99999999.0"] {
            check(AppVersion(text) == nil, "\"\(text)\" must not be a version")
        }
        check(Set([v("0.4"), v("0.4.0"), v("v0.4.0.0")]).count == 1, "equal versions must hash alike")
    }

    // MARK: - Feed

    /// GitHub's answer for the release that was latest when this was written, trimmed to what matters, with a signature added.
    nonisolated static func release(tag: String = "v0.4.1", assets: [(String, String)] = [("Tint.zip", "https://github.com/dorogant/tint/releases/download/v0.4.1/Tint.zip"),
                                                                             ("Tint.zip.sig", "https://github.com/dorogant/tint/releases/download/v0.4.1/Tint.zip.sig")]) -> Data {
        let list = assets.map { #"{"name":"\#($0.0)","size":6059807,"digest":"sha256:2f38","content_type":"application/zip","browser_download_url":"\#($0.1)"}"# }.joined(separator: ",")
        return Data(#"{"url":"https://api.github.com/repos/dorogant/tint/releases/458772283","html_url":"https://github.com/dorogant/tint/releases/tag/\#(tag)","tag_name":"\#(tag)","name":"Tint","draft":false,"prerelease":false,"assets":[\#(list)]}"#.utf8)
    }

    static func feedChecks() async {
        let transport = StubTransport()
        var feed = UpdateFeed(transport: transport)
        feed.userAgent = "Tint/0.4.0"

        transport.respond = { _ in (release(), 200) }
        let latest = await attempt { try await feed.latest() }
        check(latest == .success(UpdateRelease(version: AppVersion("0.4.1")!, page: URL(string: "https://github.com/dorogant/tint/releases/tag/v0.4.1")!,
                                               archive: URL(string: "https://github.com/dorogant/tint/releases/download/v0.4.1/Tint.zip")!,
                                               signature: URL(string: "https://github.com/dorogant/tint/releases/download/v0.4.1/Tint.zip.sig")!)),
              "the latest release must be read with its page, zip and signature (\(latest))")
        let asked = transport.requests.last
        check(asked?.url == UpdateFeed.latest && asked?.value(forHTTPHeaderField: "User-Agent") == "Tint/0.4.0"
              && asked?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json" && asked?.httpBody == nil && asked?.url?.query == nil,
              "the check must ask GitHub's latest-release address, naming only Tint and its version")

        transport.respond = { _ in (release(tag: "v0.4.0", assets: [("Tint.zip", "https://github.com/dorogant/tint/releases/download/v0.4.0/Tint.zip")]), 200) }
        let unsigned = await attempt { try await feed.latest() }
        check((try? unsigned.get())??.isInstallable == false && (try? unsigned.get())??.archive != nil, "a release without a signature must not be installable")

        transport.respond = { _ in (release(assets: [("Tint.zip", "http://example.com/Tint.zip"), ("Tint.zip.sig", "file:///tmp/sig")]), 200) }
        let insecure = await attempt { try await feed.latest() }
        check((try? insecure.get())??.archive == nil && (try? insecure.get())??.signature == nil, "links that aren't https must be dropped")

        transport.respond = { _ in (release(tag: "nightly"), 200) }
        check(await attempt { try await feed.latest() } == .success(nil), "a release whose tag isn't a version must be passed over")
        transport.respond = { _ in (Data("<html>".utf8), 200) }
        check(await attempt { try await feed.latest() } == .failure(.unexpected), "an answer that isn't a release must be a problem, not a crash")
        for (status, expected) in [(404, Result<UpdateRelease?, UpdateProblem>.success(nil)), (403, .failure(.busy)), (429, .failure(.busy)),
                                   (500, .failure(.unreachable)), (503, .failure(.unreachable)), (418, .failure(.unexpected))] {
            transport.respond = { _ in (Data(), status) }
            let result = await attempt { try await feed.latest() }
            check(result == expected, "status \(status) must be \(expected), was \(result)")
        }
        transport.respond = { _ in throw URLError(.notConnectedToInternet) }
        check(await attempt { try await feed.latest() } == .failure(.unreachable), "no connection must be \"unreachable\"")

        let url = URL(string: "https://github.com/dorogant/tint/releases/download/v0.4.1/Tint.zip.sig")!
        let signature = Data((0..<64).map { UInt8($0) })
        transport.respond = { _ in (Data((signature.base64EncodedString() + "\n").utf8), 200) }
        check(await attempt { try await feed.signature(at: url) } == .success(signature), "a signature must be read through its trailing newline")
        transport.respond = { _ in (Data("not base64 at all!".utf8), 200) }
        check(await attempt { try await feed.signature(at: url) } == .failure(.badSignature), "a signature file that isn't one must be refused")
        transport.respond = { _ in (Data(repeating: 65, count: UpdateFeed.signatureLimit + 4), 200) }
        check(await attempt { try await feed.signature(at: url) } == .failure(.unexpected), "an oversized signature file must be refused")

        let file = root.appendingPathComponent("download.zip")
        transport.respond = { _ in (Data("zip".utf8), 200) }
        check(await attempt { try await feed.download(url, to: file) } == .success(()) && (try? Data(contentsOf: file)) == Data("zip".utf8), "a download must land in its file")
        transport.respond = { _ in (Data(), 200) }
        check(await attempt { try await feed.download(url, to: file) } == .failure(.damaged), "an empty download must be refused")
        transport.respond = { _ in (Data("gone".utf8), 404) }
        check(await attempt { try await feed.download(url, to: file) } == .failure(.unexpected), "a download that isn't there must be a problem")
    }

    // MARK: - Installer

    /// A stand-in Tint: a real signed bundle around a copy of /usr/bin/true.
    @discardableResult
    static func makeApp(at url: URL, version: String, identifier: String = "com.example.tint", note: String = "", breakSignature: Bool = false) -> URL {
        let contents = url.appendingPathComponent("Contents")
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try! FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/Tint").path)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Tint",
                                   "CFBundlePackageType": "APPL", "CFBundleName": "Tint"]
        try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try! Data(note.utf8).write(to: contents.appendingPathComponent("Resources/note.txt"))
        guard run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", url.path]) else { fail("couldn't sign the stand-in app") }
        if breakSignature {
            // A resource changed after signing: what a truncated or altered bundle looks like to macOS.
            try! Data("changed".utf8).write(to: contents.appendingPathComponent("Resources/note.txt"))
        }
        return url
    }

    /// Zips a bundle as scripts/package-app.sh does and signs the zip.
    static func pack(_ app: URL, name: String, signedBy signer: Curve25519.Signing.PrivateKey = key) -> (archive: URL, signature: Data) {
        let archive = root.appendingPathComponent("\(name).zip")
        try? FileManager.default.removeItem(at: archive)
        guard run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path]) else { fail("couldn't zip the stand-in app") }
        return (archive, try! signer.signature(for: Data(contentsOf: archive)))
    }

    static func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    static func note(in app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/Resources/note.txt"), encoding: .utf8)
    }

    static func installerChecks() async {
        let apps = root.appendingPathComponent("Applications")
        try! FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let installed = apps.appendingPathComponent("Tint.app")
        let sources = root.appendingPathComponent("Sources")
        try! FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        func fresh(_ version: String, identifier: String = "com.example.tint", breakSignature: Bool = false) -> URL {
            makeApp(at: sources.appendingPathComponent("Tint.app"), version: version, identifier: identifier, note: "new", breakSignature: breakSignature)
        }
        var installer = UpdateInstaller(app: installed, bundleIdentifier: "com.example.tint", running: AppVersion("0.4.0")!)
        installer.publicKey = publicKey
        /// The copy that every refusal must leave alone.
        func untouched() -> Bool {
            version(of: installed) == "0.4.0" && note(in: installed) == "old" && run("/usr/bin/codesign", ["--verify", "--strict", installed.path])
        }

        makeApp(at: installed, version: "0.4.0", note: "old")
        check(untouched(), "the stand-in installed copy must be a valid signed bundle")

        // Every refusal first, on the same installed copy.
        let good = pack(fresh("0.4.1"), name: "good")
        let stranger = pack(fresh("0.4.1"), name: "stranger", signedBy: Curve25519.Signing.PrivateKey())
        check(await attempt { try await installer.install(archive: stranger.archive, signature: stranger.signature) } == .failure(.badSignature) && untouched(),
              "an archive signed with another key must be refused")
        check(await attempt { try await installer.install(archive: good.archive, signature: stranger.signature) } == .failure(.badSignature) && untouched(),
              "a signature of another archive must be refused")
        let altered = root.appendingPathComponent("altered.zip")
        try! (Data(contentsOf: good.archive) + Data([0])).write(to: altered)
        check(await attempt { try await installer.install(archive: altered, signature: good.signature) } == .failure(.badSignature) && untouched(),
              "an archive changed by one byte must be refused")
        check(await attempt { try await installer.install(archive: good.archive, signature: Data()) } == .failure(.badSignature) && untouched(),
              "an empty signature must be refused")
        var builtIn = installer
        builtIn.publicKey = UpdateInstaller.publicKey
        let refused = await attempt { try await builtIn.install(archive: good.archive, signature: good.signature) }
        check(Data(base64Encoded: UpdateInstaller.publicKey)?.count == 32 && refused == .failure(.badSignature) && untouched(),
              "the key built into Tint must be a real key, and must refuse an archive signed with the test's")
        var broken = installer
        broken.publicKey = "nonsense"
        check(await attempt { try await broken.install(archive: good.archive, signature: good.signature) } == .failure(.damaged) && untouched(),
              "without a usable key nothing may be installed")

        let same = pack(fresh("0.4.0"), name: "same")
        check(await attempt { try await installer.install(archive: same.archive, signature: same.signature) } == .failure(.notNewer) && untouched(),
              "a signed archive of the running version must be refused")
        let older = pack(fresh("0.3.9"), name: "older")
        check(await attempt { try await installer.install(archive: older.archive, signature: older.signature) } == .failure(.notNewer) && untouched(),
              "a signed archive of an older version must be refused: a release can't be replayed to go back")
        let other = pack(fresh("0.4.1", identifier: "com.example.other"), name: "other")
        check(await attempt { try await installer.install(archive: other.archive, signature: other.signature) } == .failure(.damaged) && untouched(),
              "a signed archive of another app must be refused")
        let unsealed = pack(fresh("0.4.1", breakSignature: true), name: "unsealed")
        check(await attempt { try await installer.install(archive: unsealed.archive, signature: unsealed.signature) } == .failure(.damaged) && untouched(),
              "a bundle macOS wouldn't start must be refused while the old copy is still there")
        let text = root.appendingPathComponent("text.zip")
        let plain = sources.appendingPathComponent("readme.txt")
        try! Data("no app here".utf8).write(to: plain)
        _ = run("/usr/bin/ditto", ["-c", "-k", plain.path, text.path])
        check(await attempt { try await installer.install(archive: text, signature: try! key.signature(for: Data(contentsOf: text))) } == .failure(.damaged) && untouched(),
              "a signed archive with no app in it must be refused")
        let garbage = root.appendingPathComponent("garbage.zip")
        try! Data("this is not a zip".utf8).write(to: garbage)
        check(await attempt { try await installer.install(archive: garbage, signature: try! key.signature(for: Data(contentsOf: garbage))) } == .failure(.damaged) && untouched(),
              "a signed file that isn't a zip must be refused")

        // Places a copy can't be replaced from.
        var moved = installer
        moved.app = URL(fileURLWithPath: "/private/var/folders/zz/T/AppTranslocation/0F2C/d/Tint.app")
        check(await attempt { try moved.preflight() } == .failure(.translocated), "a copy macOS runs from a translocated folder must say so")
        let locked = root.appendingPathComponent("Locked")
        try! FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        makeApp(at: locked.appendingPathComponent("Tint.app"), version: "0.4.0", note: "old")
        try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        var fixed = installer
        fixed.app = locked.appendingPathComponent("Tint.app")
        check(await attempt { try await fixed.install(archive: good.archive, signature: good.signature) } == .failure(.notWritable)
              && version(of: fixed.app) == "0.4.0", "a copy in a folder that can't be changed must say so and stay")
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        var bare = installer
        bare.app = root.appendingPathComponent("Tint")
        check(await attempt { try bare.preflight() } == .failure(.notWritable), "something that isn't an app bundle must not be replaced")

        // And the update itself.
        check(await attempt { try installer.preflight() } == .success(()), "a copy in a folder of the user's own must pass")
        let result = await attempt { try await installer.install(archive: good.archive, signature: good.signature) }
        guard case let .success(done) = result else { fail("a good update must install, got \(result)") }
        check(done.version == AppVersion("0.4.1") && version(of: installed) == "0.4.1" && note(in: installed) == "new"
              && run("/usr/bin/codesign", ["--verify", "--strict", installed.path]),
              "the new copy must stand where the old one did, its signature intact")
        let previous = done.staging.appendingPathComponent("Previous.app")
        check(version(of: previous) == "0.4.0" && note(in: previous) == "old", "the old copy must be kept until Tint has reopened")
        check((try? FileManager.default.contentsOfDirectory(atPath: apps.path)) == ["Tint.app"], "nothing else may be left in the app's folder")
        try? FileManager.default.removeItem(at: done.staging)
    }

    // MARK: - Reopening

    static func relaunchChecks() async {
        let staging = root.appendingPathComponent("Staging")
        try! FileManager.default.createDirectory(at: staging.appendingPathComponent("Previous.app"), withIntermediateDirectories: true)
        let opened = root.appendingPathComponent("opened")
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["1.2"]
        try! old.run()
        // `touch` stands in for `open`: the file appears when Tint would be opened.
        check(UpdateInstaller.relaunch(after: old.processIdentifier, staging: staging, app: opened, opener: "/usr/bin/touch"), "the waiting shell must start")
        try? await Task.sleep(for: .milliseconds(500))
        check(!FileManager.default.fileExists(atPath: opened.path) && FileManager.default.fileExists(atPath: staging.path),
              "nothing may be opened or cleared while the old process is alive")
        old.waitUntilExit()
        var waited = 0
        while !FileManager.default.fileExists(atPath: opened.path), waited < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        check(FileManager.default.fileExists(atPath: opened.path), "the new copy must be opened once the old process has gone")
        check(!FileManager.default.fileExists(atPath: staging.path), "the old copy must be cleared away by then")
    }

    // MARK: - Model

    static func modelChecks() async {
        let apps = root.appendingPathComponent("ModelApps")
        try! FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let installed = makeApp(at: apps.appendingPathComponent("Tint.app"), version: "0.4.0", note: "old")
        let sources = root.appendingPathComponent("ModelSources")
        try! FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let update = pack(makeApp(at: sources.appendingPathComponent("Tint.app"), version: "0.4.1", note: "new"), name: "model")
        let archive = try! Data(contentsOf: update.archive)

        let transport = StubTransport()
        let clock = Clock()
        var installer = UpdateInstaller(app: installed, bundleIdentifier: "com.example.tint", running: AppVersion("0.4.0")!)
        installer.publicKey = publicKey
        func model(_ defaults: UserDefaults, enabled: Bool = true, version: String = "0.4.0") -> UpdateModel {
            UpdateModel(isEnabled: enabled, version: AppVersion(version)!, feed: UpdateFeed(transport: transport), installer: installer,
                        defaults: defaults, now: { clock.now })
        }
        /// GitHub with 0.4.1 out: the feed, then the signature and the zip by their names.
        func serve(signature: Data = update.signature) {
            transport.respond = { request in
                switch request.url?.lastPathComponent {
                case "Tint.zip": (archive, 200)
                case "Tint.zip.sig": (Data(signature.base64EncodedString().utf8), 200)
                default: (release(), 200)
                }
            }
        }

        // A copy built from source never asks.
        let local = model(TestDefaults.make(), enabled: false)
        local.checkIfDue()
        await local.due?.value
        await local.check()
        await local.install()
        check(transport.requests.isEmpty && local.release == nil && local.activity == .idle, "a copy built from source must never ask GitHub")

        // Up to date, and the day between checks.
        var defaults = TestDefaults.make()
        transport.respond = { _ in (release(tag: "v0.4.0"), 200) }
        var updates = model(defaults)
        check(updates.automatic && updates.lastChecked == nil && updates.release == nil, "a fresh copy checks by itself and knows of no release")
        updates.checkIfDue()
        await updates.due?.value
        check(transport.requests.count == 1 && updates.release == nil && updates.problem == nil && updates.lastChecked == clock.now && updates.activity == .idle,
              "the first activation must check, and find the running version current")
        clock.now += UpdateModel.interval - 60
        updates.checkIfDue()
        await updates.due?.value
        check(transport.requests.count == 1, "within a day of a check, coming to the front must not ask again")
        check(model(defaults).lastChecked == updates.lastChecked, "the time of the last check must survive a relaunch")
        clock.now += 120
        serve()
        updates.checkIfDue()
        await updates.due?.value
        check(transport.requests.count == 2 && updates.release?.version == AppVersion("0.4.1") && updates.release?.isInstallable == true,
              "a day later it must ask again and find the newer release")

        // The offer outlives a relaunch, and ends once that version runs.
        let before = transport.requests.count
        check(model(defaults).release == updates.release && transport.requests.count == before, "a known newer release must be offered at launch without asking")
        check(model(defaults, version: "0.4.1").release == nil && model(defaults).release == nil, "once that version is running the offer must be gone for good")

        // A failed check: said, not counted as a check, and not repeated on every activation.
        defaults = TestDefaults.make()
        transport.respond = { _ in throw URLError(.timedOut) }
        updates = model(defaults)
        updates.checkIfDue()
        await updates.due?.value
        let failures = transport.requests.count
        check(updates.problem == .unreachable && updates.lastChecked == nil && updates.activity == .idle, "a check that fails must say why and not count as checked")
        clock.now += UpdateModel.retry - 60
        updates.checkIfDue()
        await updates.due?.value
        check(transport.requests.count == failures, "after a failed check, the next activation must not try at once")
        clock.now += 120
        serve()
        updates.checkIfDue()
        await updates.due?.value
        check(transport.requests.count == failures + 1 && updates.problem == nil && updates.release != nil, "an hour later it must try again, and the problem must clear")

        // Checking by itself switched off.
        defaults = TestDefaults.make()
        updates = model(defaults)
        updates.automatic = false
        clock.now += 10 * UpdateModel.interval
        let quiet = transport.requests.count
        updates.checkIfDue()
        await updates.due?.value
        check(transport.requests.count == quiet && !model(defaults).automatic, "with automatic checks off nothing may be asked, and the choice must be kept")
        await updates.check()
        check(transport.requests.count == quiet + 1 && updates.release != nil, "Check Now must still ask")

        // A release that can only be downloaded by hand.
        transport.respond = { _ in (release(assets: [("Tint.zip", "https://github.com/dorogant/tint/releases/download/v0.4.1/Tint.zip")]), 200) }
        await updates.check()
        let manual = transport.requests.count
        await updates.install()
        check(updates.release?.isInstallable == false && transport.requests.count == manual && updates.activity == .idle && version(of: installed) == "0.4.0",
              "a release without a signature must be offered but never downloaded")

        // A download that isn't Tint's.
        serve(signature: try! Curve25519.Signing.PrivateKey().signature(for: archive))
        await updates.check()
        var reopened: [UpdateInstaller.Installed] = []
        updates.reopen = { reopened.append($0) }
        await updates.install()
        check(updates.problem == .badSignature && updates.activity == .idle && reopened.isEmpty && version(of: installed) == "0.4.0" && note(in: installed) == "old",
              "a download with the wrong signature must be reported and leave Tint as it was")

        // The update, start to finish.
        serve()
        await updates.install()
        check(updates.problem == nil && updates.activity == .reopening && reopened.count == 1 && reopened.first?.version == AppVersion("0.4.1"),
              "a good update must end with Tint asked to reopen")
        check(version(of: installed) == "0.4.1" && note(in: installed) == "new", "and with the new copy in place")
        let asked = transport.requests.suffix(2).compactMap { $0.url?.lastPathComponent }
        check(asked == ["Tint.zip.sig", "Tint.zip"], "the install must fetch the signature and the zip, nothing else (\(asked))")
        let again = transport.requests.count
        await updates.install()
        await updates.check()
        check(transport.requests.count == again, "while Tint is reopening nothing more may start")
        reopened.forEach { try? FileManager.default.removeItem(at: $0.staging) }
    }

    // MARK: - Support

    /// Closures don't infer a typed throw, so the problem is picked out here.
    static func attempt<T: Sendable>(_ body: () async throws -> T) async -> Result<T, UpdateProblem> {
        do { return .success(try await body()) } catch let problem as UpdateProblem { return .failure(problem) } catch { fail("unexpected error \(error)") }
    }

    static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fail(message) }
    }

    nonisolated static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

extension Result where Success == Void, Failure: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.success, .success): true
        case let (.failure(x), .failure(y)): x == y
        default: false
        }
    }
}

/// The time the model reads, moved by the test.
final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

/// GitHub's stand-in: answers from a closure and remembers what it was asked.
final class StubTransport: UpdateTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [URLRequest] = []
    private var responder: @Sendable (URLRequest) throws -> (Data, Int) = { _ in (Data(), 500) }

    var requests: [URLRequest] { lock.withLock { asked } }
    var respond: @Sendable (URLRequest) throws -> (Data, Int) {
        get { lock.withLock { responder } }
        set { lock.withLock { responder = newValue } }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let responder = lock.withLock { asked.append(request); return self.responder }
        return try responder(request)
    }

    func download(_ request: URLRequest, to file: URL) async throws -> Int {
        let (data, status) = try await fetch(request)
        try data.write(to: file)
        return status
    }
}
