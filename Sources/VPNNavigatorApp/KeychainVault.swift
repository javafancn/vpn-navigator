import Foundation
import Security

/// Credentials are optional, per profile, and never written to a .ovpn file or app logs.
/// Passwords stay in the user's login Keychain, not in root-owned profile storage.
enum KeychainVault {
    private static let service = "com.javafancn.vpn-navigator.credentials"

    struct Credentials: Codable {
        let username: String
        let password: String
    }
    static func load(id: UUID) -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    static func store(_ credentials: Credentials, id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let changes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw VaultError.keychain(updateStatus) }
        var toInsert = identity
        toInsert[kSecValueData as String] = data
        toInsert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(toInsert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw VaultError.keychain(insertStatus) }
    }
    /// Explicit maintenance action scoped to this app, including credentials
    /// whose profile was removed by an earlier app version.
    static func removeAll() throws {
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service]
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }

    static func remove(id: UUID) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        _ = SecItemDelete(identity as CFDictionary)
    }
}
enum VaultError: Error, LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? { "macOS Keychain operation failed." }
}

