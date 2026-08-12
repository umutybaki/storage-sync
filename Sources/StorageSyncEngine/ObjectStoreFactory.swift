import Foundation
import StorageSyncCore
import StorageSyncS3
import StorageSyncSystem

public struct ObjectStoreFactory: Sendable {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    /// - Parameter credentials: Keys to use instead of the connection's saved
    ///   ones. Only the check that runs before a credential is saved passes
    ///   these; every other caller leaves it `nil` so the secret is read from
    ///   the Keychain at the moment it is needed and nowhere kept.
    public func make(
        connection: S3Connection,
        credentials: S3Credentials? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> any ObjectStore {
        let resolved: S3Credentials
        if let credentials {
            resolved = credentials
        } else if let stored = try await keychain.load(reference: connection.credentialReference) {
            resolved = stored
        } else {
            throw ObjectStoreError.authentication("Credentials are missing from Keychain.")
        }
        return S3ObjectStore(
            configuration: S3ClientConfiguration(
                endpoint: connection.endpoint,
                region: connection.region,
                bucket: connection.bucket,
                addressingStyle: connection.addressingStyle,
                credentials: resolved,
                timeout: timeout ?? 120
            )
        )
    }
}
