import Foundation
import Security

/// A GitHub token saved in the login keychain.
public struct KeychainToken: Sendable {
    public static let standard = KeychainToken(service: "com.aj604.prtally.github-token")

    private let service: String

    public init(service: String) {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    public func read() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces any saved token. Returns false if the keychain refused.
    @discardableResult
    public func save(_ token: String) -> Bool {
        delete()
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
