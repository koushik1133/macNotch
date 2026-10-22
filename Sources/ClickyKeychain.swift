import Foundation
import Security

/// The Groq API key for Clicky, kept as a plain generic-password item in
/// the login keychain.
///
/// No `SecAccessControl` is attached: access-controlled items need a signing
/// identity with a team ID, and SparkV is ad-hoc signed, so they fail to
/// save. The item uses the keychain's default ACL (this app may read it).
/// After a rebuild the ad-hoc signature changes, so macOS may ask once whether
/// SparkV may use the item; `hasKey()` never triggers that prompt since it
/// asks for attributes only, and the key itself is read only when asking.
enum ClickyKeychain {
    static let service = "com.notchisland.app.groq"
    static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// True when an item exists. Reads attributes only, so it never prompts.
    static func hasKey() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// The stored key, or nil when there is none or access was refused.
    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                AppLog.log("Clicky: keychain read failed (\(status))")
            }
            return nil
        }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Stores (or replaces) the key. Returns false when the keychain refused it.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            // An item from an older signature that this build can't update:
            // replace it.
            delete()
            return add(data)
        }
        return add(data)
    }

    private static func add(_ data: Data) -> Bool {
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "SparkV Clicky (Groq API key)"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.log("Clicky: keychain save failed (\(status))")
        }
        return status == errSecSuccess
    }

    static func delete() {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            AppLog.log("Clicky: keychain delete failed (\(status))")
        }
    }
}
