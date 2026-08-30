import CryptoKit
import Foundation
import Security

/// Locked facts are encrypted before they touch disk or iCloud, so the plaintext
/// only ever exists in memory. Keys live in the Keychain and ride iCloud Keychain
/// to the user's other Macs, which is what lets a sealed value still sync as
/// ordinary JSON.
///
/// Every sealed value names the key that sealed it, and keys are never deleted or
/// overwritten. Two Macs that each mint a key before the other's has synced end up
/// with two keys rather than one clobbering the other, so no ciphertext is ever
/// orphaned — the value simply stays unreadable until its key arrives.
enum Vault {
    /// `bp1:<key id>:<base64 ciphertext>`. Base64 contains no colon, so the
    /// split is unambiguous.
    private static let prefix = "bp1:"

    static func isSealed(_ stored: String) -> Bool {
        stored.hasPrefix(prefix)
    }

    /// Ciphertext for `plaintext`, or nil when no key could be obtained — the
    /// caller must then refuse to store the value rather than write it in the clear.
    static func seal(_ plaintext: String) -> String? {
        guard let (id, key) = currentKey(),
              let combined = try? AES.GCM.seal(Data(plaintext.utf8), using: key).combined
        else { return nil }
        return "\(prefix)\(id):\(combined.base64EncodedString())"
    }

    /// Plaintext for `stored`, or nil when its key hasn't reached this Mac yet.
    static func open(_ stored: String) -> String? {
        guard isSealed(stored) else { return nil }
        let parts = stored.dropFirst(prefix.count).split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let data = Data(base64Encoded: String(parts[1])),
              let key = key(id: String(parts[0])),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(box, using: key)
        else { return nil }
        return String(data: plaintext, encoding: .utf8)
    }

    // MARK: - Keys

    private static let preferredKeyIDDefaultsKey = "vaultKeyID"
    private static var cache: [String: SymmetricKey] = [:]

    /// The key new values are sealed with, minting one the first time anything
    /// is locked on this Mac.
    private static func currentKey() -> (id: String, key: SymmetricKey)? {
        if let id = UserDefaults.standard.string(forKey: preferredKeyIDDefaultsKey),
           let key = key(id: id) {
            return (id, key)
        }
        let id = UUID().uuidString
        let fresh = SymmetricKey(size: .bits256)
        guard let stored = store(fresh, id: id) else { return nil }
        cache[id] = stored
        UserDefaults.standard.set(id, forKey: preferredKeyIDDefaultsKey)
        return (id, stored)
    }

    private static func key(id: String) -> SymmetricKey? {
        if let cached = cache[id] { return cached }
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        let key = SymmetricKey(data: data)
        cache[id] = key
        return key
    }

    /// Adds without ever deleting: a key already under this id is authoritative,
    /// because something is already sealed with it.
    private static func store(_ key: SymmetricKey, id: String) -> SymmetricKey? {
        var item = baseQuery(id: id)
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        // Synchronizable items cannot be device-only; after-first-unlock is the
        // strongest protection class iCloud Keychain accepts.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess: return key
        case errSecDuplicateItem: return self.key(id: id)
        default: return nil
        }
    }

    /// Data-protection keychain, scoped to the Team ID rather than a specific
    /// signature so re-signed builds keep access without a prompt.
    private static func baseQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.backpocket.mac.vault",
            kSecAttrAccount as String: "fact-key.\(id)",
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
