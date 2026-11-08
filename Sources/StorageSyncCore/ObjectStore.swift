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

/// What the destination must still look like for a write to go ahead.
///
/// A transfer is planned from a listing that can be hours or days old by the
/// time its turn comes. Writing unconditionally replaced whatever had appeared
/// or changed at the key since then — on a bucket without versioning, someone
/// else's file, gone. S3 checks these on the server, so there is no window
/// between looking and writing.
public enum WritePrecondition: Sendable, Equatable {
    /// No check: the write always goes ahead.
    case none
    /// Only if nothing exists at the key (`If-None-Match: *`).
    case absent
    /// Only if the object at the key still has this ETag (`If-Match`).
    case matching(eTag: String)
}

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
    func getRange(key: String, range: Range<Int64>, matchingETag: String?) async throws -> Data
    /// Conditional forms of the two requests that make an object visible. A
    /// failed condition throws `ObjectStoreError.objectChanged`.
    func put(
        key: String,
        data: Data,
        metadata: [String: String],
        precondition: WritePrecondition,
        progress: @escaping UploadProgressHandler
    ) async throws -> RemoteObject
    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [UploadedPart],
        precondition: WritePrecondition
    ) async throws -> RemoteObject
}

public extension ObjectStore {
    func getRange(key: String, range: Range<Int64>, matchingETag: String?) async throws -> Data {
        guard RemoteObject.comparableETag(matchingETag) == nil else {
            throw ObjectStoreError.incompatible("The store cannot pin a range to an object version.")
        }
        return try await getRange(key: key, range: range)
    }

    func put(
        key: String,
        data: Data,
        metadata: [String: String],
        precondition: WritePrecondition,
        progress: @escaping UploadProgressHandler
    ) async throws -> RemoteObject {
        guard precondition == .none else { throw ObjectStoreError.incompatible("The store cannot perform a conditional upload.") }
        return try await put(key: key, data: data, metadata: metadata, progress: progress)
    }

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [UploadedPart],
        precondition: WritePrecondition
    ) async throws -> RemoteObject {
        guard precondition == .none else { throw ObjectStoreError.incompatible("The store cannot conditionally complete an upload.") }
        return try await completeMultipartUpload(key: key, uploadID: uploadID, parts: parts)
    }

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
    /// The object is no longer the version a transfer was planned against: a
    /// write condition failed, or a ranged read ran past the end of an object
    /// that has since shrunk. The next scan plans against what is there now.
    case objectChanged(String)

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
        case .objectChanged(let message): message
        }
    }
}
