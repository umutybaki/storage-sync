import Foundation
import StorageSyncCore

public struct S3ClientConfiguration: Sendable {
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var addressingStyle: AddressingStyle
    public var credentials: S3Credentials
    public var timeout: TimeInterval

    public init(
        endpoint: URL,
        region: String,
        bucket: String,
        addressingStyle: AddressingStyle,
        credentials: S3Credentials,
        timeout: TimeInterval = 120
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.addressingStyle = addressingStyle
        self.credentials = credentials
        self.timeout = timeout
    }
}
