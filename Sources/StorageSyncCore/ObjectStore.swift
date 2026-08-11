import Foundation

public struct ObjectPage: Sendable, Equatable {
    public var objects: [RemoteObject]
    public var nextContinuationToken: String?

    public init(objects: [RemoteObject], nextContinuationToken: String?) {
        self.objects = objects
        self.nextContinuationToken = nextContinuationToken
    }
}

public struct UploadedPart: Codable, Hashable, Sendable {
    public let number: Int
    public let eTag: String
    public let size: Int64?
    public let checksum: String?

    public init(number: Int, eTag: String, size: Int64? = nil, checksum: String? = nil) {
        self.number = number
        self.eTag = eTag
        self.size = size
        self.checksum = checksum
    }
}

public protocol ObjectStore: Sendable {
    func list(prefix: String, continuationToken: String?) async throws -> ObjectPage
    func head(key: String) async throws -> RemoteObject?
    func put(key: String, data: Data, metadata: [String: String]) async throws -> RemoteObject
    func createMultipartUpload(key: String, metadata: [String: String]) async throws -> String
    func uploadPart(key: String, uploadID: String, partNumber: Int, data: Data) async throws -> UploadedPart
    func listParts(key: String, uploadID: String) async throws -> [UploadedPart]
    func completeMultipartUpload(key: String, uploadID: String, parts: [UploadedPart]) async throws -> RemoteObject
    func abortMultipartUpload(key: String, uploadID: String) async throws
    func getRange(key: String, range: Range<Int64>?) async throws -> Data
}

public enum ObjectStoreError: Error, LocalizedError, Sendable, Equatable {
    case notFound
    case authentication(String)
    case accessDenied(String)
    case invalidResponse(String)
    case incompatible(String)
    case transient(String)
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .notFound: "The S3 object or multipart upload no longer exists."
        case .authentication(let message): message
        case .accessDenied(let message): message
        case .invalidResponse(let message): message
        case .incompatible(let message): message
        case .transient(let message): message
        case .checksumMismatch: "The downloaded data did not match its expected checksum."
        }
    }
}
