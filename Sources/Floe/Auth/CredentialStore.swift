import Foundation
import os
import Security

/// Tint's saved Spotify logins: one file per account in
/// `~/Library/Application Support/Floe/Credentials` (0700, files 0600, excluded from backups).
///
/// Trade-off: any process running as this user can read these files. Spotify's own
/// desktop client keeps its login the same way, and FileVault protects them at rest.
/// The Keychain would be stricter, but without a Team ID macOS ties each item to the
/// build's code hash, so every rebuild asked for the login password.
///
/// Calls block on file I/O and, once per account, on the Keychain migration prompt,
/// so keep them off the main thread.
final class CredentialStore: Sendable {
    enum Account: String, Sendable {
        /// Reusable librespot credentials (JSON).
        case playbackSession = "librespot-session"
        /// Web API tokens for Tint's own client ID (JSON: access + refresh token).
        case webAPI = "web-api"
    }

    /// Where earlier builds kept credentials; only touched to move each item out once.
    struct Legacy: Sendable {
        var read: @Sendable (Account) -> Data?
        var delete: @Sendable (Account) -> Void
    }

    static let shared = CredentialStore(
        directory: .applicationSupportDirectory.appending(path: "Floe/Credentials", directoryHint: .isDirectory),
        legacy: .keychain
    )

    private let directory: URL
    private let legacy: Legacy
    /// One operation at a time, so a migration can't race a write for the same account.
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.antonchurchyn.floe", category: "credentials")

    init(directory: URL, legacy: Legacy) {
        self.directory = directory
        self.legacy = legacy
    }

    func read(_ account: Account) -> Data? {
        lock.withLock {
            if let data = try? Data(contentsOf: file(account)) { return data }
            return migrate(account)
        }
    }

    func write(_ data: Data, account: Account) {
        lock.withLock {
            if save(data, account) { retireLegacy(account) }
        }
    }

    /// Signing out clears the file and any legacy item.
    func delete(_ account: Account) {
        lock.withLock {
            try? FileManager.default.removeItem(at: file(account))
            legacy.delete(account)
            markRetired(account)
        }
    }

    // MARK: - Migration

    /// Moves the account's legacy Keychain item into its file on first read. Reading it may
    /// show one last password prompt. Deleting it shouldn't: apps on an item's access list
    /// may delete it without asking, and Tint's signing certificate keeps it on that list.
    private func migrate(_ account: Account) -> Data? {
        guard !isRetired(account) else { return nil }
        let data = legacy.read(account)
        if let data, !save(data, account) { return data } // keep the item; retry next launch
        retireLegacy(account)
        if data != nil { log.notice("Moved \(account.rawValue, privacy: .public) out of the Keychain") }
        return data
    }

    /// Once retired, an account never consults the Keychain again, even if deleting failed,
    /// so a denied prompt isn't repeated and signed-out credentials can't come back.
    private func retireLegacy(_ account: Account) {
        guard !isRetired(account) else { return }
        legacy.delete(account)
        markRetired(account)
    }

    private func isRetired(_ account: Account) -> Bool {
        FileManager.default.fileExists(atPath: marker(account).path)
    }

    private func markRetired(_ account: Account) {
        guard (try? prepareDirectory()) != nil else { return }
        FileManager.default.createFile(atPath: marker(account).path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    // MARK: - Files

    private func file(_ account: Account) -> URL { directory.appending(path: account.rawValue) }
    private func marker(_ account: Account) -> URL { directory.appending(path: account.rawValue + ".migrated") }

    /// Writes beside the target, narrows it to 0600, then renames it into place, so readers
    /// never see a partial file. The 0700 folder keeps the temporary copy private.
    private func save(_ data: Data, _ account: Account) -> Bool {
        let target = file(account), temporary = target.appendingPathExtension("new")
        do {
            try prepareDirectory()
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log.error("Couldn't save \(account.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Creates the folder (or tightens an existing one) as 0700 and keeps it out of backups.
    private func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
    }
}

extension CredentialStore.Legacy {
    /// Generic-password items in the login keychain, as builds before `CredentialStore` saved them.
    static let keychain = Self(
        read: { account in
            // Attributes never prompt, so check that the item exists before asking for its secret.
            var query = keychainQuery(account)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnAttributes as String] = true
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
            query[kSecReturnAttributes as String] = nil
            query[kSecReturnData as String] = true
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
            return item as? Data
        },
        delete: { account in
            _ = SecItemDelete(keychainQuery(account) as CFDictionary)
        }
    )

    private static func keychainQuery(_ account: CredentialStore.Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.antonchurchyn.floe",
            kSecAttrAccount as String: account.rawValue,
        ]
    }
}
