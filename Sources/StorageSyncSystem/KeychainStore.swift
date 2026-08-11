import Foundation
import StorageSyncCore
import Security

public enum KeychainStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .invalidPayload:
            "The credential stored in Keychain is invalid."
        }
    }
}

public actor KeychainStore {
    private let service: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "app.photosync.credentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(_ credentials: S3Credentials, reference: String) throws {
        let payload = try encoder.encode(credentials)
        let query = baseQuery(reference: reference)
        let update: [CFString: Any] = [
            kSecValueData: payload,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var item = query
        item[kSecValueData] = payload
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    public func load(reference: String) throws -> S3Credentials? {
        var query = baseQuery(reference: reference)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data else { throw KeychainStoreError.invalidPayload }
        return try decoder.decode(S3Credentials.self, from: data)
    }

    public func remove(reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(reference: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: reference
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }
}
