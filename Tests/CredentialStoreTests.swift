import Foundation

/// Stands in for the login keychain and counts every call; the real one is never touched.
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CredentialStore.Account: Data]
    private var reads = 0, deletes = 0
    private let denies: Bool, keepsItems: Bool, readDelay: TimeInterval

    /// `denies`: the item exists but the prompt is refused. `keepsItems`: deleting fails.
    init(_ items: [CredentialStore.Account: Data] = [:], denies: Bool = false, keepsItems: Bool = false,
         readDelay: TimeInterval = 0) {
        self.items = items
        self.denies = denies
        self.keepsItems = keepsItems
        self.readDelay = readDelay
    }

    var legacy: CredentialStore.Legacy {
        CredentialStore.Legacy(read: { self.read($0) }, delete: { self.delete($0) })
    }
    var counts: [Int] { lock.withLock { [reads, deletes] } }
    func has(_ account: CredentialStore.Account) -> Bool { lock.withLock { items[account] != nil } }

    private func read(_ account: CredentialStore.Account) -> Data? {
        Thread.sleep(forTimeInterval: readDelay)
        return lock.withLock {
            reads += 1
            return denies ? nil : items[account]
        }
    }

    private func delete(_ account: CredentialStore.Account) {
        lock.withLock {
            deletes += 1
            if !keepsItems { items[account] = nil }
        }
    }
}

@main
struct CredentialStoreTests {
    static func main() throws {
        // A scratch folder from the script; never Application Support.
        let root = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        precondition(!root.path.contains("Application Support"))
        var runs = 0
        func folder() -> URL {
            runs += 1
            return root.appending(path: "run-\(runs)/Floe/Credentials", directoryHint: .isDirectory)
        }
        let token = Data(#"{"accessToken":"synthetic"}"#.utf8), newer = Data(#"{"accessToken":"newer"}"#.utf8)

        // Round trip, overwrite, delete.
        var directory = folder()
        var keychain = FakeKeychain()
        var store = CredentialStore(directory: directory, legacy: keychain.legacy)
        store.write(token, account: .webAPI)
        let saved = try Data(contentsOf: directory.appending(path: "web-api"))
        precondition(store.read(.webAPI) == token && saved == token)
        print("PASS: round trip")
        store.write(newer, account: .webAPI)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        precondition(store.read(.webAPI) == newer)
        precondition(files == ["web-api", "web-api.migrated"], "unexpected files: \(files)")
        print("PASS: overwrite")
        store.write(token, account: .playbackSession)
        store.delete(.webAPI)
        precondition(store.read(.webAPI) == nil && store.read(.playbackSession) == token)
        precondition(!FileManager.default.fileExists(atPath: directory.appending(path: "web-api").path))
        print("PASS: delete")

        // Permissions and backup exclusion, including tightening a folder that already existed.
        directory = folder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        store = CredentialStore(directory: directory, legacy: FakeKeychain().legacy)
        store.write(token, account: .playbackSession)
        store.write(newer, account: .playbackSession)
        let directoryMode = try mode(directory), fileMode = try mode(directory.appending(path: "librespot-session"))
        let excluded = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        precondition(directoryMode == 0o700, "directory mode \(String(directoryMode, radix: 8))")
        precondition(fileMode == 0o600, "file mode \(String(fileMode, radix: 8))")
        precondition(excluded == true, "directory must be excluded from backups")
        print("PASS: 0700 directory, 0600 files, excluded from backups")

        // Migration: the first read moves the item into a file and deletes it; later reads and
        // relaunches use the file.
        directory = folder()
        keychain = FakeKeychain([.webAPI: token])
        store = CredentialStore(directory: directory, legacy: keychain.legacy)
        precondition(store.read(.webAPI) == token)
        precondition(keychain.counts == [1, 1] && !keychain.has(.webAPI))
        let migratedMode = try mode(directory.appending(path: "web-api"))
        precondition(migratedMode == 0o600)
        precondition(store.read(.webAPI) == token)
        precondition(CredentialStore(directory: directory, legacy: keychain.legacy).read(.webAPI) == token)
        precondition(keychain.counts == [1, 1], "migration must run once")
        print("PASS: migration moves the Keychain item once")

        // Sign-out clears the file and the legacy item.
        store.delete(.webAPI)
        precondition(keychain.counts == [1, 2], "sign-out must delete any legacy item")
        precondition(store.read(.webAPI) == nil && keychain.counts == [1, 2])
        print("PASS: sign-out clears the file and the legacy item")

        // If the Keychain refuses to delete the item, sign-out still can't bring it back.
        keychain = FakeKeychain([.webAPI: token], keepsItems: true)
        store = CredentialStore(directory: folder(), legacy: keychain.legacy)
        precondition(store.read(.webAPI) == token)
        store.delete(.webAPI)
        precondition(keychain.has(.webAPI) && store.read(.webAPI) == nil && keychain.counts == [1, 2],
                     "signed-out credentials must not return")
        print("PASS: undeletable legacy item is never read again")

        // No legacy item: one lookup, then never again.
        keychain = FakeKeychain()
        store = CredentialStore(directory: folder(), legacy: keychain.legacy)
        precondition(store.read(.playbackSession) == nil && store.read(.playbackSession) == nil)
        precondition(keychain.counts == [1, 1])
        print("PASS: missing legacy item is looked up once")

        // A denied prompt isn't repeated: the item is deleted and the account retired.
        keychain = FakeKeychain([.playbackSession: token], denies: true)
        store = CredentialStore(directory: folder(), legacy: keychain.legacy)
        precondition(store.read(.playbackSession) == nil && store.read(.playbackSession) == nil)
        precondition(keychain.counts == [1, 1] && !keychain.has(.playbackSession))
        print("PASS: denied prompt is not repeated")

        // A fresh login before any read supersedes the legacy item without reading it.
        keychain = FakeKeychain([.webAPI: token])
        store = CredentialStore(directory: folder(), legacy: keychain.legacy)
        store.write(newer, account: .webAPI)
        precondition(store.read(.webAPI) == newer && keychain.counts == [0, 1] && !keychain.has(.webAPI))
        print("PASS: write retires the legacy item unread")

        // Concurrent first reads share one migration, so at most one prompt.
        keychain = FakeKeychain([.webAPI: token], readDelay: 0.05)
        let concurrent = CredentialStore(directory: folder(), legacy: keychain.legacy)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            precondition(concurrent.read(.webAPI) == token)
        }
        precondition(keychain.counts == [1, 1])
        print("PASS: concurrent reads migrate once")
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
    }
}
