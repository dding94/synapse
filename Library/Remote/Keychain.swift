import Foundation
import Security

/// SecretStore 구현: macOS 키체인(generic password). 토큰은 여기에만 저장한다.
final class KeychainSecretStore: SecretStore {
    static let service = "local.codex.synapse.atlassian"

    init() {}

    private func baseQuery(_ account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretStore.service,
            kSecAttrAccount as String: account,
        ]
    }

    func secret(for account: String) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "Synapse.Keychain", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "키체인에 토큰을 저장하지 못했어요."])
        }
    }

    func removeSecret(for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
