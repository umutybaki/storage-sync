import Foundation

public enum SyncDirection: String, Codable, CaseIterable, Sendable {
    case upload
    case download
}

public enum DeletionPolicy: String, Codable, Sendable {
    case preserveDestination
}

public enum SyncPhase: String, Codable, Sendable {
    case idle
    case scanning
    case transferring
    case verifying
    case watching
    case paused
    case attention
}

public enum SyncBlocker: String, Codable, Hashable, Sendable {
    case localVolumeUnavailable
    case networkUnavailable
    case credentialsUnavailable
    case insufficientSpace
    case providerIncompatible
}

public struct S3Connection: Codable, Hashable, Sendable, Identifiable {
    public let id: ConnectionID
    public var name: String
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var addressingStyle: AddressingStyle
    public var credentialReference: String

    public init(
        id: ConnectionID = ConnectionID(),
        name: String,
        endpoint: URL,
        region: String,
        bucket: String,
        addressingStyle: AddressingStyle = .path,
        credentialReference: String
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.addressingStyle = addressingStyle
        self.credentialReference = credentialReference
    }
}

public enum AddressingStyle: String, Codable, Sendable {
    case path
    case virtualHost
}

public struct S3Credentials: Codable, Hashable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

public struct LocalRoot: Codable, Hashable, Sendable {
    public var displayName: String
    public var fallbackPath: String
    public var bookmarkReference: String
    public var expectedVolume: VolumeIdentity?

    public init(
        displayName: String,
        fallbackPath: String,
        bookmarkReference: String,
        expectedVolume: VolumeIdentity? = nil
    ) {
        self.displayName = displayName
        self.fallbackPath = fallbackPath
        self.bookmarkReference = bookmarkReference
        self.expectedVolume = expectedVolume
    }
}

public struct VolumeIdentity: Codable, Hashable, Sendable {
    public var persistentUUID: String?
    public var creationDate: Date?
    public var filesystemType: String?
    public var totalCapacity: Int64?
    public var isRemovable: Bool
    public var isCaseSensitive: Bool?
    public var rootMarker: UUID?

    public init(
        persistentUUID: String?,
        creationDate: Date?,
        filesystemType: String?,
        totalCapacity: Int64?,
        isRemovable: Bool,
        isCaseSensitive: Bool? = nil,
        rootMarker: UUID? = nil
    ) {
        self.persistentUUID = persistentUUID
        self.creationDate = creationDate
        self.filesystemType = filesystemType
        self.totalCapacity = totalCapacity
        self.isRemovable = isRemovable
        self.isCaseSensitive = isCaseSensitive
        self.rootMarker = rootMarker
    }

    public func confidentlyMatches(_ other: VolumeIdentity) -> Bool {
        if let persistentUUID, let otherUUID = other.persistentUUID {
            guard persistentUUID == otherUUID else { return false }
            // New external-volume pairings also carry a private marker. When
            // one was recorded, require it as a second factor so a cloned or
            // duplicated filesystem UUID cannot impersonate the selected disk.
            if let rootMarker {
                return rootMarker == other.rootMarker
            }
            return true
        }
        if let rootMarker, let otherMarker = other.rootMarker {
            return rootMarker == otherMarker
        }
        return persistentUUID == nil && rootMarker == nil && creationDate != nil
            && filesystemType != nil && totalCapacity != nil && !isRemovable
            && !other.isRemovable
            && creationDate == other.creationDate
            && filesystemType == other.filesystemType
            && totalCapacity == other.totalCapacity
    }
}

public struct SyncJob: Codable, Hashable, Sendable, Identifiable {
    public let id: SyncJobID
    public var name: String
    public var direction: SyncDirection
    public var localRoot: LocalRoot
    public var connectionID: ConnectionID
    public var remotePrefix: String
    public var deletionPolicy: DeletionPolicy
    public var isPaused: Bool
    /// Changes only when the user explicitly selects a different folder pairing.
    public var multipartGeneration: UUID?
    public let createdAt: Date

