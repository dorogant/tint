import Foundation
import Security

/// Generic-password items in the login keychain under Floe's service name.
/// Calls can block on a system prompt, so keep them off the main thread.
enum Keychain {
    enum Account {
        /// Reusable librespot credentials (JSON).
        static let playbackSession = "librespot-session"
    }

    private static let service = "com.antonchurchyn.floe"

    static func read(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> OSStatus {
        let update = SecItemUpdate(
            baseQuery(account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard update == errSecItemNotFound else { return update }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Floe (\(account))"
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
