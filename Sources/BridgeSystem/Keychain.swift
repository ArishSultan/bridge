import Foundation
import Security

/// Saved SSH passwords, as generic passwords in the login Keychain. The service and account
/// names are v1's, so passwords saved by v1 keep working.
public enum Keychain {
    static let service = "gpu-terminal"

    static func account(host: UInt64) -> String { "ssh:\(host)" }

    public static func password(host: UInt64) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func hasPassword(host: UInt64) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host),
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func setPassword(_ password: String, host: UInt64) -> Bool {
        deletePassword(host: host)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host),
            kSecAttrLabel as String: "Bridge SSH password",
            kSecValueData as String: Data(password.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func deletePassword(host: UInt64) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(host: host),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
