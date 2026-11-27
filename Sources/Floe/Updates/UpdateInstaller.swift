import CryptoKit
import Foundation

/// Everything between a downloaded archive and the new Tint standing where
/// the old one did. Nothing is touched until the archive has proved to be
/// Tint's own, and the old copy is kept until the new one is in place.
struct UpdateInstaller: Sendable {
    /// The public half of Tint's update key. Its private half signs each
    /// release's zip (scripts/update-signature.swift, scripts/release.sh).
    static let publicKey = "ND+Gp0F7mde7yKGwrDdCXOsFEXBZiLuNbHfSm/xplwQ="

    /// What `install` leaves behind for the relaunch: the old copy is still in
    /// `staging`, and goes with it once the old process has quit.
    struct Installed: Equatable, Sendable {
        var staging: URL
        var version: AppVersion
    }

    /// The copy to replace.
    var app: URL
    var bundleIdentifier: String
    var running: AppVersion
    var publicKey = Self.publicKey

    /// Fails before anything is downloaded when the copy can't be replaced where it is.
    func preflight() throws(UpdateProblem) {
        // An app opened without being moved out of Downloads runs from a
        // random read-only folder, and its real place can't be found from inside.
        guard !app.path.contains("/AppTranslocation/") else { throw .translocated }
        guard app.pathExtension == "app", FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else { throw .notWritable }
    }

    /// Verifies, unpacks, checks and swaps. Off the main actor: it runs two
    /// tools and waits for them (0.11 s for the 6 MB zip of 0.4.0 on an M3).
    @concurrent nonisolated func install(archive: URL, signature: Data) async throws(UpdateProblem) -> Installed {
        try preflight()
        try verify(archive: archive, signature: signature)
        let staging = try stagingFolder()
        do {
            let fresh = try unpack(archive, into: staging)
            let version = try check(fresh)
            try swap(in: fresh, staging: staging)
            return Installed(staging: staging, version: version)
        } catch {
            // Not while it holds the only copy: a swap that couldn't be undone
            // leaves the old app in there, to be put back by hand.
            if FileManager.default.fileExists(atPath: app.path) { try? FileManager.default.removeItem(at: staging) }
            throw error
        }
    }

    func verify(archive: URL, signature: Data) throws(UpdateProblem) {
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let data = try? Data(contentsOf: archive, options: .mappedIfSafe)
        else { throw .damaged }
        guard key.isValidSignature(signature, for: data) else { throw .badSignature }
    }

    /// A folder on the app's own volume, so that the swap is two renames and
    /// can't stop halfway through a copy.
    private func stagingFolder() throws(UpdateProblem) -> URL {
        do {
            return try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        } catch { throw .notWritable }
    }

    /// ditto, as the zip was made with it: it keeps the bundle's symlinks,
    /// permissions and signature, which a plain unzip doesn't.
    private func unpack(_ archive: URL, into staging: URL) throws(UpdateProblem) -> URL {
        let folder = staging.appendingPathComponent("Unpacked")
        guard Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]),
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              let fresh = items.first(where: { $0.pathExtension == "app" })
        else { throw .damaged }
        return fresh
    }

    /// The unpacked bundle must be this app, newer, and intact: macOS won't
    /// start an Apple Silicon app whose signature doesn't hold, and by then
    /// the old copy would be gone.
    func check(_ fresh: URL) throws(UpdateProblem) -> AppVersion {
        let contents = fresh.appendingPathComponent("Contents")
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              let executable = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/\(executable)").path)
        else { throw .damaged }
        guard version > running else { throw .notNewer }
        guard Self.run("/usr/bin/codesign", ["--verify", "--strict", fresh.path]) else { throw .damaged }
        return version
    }

    /// Old copy out, new copy in. If the new one can't be put in place the
    /// old one goes back, so a failure leaves Tint as it was.
    private func swap(in fresh: URL, staging: URL) throws(UpdateProblem) {
        let previous = staging.appendingPathComponent("Previous.app")
        do {
            try FileManager.default.moveItem(at: app, to: previous)
        } catch { throw Self.problem(error) }
        do {
            try FileManager.default.moveItem(at: fresh, to: app)
        } catch {
            try? FileManager.default.moveItem(at: previous, to: app)
            throw Self.problem(error)
        }
    }

    /// "Operation not permitted" is macOS protecting apps from one another
    /// (App Management); "Permission denied" is the folder's own permissions.
    private static func problem(_ error: any Error) -> UpdateProblem {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let code = error.domain == NSPOSIXErrorDomain ? error.code : (underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : nil)
        return code == Int(EPERM) ? .refused : .notWritable
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Starts a shell that waits for this process to quit, clears away the old
    /// copy and opens the new one. It outlives Tint: a process can't open its
    /// successor after it has gone. It gives up after a minute, in case
    /// quitting was held up, rather than reopen Tint at some later moment.
    @discardableResult
    static func relaunch(after pid: Int32, staging: URL, app: URL, opener: String = "/usr/bin/open") -> Bool {
        let script = """
        n=0
        while /bin/kill -0 "$1" 2>/dev/null; do
            n=$((n + 1)); [ "$n" -gt 300 ] && exit 1
            /bin/sleep 0.2
        done
        /bin/rm -rf "$2" 2>/dev/null
        exec "$3" "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), staging.path, opener, app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
