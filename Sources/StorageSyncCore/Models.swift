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
        return !isRemovable
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
        prefix
            .split(separator: "/", omittingEmptySubsequences: true)
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

    public init(
        key: String,
        size: Int64,
        lastModified: Date? = nil,
        eTag: String? = nil,
        checksum: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
        self.checksum = checksum
        self.metadata = metadata
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
    public var temporaryPath: String?
    public var retryCount: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
        filesAlreadyPresent: Int? = nil
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
    }
}
