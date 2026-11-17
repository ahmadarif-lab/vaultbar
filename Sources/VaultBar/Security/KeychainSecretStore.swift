import Foundation
import Security
import VaultKit

/// Refresh tokens live in the Keychain, this-device-only, never on disk or in defaults.
/// (A refresh token lets the app fetch the encrypted vault; it cannot decrypt anything.)
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service = "dev.ahmadarif.vaultbar.tokens"

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for key: String) {
        remove(key)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    func remove(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}