    public init(
        id: SyncJobID = SyncJobID(),
        name: String,
        direction: SyncDirection,
        localRoot: LocalRoot,
        connectionID: ConnectionID,
        remotePrefix: String,
        deletionPolicy: DeletionPolicy = .preserveDestination,
        isPaused: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.direction = direction
        self.localRoot = localRoot
        self.connectionID = connectionID
        self.remotePrefix = Self.normalizedPrefix(remotePrefix)
        self.deletionPolicy = deletionPolicy
        self.isPaused = isPaused
        self.createdAt = createdAt
    }

    public static func normalizedPrefix(_ prefix: String) -> String {
        Reconciler.pathComponents(prefix).filter { !$0.isEmpty }
            .joined(separator: "/")
    }
}

public struct FileFingerprint: Codable, Hashable, Sendable {
    public var relativePath: String
    public var size: Int64
    public var modificationTimeNanoseconds: Int64
    public var fileIdentifier: String?
    public var generationIdentifier: String?
    public var checksum: String?

    public init(
        relativePath: String,
        size: Int64,
        modificationTimeNanoseconds: Int64,
        fileIdentifier: String? = nil,
        generationIdentifier: String? = nil,
        checksum: String? = nil
    ) {
        self.relativePath = relativePath
        self.size = size
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.fileIdentifier = fileIdentifier
        self.generationIdentifier = generationIdentifier
        self.checksum = checksum
    }

    public func representsSameContent(as other: FileFingerprint) -> Bool {
        if let checksum, let otherChecksum = other.checksum {
            return size == other.size && checksum == otherChecksum
        }
        guard size == other.size,
              modificationTimeNanoseconds == other.modificationTimeNanoseconds else {
            return false
        }
        // When a filesystem exposes a generation counter for the same stable
        // file ID, use it to catch a rewrite whose size and timestamp were
        // deliberately preserved. Do not compare generations across different
        // IDs because removable filesystems may regenerate both on remount.
        if let fileIdentifier, fileIdentifier == other.fileIdentifier,
           let generationIdentifier, let otherGeneration = other.generationIdentifier {
            return generationIdentifier == otherGeneration
        }
        return true
    }

    /// File identifiers are useful only within the current mount. ExFAT and
    /// some external-volume drivers regenerate them whenever a drive returns,
    /// even though the bytes and modification time are unchanged.
    public func representsSameFileState(as other: FileFingerprint) -> Bool {
        guard representsSameContent(as: other) else { return false }
        if let fileIdentifier, let otherIdentifier = other.fileIdentifier,
           fileIdentifier != otherIdentifier {
            return false
        }
        if let generationIdentifier, let otherGeneration = other.generationIdentifier,
           generationIdentifier != otherGeneration {
            return false
        }
        return true
    }
}

public struct RemoteObject: Codable, Hashable, Sendable {
    public var key: String
    public var size: Int64
    public var lastModified: Date?
    public var eTag: String?
    public var checksum: String?
    public var metadata: [String: String]
    /// `x-amz-server-side-encryption` from a HEAD, when the provider sends it.
    /// Listings never carry it. It decides whether an ETag can be read as the
    /// object's MD5: with KMS or customer keys it is not, and checking a
    /// download against it would fail every time.
    public var serverSideEncryption: String?

    public init(
        key: String,
        size: Int64,
        lastModified: Date? = nil,
        eTag: String? = nil,
        checksum: String? = nil,
        metadata: [String: String] = [:],
        serverSideEncryption: String? = nil
    ) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
        self.checksum = checksum
        self.metadata = metadata
        self.serverSideEncryption = serverSideEncryption
    }

    /// Strong ETags identify bytes. Quoting is transport syntax, but case is
    /// significant and a weak validator does not identify an exact representation.
    public static func comparableETag(_ eTag: String?) -> String? {
        guard var value = eTag?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard !value.lowercased().hasPrefix("w/") else { return nil }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty, !value.contains("\""), value.utf8.allSatisfy({ $0 > 32 && $0 != 127 }) else { return nil }
        return value
    }
}

public enum ManifestSide: String, Codable, Sendable {
    case local
    case remote
}

