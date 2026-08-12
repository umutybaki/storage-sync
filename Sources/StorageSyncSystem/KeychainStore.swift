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

    /// - Parameter label: What the item is called in Keychain Access. The user
    ///   chose this name for the credential, so showing it there is honest
    ///   about what StorageSync keeps and makes the item removable by hand.
    ///   It is metadata, never a secret.
    public func save(_ credentials: S3Credentials, reference: String, label: String? = nil) throws {
        let payload = try encoder.encode(credentials)
        let query = baseQuery(reference: reference)
        var update: [CFString: Any] = [
            kSecValueData: payload,
            // The agent has to read these after a reboot with nobody logged in
            // at the keyboard, so they cannot require an unlocked screen — but
            // they have no business leaving this Mac. `Synchronizable: false`
            // keeps them out of iCloud Keychain, which is the part that
            // actually binds here: macOS puts generic passwords in the
            // file-based login keychain, and that keychain treats accessibility
            // as a declaration rather than enforcing it. The declaration is
            // still the right one to make, and becomes enforcement if the item
            // ever moves to the data protection keychain.
            //
            // Moving it there now is not an option: that keychain needs a
            // keychain-access-group entitlement, which needs an Apple team
            // identifier this ad-hoc signed build does not have, and the switch
            // would orphan every credential already saved.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false
        ]
        if let label {
            update[kSecAttrLabel] = label
            update[kSecAttrDescription] = Self.itemDescription
        }
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var item = query
        item.merge(update) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    /// Renames the Keychain item without touching the secret, so the entry in
    /// Keychain Access keeps matching what the credential is called in
    /// StorageSync.
    public func relabel(reference: String, label: String) throws {
        let update: [CFString: Any] = [
            kSecAttrLabel: label,
            kSecAttrDescription: Self.itemDescription
        ]
        let status = SecItemUpdate(baseQuery(reference: reference) as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    /// Whether a secret is stored under this reference, without reading it.
    /// Used to check that a connection's credential is really there before
    /// saving the connection, which should not need the secret in hand.
    public func contains(reference: String) throws -> Bool {
        var query = baseQuery(reference: reference)
        query[kSecReturnData] = false
        query[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        return true
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

    private static let itemDescription = "StorageSync object storage credentials"

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
