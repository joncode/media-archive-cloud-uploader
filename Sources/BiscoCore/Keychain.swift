import Foundation
import Security

public struct KeychainStore: SecretStore {
    private let service: String
    public init(service: String = "org.bisco.archive-uploader") { self.service = service }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false]
    }
    public func read(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return result as? Data
    }
    public func write(_ key: String, data: Data) throws {
        let q = query(key)
        let values: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var entry = q.merging(values) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(entry as CFDictionary, nil)
            guard add == errSecSuccess else { throw failure(add) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    public func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    public func clearUploads() throws {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll]
        q[kSecAttrSynchronizable as String] = false
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw failure(status) }
        for entry in (result as? [[String: Any]]) ?? [] {
            if let key = entry[kSecAttrAccount as String] as? String, key.hasPrefix("upload-") { try remove(key) }
        }
    }
    private func failure(_ status: OSStatus) -> ArchiveError {
        ArchiveError("macOS Keychain could not save or read private app data (\(status)). Unlock your login Keychain and retry.")
    }
}