public struct ManifestEntry: Codable, Hashable, Sendable {
    public var jobID: SyncJobID
    public var side: ManifestSide
    public var relativePath: String
    public var fingerprint: FileFingerprint
    public var eTag: String?
    public var scanGeneration: Int64

    public init(
        jobID: SyncJobID,
        side: ManifestSide,
        relativePath: String,
        fingerprint: FileFingerprint,
        eTag: String? = nil,
        scanGeneration: Int64
    ) {
        self.jobID = jobID
        self.side = side
        self.relativePath = relativePath
        self.fingerprint = fingerprint
        self.eTag = eTag
        self.scanGeneration = scanGeneration
    }
}

public enum TransferKind: String, Codable, Sendable {
    case upload
    case download
}

public enum TransferStatus: String, Codable, Sendable {
    case queued
    case running
    case waiting
    case verifying
    case completed
    case failed
    case superseded
}

public struct TransferRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: TransferID
    public let jobID: SyncJobID
    public var relativePath: String
    public var kind: TransferKind
    public var status: TransferStatus
    public var totalBytes: Int64
    public var completedBytes: Int64
    public var sourceFingerprint: FileFingerprint?
    public var remoteSource: RemoteObject?
    public var remoteKey: String
    public var multipartUploadID: String?
    public var multipartGeneration: UUID?
    public var temporaryPath: String?
    public var retryCount: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    /// Why the engine stopped this transfer, decided where the failure was
    /// caught rather than re-derived downstream: `lastError` holds a system
    /// message that macOS localizes, so any consumer matching words in it
    /// reports the wrong cause on a non-English system. Optional so queue rows
    /// written before this field still decode.
    public var waitingBlocker: SyncBlocker?
    /// Downloads of this transfer that arrived whole but failed verification.
    /// A transient fault does not repeat; an object whose recorded checksum is
    /// simply wrong fails every time, and used to be fetched again forever.
    /// Optional so queue rows written before this field still decode.
    public var integrityFailureCount: Int?
    /// Saved before publishing a verified download so a restart can identify the installed bytes.
    public var verifiedDownloadChecksum: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: TransferID = TransferID(),
        jobID: SyncJobID,
        relativePath: String,
        kind: TransferKind,
        status: TransferStatus = .queued,
        totalBytes: Int64,
        completedBytes: Int64 = 0,
        sourceFingerprint: FileFingerprint? = nil,
        remoteSource: RemoteObject? = nil,
        remoteKey: String,
        multipartUploadID: String? = nil,
        temporaryPath: String? = nil,
        retryCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastError: String? = nil,
        waitingBlocker: SyncBlocker? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.relativePath = relativePath
        self.kind = kind
        self.status = status
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.sourceFingerprint = sourceFingerprint
        self.remoteSource = remoteSource
        self.remoteKey = remoteKey
        self.multipartUploadID = multipartUploadID
        self.temporaryPath = temporaryPath
        self.retryCount = retryCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.waitingBlocker = waitingBlocker
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A compact, user-facing record of one transfer in the current sync batch.
/// It deliberately excludes resumable implementation details such as upload
/// IDs and partial-file paths, and remains after a successful queue row is
/// removed so the UI can show what just finished.
public struct TransferActivityItem: Codable, Hashable, Sendable, Identifiable {
    public let id: TransferID
    public let jobID: SyncJobID
    public let batchID: UUID
    public var relativePath: String
    public var kind: TransferKind
    public var status: TransferStatus
    public var totalBytes: Int64
    public var completedBytes: Int64
    /// Bytes handed to the network stack for the current request, including
    /// durable completed parts. This is live presentation state: S3 confirms
    /// the bytes only when the request succeeds, so resumability continues to
    /// use `completedBytes` and saved part rows exclusively.
    public var bytesSent: Int64?
    public var retryCount: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    /// Carried from the queue row so a row can name what it is waiting for
    /// without reading `lastError`, whose wording changes with the system
    /// language. Optional so activity rows written before this field decode.
    public var waitingBlocker: SyncBlocker?
    public let createdAt: Date
    public var updatedAt: Date

