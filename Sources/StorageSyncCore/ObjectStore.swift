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

/// Cumulative body bytes sent for one HTTP request. A successful response is
/// still required before those bytes count as durably uploaded.
public typealias UploadProgressHandler = @Sendable (Int64) async -> Void

public protocol ObjectStore: Sendable {
    func list(prefix: String, continuationToken: String?) async throws -> ObjectPage
    func head(key: String) async throws -> RemoteObject?
    func put(key: String, data: Data, metadata: [String: String]) async throws -> RemoteObject
    func put(
        key: String,
        data: Data,
        metadata: [String: String],
        progress: @escaping UploadProgressHandler
    ) async throws -> RemoteObject
    func createMultipartUpload(key: String, metadata: [String: String]) async throws -> String
    func uploadPart(key: String, uploadID: String, partNumber: Int, data: Data) async throws -> UploadedPart
    func uploadPart(
        key: String,
        uploadID: String,
        partNumber: Int,
        data: Data,
        progress: @escaping UploadProgressHandler
    ) async throws -> UploadedPart
    func listParts(key: String, uploadID: String) async throws -> [UploadedPart]
    func completeMultipartUpload(key: String, uploadID: String, parts: [UploadedPart]) async throws -> RemoteObject
    func abortMultipartUpload(key: String, uploadID: String) async throws
    func getRange(key: String, range: Range<Int64>?) async throws -> Data
}

public extension ObjectStore {
    /// Existing providers and test doubles remain correct without implementing
    /// transport-level progress: they report the complete request at success.
    func put(
        key: String,
        data: Data,
        metadata: [String: String],
        progress: @escaping UploadProgressHandler
    ) async throws -> RemoteObject {
        let object = try await put(key: key, data: data, metadata: metadata)
        await progress(Int64(data.count))
        return object
    }

    func uploadPart(
        key: String,
        uploadID: String,
        partNumber: Int,
        data: Data,
        progress: @escaping UploadProgressHandler
    ) async throws -> UploadedPart {
        let part = try await uploadPart(
            key: key,
            uploadID: uploadID,
            partNumber: partNumber,
            data: data
        )
        await progress(Int64(data.count))
        return part
    }
}

public enum ObjectStoreError: Error, LocalizedError, Sendable, Equatable {
    case notFound
    case authentication(String)
    case accessDenied(String)
    case invalidResponse(String)
    case incompatible(String)
    case transient(String)
    case checksumMismatch
    /// One object the provider lists but will not serve: archived to a storage
    /// class such as Glacier, or locked behind a key these credentials cannot
    /// use. It says nothing about any other object, so it fails that one file
    /// and never the whole sync.
    case objectUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "The S3 object or multipart upload no longer exists."
        case .authentication(let message): message
        case .accessDenied(let message): message
        case .invalidResponse(let message): message
        case .incompatible(let message): message
        case .transient(let message): message
        case .checksumMismatch: "The downloaded data did not match its expected checksum."
        case .objectUnavailable(let message): message
        }
    }
}
