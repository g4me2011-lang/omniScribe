import Foundation
import Security

/// Secure storage for provider API keys, backed by the macOS Keychain.
///
/// Keys are stored as generic passwords under one service, keyed by the
/// provider's `rawValue`. Nothing here ever touches `UserDefaults`, and keys are
/// never logged (satisfies "keys not visible in plain text" / "never log keys").
final class KeychainManager {

    static let shared = KeychainManager()
    private init() {}

    /// One service namespace for all OmniScribe API keys.
    private let service = "com.omniscribe.app.apikeys"

    enum KeychainError: LocalizedError {
        case encodingFailed
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Could not encode the API key for storage."
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
                return "Keychain error: \(message) (\(status))"
            }
        }
    }

    // MARK: – Create / Update

    /// Stores (or replaces) the key for a provider. Implemented as delete-then-add
    /// so it works whether or not an entry already exists.
    func setAPIKey(_ key: String, for provider: AIProviderID) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        try? deleteAPIKey(for: provider)  // Ignore "not found" from a first-time save.

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      provider.rawValue,
            kSecValueData as String:        data,
            // Available after first unlock so a Launch-at-Login app can read it.
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: – Read

    /// Returns the stored key, or `nil` if none is set for this provider.
    func apiKey(for provider: AIProviderID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      provider.rawValue,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                return nil
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Convenience: `true` if a non-empty key exists.
    func hasAPIKey(for provider: AIProviderID) -> Bool {
        let key = (try? apiKey(for: provider)) ?? nil
        return key?.isEmpty == false
    }

    // MARK: – Delete

    func deleteAPIKey(for provider: AIProviderID) throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  provider.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