    public init(transfer: TransferRecord, batchID: UUID) {
        id = transfer.id
        jobID = transfer.jobID
        self.batchID = batchID
        relativePath = transfer.relativePath
        kind = transfer.kind
        status = transfer.status
        totalBytes = transfer.totalBytes
        completedBytes = transfer.completedBytes
        bytesSent = transfer.completedBytes
        retryCount = transfer.retryCount
        nextAttemptAt = transfer.nextAttemptAt
        lastError = transfer.lastError
        waitingBlocker = transfer.waitingBlocker
        createdAt = transfer.createdAt
        updatedAt = transfer.updatedAt
    }
}

public struct TransferProgressUpdate: Hashable, Sendable {
    public var jobID: SyncJobID
    public var transferID: TransferID
    public var bytesSent: Int64

    public init(jobID: SyncJobID, transferID: TransferID, bytesSent: Int64) {
        self.jobID = jobID
        self.transferID = transferID
        self.bytesSent = bytesSent
    }
}

public enum TransferActivityFilter: String, Codable, CaseIterable, Sendable {
    case all
    case active
    case waiting
    case completed
    case issues
}

/// Keyset pagination remains stable without reading a full activity manifest.
public struct TransferActivityCursor: Codable, Hashable, Sendable {
    public var updatedAtMilliseconds: Int64
    public var transferID: TransferID

    public init(updatedAtMilliseconds: Int64, transferID: TransferID) {
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.transferID = transferID
    }
}

public struct TransferActivityCounts: Codable, Hashable, Sendable {
    public var all: Int
    public var active: Int
    public var waiting: Int
    public var completed: Int
    public var issues: Int

    public init(all: Int = 0, active: Int = 0, waiting: Int = 0, completed: Int = 0, issues: Int = 0) {
        self.all = all
        self.active = active
        self.waiting = waiting
        self.completed = completed
        self.issues = issues
    }

    public subscript(filter: TransferActivityFilter) -> Int {
        switch filter {
        case .all: all
        case .active: active
        case .waiting: waiting
        case .completed: completed
        case .issues: issues
        }
    }
}

public struct TransferActivityPageRequest: Codable, Hashable, Sendable {
    public var jobID: SyncJobID
    public var filter: TransferActivityFilter
    public var cursor: TransferActivityCursor?
    public var limit: Int

    public init(
        jobID: SyncJobID,
        filter: TransferActivityFilter = .all,
        cursor: TransferActivityCursor? = nil,
        limit: Int = 150
    ) {
        self.jobID = jobID
        self.filter = filter
        self.cursor = cursor
        self.limit = limit
    }
}

public struct TransferActivityPage: Codable, Hashable, Sendable {
    public var jobID: SyncJobID
    public var batchID: UUID?
    public var revision: Int64
    public var items: [TransferActivityItem]
    public var nextCursor: TransferActivityCursor?
    public var counts: TransferActivityCounts

    public init(
        jobID: SyncJobID,
        batchID: UUID?,
        revision: Int64,
        items: [TransferActivityItem],
        nextCursor: TransferActivityCursor?,
        counts: TransferActivityCounts
    ) {
        self.jobID = jobID
        self.batchID = batchID
        self.revision = revision
        self.items = items
        self.nextCursor = nextCursor
        self.counts = counts
    }
}

/// Published only after the SQLite transaction carrying the matching revision
/// has committed. Consumers may therefore use it as a reload signal without
/// ever observing a half-written queue transition.
public struct TransferActivityUpdate: Hashable, Sendable {
    public var jobID: SyncJobID
    public var revision: Int64

    public init(jobID: SyncJobID, revision: Int64) {
        self.jobID = jobID
        self.revision = revision
    }
}

public struct TransferPart: Codable, Hashable, Sendable {
    public let transferID: TransferID
    public let number: Int
    public var offset: Int64
    public var length: Int64
    public var checksum: String
    public var eTag: String?
    public var isComplete: Bool

