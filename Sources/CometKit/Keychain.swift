import Foundation
import Security

/// Reads the Comet X password from the login keychain.
///
/// Matches the entry the shell scripts use, so both front ends share one secret:
///   security add-generic-password -a admin -s glkvm -w
///
/// The password is never written to disk or logged by this project.
public struct Keychain: Sendable {
    public let service: String
    public let account: String

    public init(service: String = "glkvm", account: String = "admin") {
        self.service = service
        self.account = account
    }

    public func password() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            throw CometError.missingCredential(service: service, account: account)
        }
        return password
    }

    /// Creates or overwrites the stored password for `service`/`account`.
    ///
    /// Used by the settings pane. Never called with an empty string — the UI
    /// leaves the password untouched when the field is blank.
    public func savePassword(_ password: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw CometError.keychainWrite(status) }
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else { throw CometError.keychainWrite(status) }
        }
    }
}
