import Foundation
import Security

protocol GBrainSecretStore {
    func contains(_ name: String) -> Bool
    func read(_ name: String) throws -> String?
    func save(_ value: String, name: String) throws
    func remove(_ name: String) throws
}

/// Values never enter defaults, MCP configuration, argv, state files or diagnostics.
struct GBrainKeychain: GBrainSecretStore {
    static let service = "TATWO.GBrain"
    let root: String

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "\(name):\(root)",
         kSecAttrSynchronizable as String: false]
    }
    func contains(_ name: String) -> Bool {
        var q = query(name)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
    func read(_ name: String) throws -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw Failure.keychain }
        return value
    }
    func save(_ value: String, name: String) throws {
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\0") else { throw Failure.invalid }
        let q = query(name)
        let update = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q
            insert.merge(update) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain }
    }
    func remove(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain }
    }
    enum Failure: Error { case keychain, invalid, readOnly }
}