    public init(
        transferID: TransferID,
        number: Int,
        offset: Int64,
        length: Int64,
        checksum: String,
        eTag: String? = nil,
        isComplete: Bool = false
    ) {
        self.transferID = transferID
        self.number = number
        self.offset = offset
        self.length = length
        self.checksum = checksum
        self.eTag = eTag
        self.isComplete = isComplete
    }
}

public struct SyncSnapshot: Codable, Hashable, Sendable {
    public var jobID: SyncJobID
    public var phase: SyncPhase
    public var blockers: Set<SyncBlocker>
    public var filesCompleted: Int
    public var filesTotal: Int
    public var bytesCompleted: Int64
    public var bytesTotal: Int64
    public var currentRelativePath: String?
    public var lastSuccessfulSync: Date?
    public var message: String
    /// Inventory counts are optional so snapshots written by earlier builds
    /// continue to decode during an in-place upgrade.
    public var sourceFilesFound: Int?
    public var destinationFilesFound: Int?
    public var filesAlreadyPresent: Int?
    /// Bytes the source side held at the scan that opened this cycle.
    public var sourceBytesFound: Int64?
    /// Bytes at the destination that count as current: everything the scan
    /// found there, minus whatever a queued transfer is about to replace.
    /// Without that subtraction a changed file is counted at both ends and
    /// inflates the total the storage balance is drawn against.
    ///
    /// This is deliberately *not* advanced as individual files complete.
    /// `StorageBalance` adds `bytesCompleted` to it, so incrementing here too
    /// would count the same bytes twice; the coordinator folds the run's
    /// finished work in once, when the transfer loop ends.
    public var destinationBytesInPlace: Int64?
    /// A filesystem event or explicit Sync Now request arrived while a cycle
    /// was active. The engine finishes only the already-admitted transfer
    /// batch before scanning again.
    public var isRescanPending: Bool?
    /// Work first discovered by the latest scan that added anything to the
    /// durable queue. Optional additive fields keep old snapshots decodable.
    public var recentlyQueuedCount: Int?
    public var recentlyQueuedPaths: [String]?
    public var recentlyQueuedAt: Date?
    /// A secondary notice for a source mutation proved by content metadata.
    /// Unstable filesystem identity alone never produces this user-facing text.
    public var sourceChangeNotice: String?

    public init(
        jobID: SyncJobID,
        phase: SyncPhase,
        blockers: Set<SyncBlocker> = [],
        filesCompleted: Int = 0,
        filesTotal: Int = 0,
        bytesCompleted: Int64 = 0,
        bytesTotal: Int64 = 0,
        currentRelativePath: String? = nil,
        lastSuccessfulSync: Date? = nil,
        message: String = "",
        sourceFilesFound: Int? = nil,
        destinationFilesFound: Int? = nil,
        filesAlreadyPresent: Int? = nil,
        sourceBytesFound: Int64? = nil,
        destinationBytesInPlace: Int64? = nil,
        isRescanPending: Bool? = nil,
        recentlyQueuedCount: Int? = nil,
        recentlyQueuedPaths: [String]? = nil,
        recentlyQueuedAt: Date? = nil,
        sourceChangeNotice: String? = nil
    ) {
        self.jobID = jobID
        self.phase = phase
        self.blockers = blockers
        self.filesCompleted = filesCompleted
        self.filesTotal = filesTotal
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.currentRelativePath = currentRelativePath
        self.lastSuccessfulSync = lastSuccessfulSync
        self.message = message
        self.sourceFilesFound = sourceFilesFound
        self.destinationFilesFound = destinationFilesFound
        self.filesAlreadyPresent = filesAlreadyPresent
        self.sourceBytesFound = sourceBytesFound
        self.destinationBytesInPlace = destinationBytesInPlace
        self.isRescanPending = isRescanPending
        self.recentlyQueuedCount = recentlyQueuedCount
        self.recentlyQueuedPaths = recentlyQueuedPaths
        self.recentlyQueuedAt = recentlyQueuedAt
        self.sourceChangeNotice = sourceChangeNotice
    }
}
