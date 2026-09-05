import Foundation
import Security

public struct KeychainStore: Sendable {
    public var service: String

    public init(service: String = "cn.termeow.Termeow") {
        self.service = service
    }

    public func saveSecret(_ secret: String, id: UUID) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            AppLog.storage.error("Keychain save failed: \(status, privacy: .public)")
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func secret(id: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            AppLog.storage.error("Keychain read failed: \(status, privacy: .public)")
            throw CocoaError(.fileReadUnknown)
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteSecret(id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
