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
}
