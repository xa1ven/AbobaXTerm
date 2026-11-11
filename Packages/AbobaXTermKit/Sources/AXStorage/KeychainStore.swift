import Foundation
import Security

/// Generic-password items in the login keychain.
public struct KeychainStore: Sendable {
    public struct KeychainError: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    public let service: String

    public init(service: String = "com.mikhail.AbobaXTerm") {
        self.service = service
    }

    /// Account name for a session password.
    public static func sessionAccount(_ id: UUID) -> String { "session:\(id.uuidString)" }
    /// Account name for a private key passphrase.
    public static func keyAccount(_ path: String) -> String { "key:\(path)" }

    public func password(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Checks presence without reading the secret (does not trigger an access prompt).
    public func hasPassword(account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func setPassword(_ password: String, account: String, label: String? = nil) throws {
        let data = Data(password.utf8)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if let label { attributes[kSecAttrLabel as String] = label }
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add.merge(attributes) { $1 }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func deletePassword(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
