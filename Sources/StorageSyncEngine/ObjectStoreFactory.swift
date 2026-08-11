import Foundation
import StorageSyncCore
import StorageSyncS3
import StorageSyncSystem

public struct ObjectStoreFactory: Sendable {
    private let keychain: KeychainStore

    public init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    public func make(connection: S3Connection) async throws -> any ObjectStore {
        guard let credentials = try await keychain.load(reference: connection.credentialReference) else {
            throw ObjectStoreError.authentication("Credentials are missing from Keychain.")
        }
        return S3ObjectStore(
            configuration: S3ClientConfiguration(
                endpoint: connection.endpoint,
                region: connection.region,
                bucket: connection.bucket,
                addressingStyle: connection.addressingStyle,
                credentials: credentials
            )
        )
    }
}
