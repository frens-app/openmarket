import Foundation
import Security

/// The session tokens, in the keychain rather than `UserDefaults`.
///
/// `UserDefaults` is a plist in the app container: readable from a backup, and
/// readable by anything that gets at the container on a jailbroken device. A
/// refresh token is a year-long credential for the account, so it belongs
/// behind the keychain's encryption.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the accessibility the
/// app actually needs: available to background work after the first unlock
/// following a reboot, and `ThisDeviceOnly` so it never rides an encrypted
/// backup onto a second device — restoring a backup should not clone a
/// logged-in session.
enum Keychain {
    private static let service = "lol.frens.openmarket.session"

    static func set(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }

        // SecItemUpdate can't create, and SecItemAdd fails on a duplicate, so
        // delete-then-add is the one sequence that is correct in both states.
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
