import CryptoKit
import Foundation
import StorageSyncCore
import StorageSyncPersistence
import StorageSyncSystem

public enum TransferExecutionResult: Sendable {
    case completed
    case cancelled
    case waiting(SyncBlocker, String)
    case attention(SyncBlocker?, String)
    /// The optional message is suitable for a secondary user-facing notice.
    /// Identity-only changes still supersede the attempt for safety, but are
    /// silent because removable filesystems can change those identifiers
    /// without changing content.
    case superseded(String?)
    /// This one file waits for its own retry; nothing about it says the rest
    /// of the sync cannot proceed, so the coordinator keeps scheduling.
    case retryingFile(String)
}

public enum TransferExecutionError: Error, LocalizedError {
    case sourceChanged
    case sourceIdentityChanged
    case remoteChanged
    case destinationChanged
    case shortRead(expected: Int64, actual: Int)
    case unexpectedObjectSize(expected: Int64, actual: Int64)
    case invalidRemoteSize(Int64)
    case insufficientSpace(required: Int64, available: Int64)
    case fileTooLarge(size: Int64, maximum: Int64)
    case invalidTransfer

    public var errorDescription: String? {
        switch self {
        case .sourceChanged: "The source file changed while it was being uploaded."
        case .sourceIdentityChanged: "The source file identity changed while it was being uploaded."
        case .remoteChanged: "The S3 object changed while it was being downloaded."
        case .destinationChanged: "The local destination changed while it was being downloaded."
        case .shortRead(let expected, let actual): "Expected \(expected) bytes but read \(actual)."
        case .unexpectedObjectSize(let expected, let actual): "Expected a \(expected)-byte object but S3 reported \(actual) bytes."
        case .invalidRemoteSize(let size): "The S3 provider reported an invalid object size of \(size) bytes."
        case .insufficientSpace(let required, let available): "The destination needs \(required) free bytes but only \(available) are available."
        case .fileTooLarge(let size, let maximum): "The destination filesystem supports files up to \(maximum) bytes, but this file is \(size) bytes."
        case .invalidTransfer: "The saved transfer record is incomplete."
        }
    }
}

private struct UploadedPartCheckpoint: Sendable {
    var part: TransferPart
    var uploaded: UploadedPart
    var checksum: String
}

private struct DownloadedPartCheckpoint: Sendable {
    var part: TransferPart
    var data: Data
    var checksum: String
}

/// Aggregates concurrent multipart request counters into one exact per-file
/// number. It is deliberately live-only: request bytes are not recovery
/// checkpoints until S3 returns success for that part.
private actor LiveUploadProgressReporter {
    private let repository: SyncRepository
    private let jobID: SyncJobID
    private let transferID: TransferID
    private let totalBytes: Int64
    private let clock = ContinuousClock()
    private var acknowledgedBytes: Int64
    private var requestBytes: [Int: Int64] = [:]
    private var lastReportedBytes: Int64
    private var lastReportedAt: ContinuousClock.Instant?

    init(repository: SyncRepository, transfer: TransferRecord, acknowledgedBytes: Int64) {
        self.repository = repository
        jobID = transfer.jobID
        transferID = transfer.id
        totalBytes = max(0, transfer.totalBytes)
        self.acknowledgedBytes = max(0, acknowledgedBytes)
        lastReportedBytes = max(0, acknowledgedBytes)
    }

    func report(requestID: Int, bytesSent: Int64, requestByteCount: Int64) async {
        let bounded = min(max(0, requestByteCount), max(0, bytesSent))
        requestBytes[requestID] = max(requestBytes[requestID] ?? 0, bounded)
        await emit(force: false)
    }

    func acknowledge(requestID: Int, byteCount: Int64) async {
        requestBytes.removeValue(forKey: requestID)
        acknowledgedBytes = min(totalBytes, acknowledgedBytes + max(0, byteCount))
        await emit(force: true)
    }

    private func emit(force: Bool) async {
        let inFlight = requestBytes.values.reduce(Int64(0), +)
        let visibleBytes = min(totalBytes, max(lastReportedBytes, acknowledgedBytes + inFlight))
        let now = clock.now
        let intervalElapsed = lastReportedAt.map {
            $0.duration(to: now) >= .milliseconds(100)
        } ?? true
        guard visibleBytes > lastReportedBytes,
              force || visibleBytes == totalBytes || intervalElapsed else { return }
        lastReportedBytes = visibleBytes
        lastReportedAt = now
        await repository.reportTransferProgress(
            jobID: jobID,
            transferID: transferID,
            bytesSent: visibleBytes
        )
    }
}

public typealias TransferProgressHandler = @Sendable (Int64) async -> Void

public struct TransferExecutor: Sendable {
    private let repository: SyncRepository
    private let objectStore: any ObjectStore
    private let scanner: LocalScanner
    private let volumeInspector: VolumeInspector
    private let transferPolicy: TransferPolicy
    private let retryPolicy: RetryPolicy
    private let verifiesETagDigests: Bool

    /// Three strikes: one verification failure can be a fault in transit or on
    /// disk; the same failure three times running is the object's recorded
    /// checksum, and fetching it again cannot change that.
    public static let maximumIntegrityFailures = 3

    /// - Parameter verifiesETagDigests: Check each finished download against
    ///   its ETag when that ETag is the object's MD5. True only for Amazon S3,
    ///   where the rules for when it is are documented; other providers may
    ///   use 32 hex digits for something else, and a check that fails every
    ///   time would block the file for good.
    public init(
        repository: SyncRepository,
        objectStore: any ObjectStore,
        scanner: LocalScanner = LocalScanner(),
        volumeInspector: VolumeInspector = VolumeInspector(),
        transferPolicy: TransferPolicy = TransferPolicy(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        verifiesETagDigests: Bool = false
    ) {
        self.repository = repository
        self.objectStore = objectStore
        self.scanner = scanner
        self.volumeInspector = volumeInspector
        self.transferPolicy = transferPolicy
        self.retryPolicy = retryPolicy
        self.verifiesETagDigests = verifiesETagDigests
    }

    public func execute(
        _ original: TransferRecord,
        job: SyncJob,
        root: URL,
        progress: @escaping TransferProgressHandler = { _ in }
    ) async -> TransferExecutionResult {
        var transfer = original
        do {
            try Task.checkCancellation()
            try validateVolume(job: job, root: root)
            transfer.status = .running
            transfer.lastError = nil
            transfer.waitingBlocker = nil
            transfer.updatedAt = Date()
            try await repository.saveTransfer(transfer)

            let baseline: ReconciliationBaseline
            switch transfer.kind {
            case .upload:
                baseline = try await uploadClassifyingMissingSource(
                    &transfer,
                    job: job,
                    root: root,
                    progress: progress
                )
            case .download:
                baseline = try await download(&transfer, job: job, root: root, progress: progress)
            }

            try await repository.finalizeSuccessfulTransfer(
                transferID: transfer.id,
                baseline: baseline,
                jobID: job.id
            )
            return .completed
        } catch is CancellationError {
            await deferAfterCancellation(&transfer)
            return .cancelled
        } catch ObjectStoreError.notFound where transfer.kind == .upload && transfer.remoteSource != nil && transfer.multipartUploadID == nil {
            await mark(&transfer, status: .superseded, message: "The listed object disappeared before the conditional write.")
            return .superseded(nil)
        } catch TransferExecutionError.sourceChanged {
            await abortIfNecessary(transfer)
            await discardCheckpoints(for: transfer, job: job, root: root)
            transfer.multipartUploadID = nil
            await mark(&transfer, status: .superseded, message: TransferExecutionError.sourceChanged.localizedDescription)
            return .superseded(TransferExecutionError.sourceChanged.localizedDescription)
        } catch TransferExecutionError.sourceIdentityChanged {
            await abortIfNecessary(transfer)
            await discardCheckpoints(for: transfer, job: job, root: root)
            transfer.multipartUploadID = nil
            await mark(
                &transfer,
                status: .superseded,
                message: TransferExecutionError.sourceIdentityChanged.localizedDescription
            )
            return .superseded(nil)
        } catch TransferExecutionError.remoteChanged {
            await discardCheckpoints(for: transfer, job: job, root: root)
            transfer.temporaryPath = nil
            await mark(&transfer, status: .superseded, message: TransferExecutionError.remoteChanged.localizedDescription)
            return .superseded(nil)
        } catch TransferExecutionError.destinationChanged {
            await abortIfNecessary(transfer)
            await discardCheckpoints(for: transfer, job: job, root: root)
            transfer.multipartUploadID = nil
            transfer.temporaryPath = nil
            await mark(&transfer, status: .superseded, message: TransferExecutionError.destinationChanged.localizedDescription)
            return .superseded(nil)
        } catch let error as TransferExecutionError {
            switch error {
            case .insufficientSpace:
                await wait(&transfer, blocker: .insufficientSpace, error: error)
                return .waiting(.insufficientSpace, error.localizedDescription)
            default:
                await mark(&transfer, status: .failed, message: error.localizedDescription)
                return .attention(nil, error.localizedDescription)
            }
        } catch let error as VolumeInspectorError {
            await wait(&transfer, blocker: .localVolumeUnavailable, error: error)
            return .waiting(.localVolumeUnavailable, error.localizedDescription)
        } catch let error as ObjectStoreError {
            switch error {
            case .authentication, .accessDenied:
                await mark(&transfer, status: .failed, message: error.localizedDescription)
                return .attention(.credentialsUnavailable, error.localizedDescription)
            case .objectUnavailable:
                // One object the provider will not serve. Its checkpoints go
                // now, because the next scan replaces this failed row with a
                // fresh one and would otherwise strand its partial file.
                await discardCheckpoints(for: transfer, job: job, root: root)
                transfer.temporaryPath = nil
                await mark(&transfer, status: .failed, message: error.localizedDescription)
                return .attention(nil, error.localizedDescription)
            case .incompatible:
                await mark(&transfer, status: .failed, message: error.localizedDescription)
                return .attention(.providerIncompatible, error.localizedDescription)
            case .invalidResponse:
                await mark(&transfer, status: .failed, message: error.localizedDescription)
                return .attention(nil, error.localizedDescription)
            case .notFound where transfer.kind == .download:
                await discardCheckpoints(for: transfer, job: job, root: root)
                await mark(&transfer, status: .superseded, message: "The remote object no longer exists.")
                return .superseded(nil)
            case .objectChanged:
                // The object is not the version this transfer was planned
                // against: a write condition failed because something else now
                // sits at the key, or a ranged read ran past the end of an
                // object that has shrunk. Re-planning from a fresh listing is
                // the answer; failing the file for good is not.
                await abortIfNecessary(transfer)
                await discardCheckpoints(for: transfer, job: job, root: root)
                transfer.multipartUploadID = nil
                transfer.temporaryPath = nil
                let message = transfer.kind == .upload
                    ? "The S3 object changed after this upload was planned."
                    : TransferExecutionError.remoteChanged.localizedDescription
                await mark(&transfer, status: .superseded, message: message)
                return .superseded(nil)
            case .checksumMismatch:
                await discardCheckpoints(for: transfer, job: job, root: root)
                transfer.temporaryPath = nil
                let failures = (transfer.integrityFailureCount ?? 0) + 1
                transfer.integrityFailureCount = failures
                guard failures < Self.maximumIntegrityFailures else {
                    let message = "The downloaded data failed verification \(failures) times in a row, so the checksum recorded for this object is probably wrong. Check the object in S3."
                    await mark(&transfer, status: .failed, message: message)
                    return .attention(nil, message)
                }
                await wait(&transfer, blocker: .networkUnavailable, error: error)
                return .retryingFile("Downloaded data failed integrity verification and will be fetched again.")
            default:
                await wait(&transfer, blocker: .networkUnavailable, error: error)
                return .waiting(.networkUnavailable, error.localizedDescription)
            }
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            await wait(&transfer, blocker: .insufficientSpace, error: error)
            return .waiting(.insufficientSpace, error.localizedDescription)
        } catch let error as CocoaError {
            return await localFailure(&transfer, job: job, root: root, error: error)
        } catch let error as POSIXError where error.code == .ENOSPC {
            await wait(&transfer, blocker: .insufficientSpace, error: error)
            return .waiting(.insufficientSpace, error.localizedDescription)
        } catch let error as POSIXError {
            return await localFailure(&transfer, job: job, root: root, error: error)
        } catch {
            await mark(&transfer, status: .failed, message: error.localizedDescription)
            return .attention(nil, error.localizedDescription)
        }
    }

    /// A file-system error names one path. It means the drive is gone only when
    /// the drive actually is gone, and that is checked rather than assumed.
    ///
    /// Assuming it is what used to happen, and a `.waiting` result stops the
    /// whole job: one unreadable photo, a bad sector, a download whose folder
    /// name is already taken by a file, or a name the destination filesystem
    /// refuses each parked every other transfer behind a "drive unavailable"
    /// message, cancelled whatever was in flight, and did it again at every
    /// retry, forever. Now that file fails on its own and the rest carry on.
    /// Its checkpoints go with it, because the next scan replaces the failed
    /// row with a fresh one — which would otherwise leave a multipart upload
    /// open at the provider and a partial download on the drive.
    private func localFailure(
        _ transfer: inout TransferRecord,
        job: SyncJob,
        root: URL,
        error: Error
    ) async -> TransferExecutionResult {
        let volumeIsPresent: Bool
        do {
            try validateVolume(job: job, root: root)
            volumeIsPresent = true
        } catch {
            volumeIsPresent = false
        }
        guard volumeIsPresent else {
            await wait(&transfer, blocker: .localVolumeUnavailable, error: error)
            return .waiting(.localVolumeUnavailable, error.localizedDescription)
        }
        await abortIfNecessary(transfer)
        await discardCheckpoints(for: transfer, job: job, root: root)
        transfer.multipartUploadID = nil
        transfer.temporaryPath = nil
        await mark(&transfer, status: .failed, message: error.localizedDescription)
        return .attention(nil, error.localizedDescription)
    }

    private func uploadClassifyingMissingSource(
        _ transfer: inout TransferRecord,
        job: SyncJob,
        root: URL,
        progress: @escaping TransferProgressHandler
    ) async throws -> ReconciliationBaseline {
        do {
            return try await upload(&transfer, job: job, root: root, progress: progress)
        } catch TransferExecutionError.shortRead {
            throw TransferExecutionError.sourceChanged
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            try validateVolume(job: job, root: root)
            throw TransferExecutionError.sourceChanged
        } catch let error as POSIXError where error.code == .ENOENT {
            try validateVolume(job: job, root: root)
            throw TransferExecutionError.sourceChanged
        }
    }

    private func upload(
        _ transfer: inout TransferRecord,
        job: SyncJob,
        root: URL,
        progress: @escaping TransferProgressHandler
    ) async throws -> ReconciliationBaseline {
        guard let expected = transfer.sourceFingerprint else { throw TransferExecutionError.invalidTransfer }
        let sourceURL = try SafePath.resolve(transfer.relativePath, beneath: root)
        let before = try scanner.fingerprint(url: sourceURL, relativePath: transfer.relativePath)
        // The plan may have survived an external-volume remount. Validate its
        // durable content identity here; use strict same-mount identity only
        // between this point and the post-transfer fingerprint below.
        guard before.representsSameContent(as: expected) else { throw TransferExecutionError.sourceChanged }

        let source = try openSource(transfer.relativePath, root: root)
        let metadata = [
            "storagesync-source-size": String(before.size),
            "storagesync-source-mtime-ns": String(before.modificationTimeNanoseconds),
            "storagesync-transfer-id": transfer.id.description
        ]
        // Old and new folders can contain unrelated files with indistinguishable
        // size and timestamps. Never finish the old folder's parts with the new one's bytes.
        if transfer.multipartUploadID != nil, transfer.multipartGeneration != job.multipartGeneration {
            throw TransferExecutionError.sourceIdentityChanged
        }
        let condition = try Self.writePrecondition(for: transfer)
        let remote: RemoteObject
        if before.size < transferPolicy.multipartThreshold {
            let data = try read(source: source, offset: 0, length: before.size)
            guard data.count == before.size else {
                throw TransferExecutionError.sourceChanged
            }
            let checksum = sha256(data)
            if let identical = try await remoteObjectHoldingSource(
                transfer,
                source: source,
                size: before.size,
                loadedData: data
            ) {
                return try alreadyPresentBaseline(transfer, sourceURL: sourceURL, before: before, remote: identical)
            }
            let liveProgress = LiveUploadProgressReporter(
                repository: repository,
                transfer: transfer,
                acknowledgedBytes: transfer.completedBytes
            )
            remote = try await objectStore.put(
                key: transfer.remoteKey,
                data: data,
                metadata: metadata.merging(["storagesync-sha256": checksum]) { _, new in new },
                precondition: condition,
                progress: { bytesSent in
                    await liveProgress.report(
                        requestID: 0,
                        bytesSent: bytesSent,
                        requestByteCount: before.size
                    )
                }
            )
            transfer.completedBytes = before.size
            await progress(transfer.completedBytes)
            let after = try scanner.fingerprint(url: sourceURL, relativePath: transfer.relativePath)
            do {
                try validateSourceAfterUpload(after, against: before)
            } catch {
                await recordUnverifiedOwnUpload(
                    transfer,
                    job: job,
                    uploadedFrom: before,
                    remote: remote,
                    remoteChecksum: remote.checksum ?? checksum
                )
                throw error
            }
            var verified = after
            verified.checksum = checksum
            guard remote.size == before.size else {
                throw TransferExecutionError.unexpectedObjectSize(expected: before.size, actual: remote.size)
            }
            return ReconciliationBaseline(
                relativePath: transfer.relativePath,
                localFingerprint: verified,
                remoteETag: remote.eTag,
                remoteChecksum: remote.checksum ?? checksum,
                remoteSize: remote.size,
                remoteLastModified: remote.lastModified
            )
        }

        let plannedParts = try transferPolicy.parts(forFileSize: before.size, transferID: transfer.id)
        var uploadID: String
        if let existing = transfer.multipartUploadID {
            uploadID = existing
            if let alreadyCompleted = try await headTreatingDenialAsAbsent(key: transfer.remoteKey),
               alreadyCompleted.size == before.size,
               alreadyCompleted.metadata["storagesync-transfer-id"] == transfer.id.description {
                let after = try scanner.fingerprint(url: sourceURL, relativePath: transfer.relativePath)
                do {
                    try validateSourceAfterUpload(after, against: before)
                } catch {
                    await recordUnverifiedOwnUpload(
                        transfer,
                        job: job,
                        uploadedFrom: before,
                        remote: alreadyCompleted,
                        remoteChecksum: alreadyCompleted.checksum
                    )
                    throw error
                }
                return ReconciliationBaseline(
                    relativePath: transfer.relativePath,
                    localFingerprint: after,
                    remoteETag: alreadyCompleted.eTag,
                    remoteChecksum: alreadyCompleted.checksum,
                    remoteSize: alreadyCompleted.size,
                    remoteLastModified: alreadyCompleted.lastModified
                )
            }
        } else {
            if let identical = try await remoteObjectHoldingSource(
                transfer,
                source: source,
                size: before.size,
                loadedData: nil
            ) {
                return try alreadyPresentBaseline(transfer, sourceURL: sourceURL, before: before, remote: identical)
            }
            uploadID = try await objectStore.createMultipartUpload(key: transfer.remoteKey, metadata: metadata)
            transfer.multipartUploadID = uploadID
            transfer.multipartGeneration = job.multipartGeneration
            transfer.updatedAt = Date()
            try await repository.saveTransfer(transfer)
        }

        let serverParts: [UploadedPart]
        do {
            serverParts = try await objectStore.listParts(key: transfer.remoteKey, uploadID: uploadID)
        } catch ObjectStoreError.notFound {
            // Providers may expire incomplete multipart uploads during a long
            // outage. Start a fresh upload while retaining the logical transfer.
            uploadID = try await objectStore.createMultipartUpload(key: transfer.remoteKey, metadata: metadata)
            transfer.multipartUploadID = uploadID
            transfer.multipartGeneration = job.multipartGeneration
            transfer.completedBytes = 0
            transfer.updatedAt = Date()
            try await repository.removeParts(transferID: transfer.id, fromPartNumber: 1)
            try await repository.saveTransfer(transfer)
            serverParts = []
        }
        let plannedByNumber = Dictionary(uniqueKeysWithValues: plannedParts.map { ($0.number, $0) })
        // `serverParts` is whatever the provider listed, so it may repeat a part
        // number; a unique-keys initializer would trap on that and take the
        // process down on every later resume. The last entry wins, matching the
        // order the S3 store accumulates overlapping listing pages in.
        var completed: [Int: UploadedPart] = Dictionary(
            serverParts.compactMap { serverPart -> (Int, UploadedPart)? in
                guard let planned = plannedByNumber[serverPart.number],
                      serverPart.size == nil || serverPart.size == planned.length else { return nil }
                return (serverPart.number, serverPart)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        transfer.completedBytes = 0
        for part in plannedParts {
            if let serverPart = completed[part.number] {
                var checkpoint = part
                checkpoint.eTag = serverPart.eTag
                checkpoint.checksum = serverPart.checksum ?? ""
                checkpoint.isComplete = true
                try await repository.savePart(checkpoint)
                transfer.completedBytes += part.length
            }
        }
        transfer.updatedAt = Date()
        try await repository.saveTransfer(transfer)
        await progress(transfer.completedBytes)

        let missingParts = plannedParts.filter { completed[$0.number] == nil }
        let liveProgress = LiveUploadProgressReporter(
            repository: repository,
            transfer: transfer,
            acknowledgedBytes: transfer.completedBytes
        )
        let maximumParallelParts = boundedPartConcurrency(for: plannedParts)
        let multipartRemoteKey = transfer.remoteKey
        let currentUploadID = uploadID
        try await withThrowingTaskGroup(of: UploadedPartCheckpoint.self) { group in
            var nextIndex = 0
            let initialCount = min(maximumParallelParts, missingParts.count)
            for _ in 0..<initialCount {
                let part = missingParts[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    let data: Data
                    do {
                        data = try read(source: source, offset: part.offset, length: part.length)
                    } catch TransferExecutionError.shortRead {
                        throw TransferExecutionError.sourceChanged
                    }
                    let checksum = sha256(data)
                    let uploaded = try await objectStore.uploadPart(
                        key: multipartRemoteKey,
                        uploadID: currentUploadID,
                        partNumber: part.number,
                        data: data,
                        progress: { bytesSent in
                            await liveProgress.report(
                                requestID: part.number,
                                bytesSent: bytesSent,
                                requestByteCount: part.length
                            )
                        }
                    )
                    try Task.checkCancellation()
                    return UploadedPartCheckpoint(part: part, uploaded: uploaded, checksum: checksum)
                }
            }

            while let result = try await group.next() {
                completed[result.part.number] = result.uploaded
                await liveProgress.acknowledge(
                    requestID: result.part.number,
                    byteCount: result.part.length
                )
                var checkpoint = result.part
                checkpoint.eTag = result.uploaded.eTag
                checkpoint.checksum = result.checksum
                checkpoint.isComplete = true
                try await repository.savePart(checkpoint)
                transfer.completedBytes += result.part.length
                transfer.updatedAt = Date()
                try await repository.saveTransfer(transfer)
                await progress(transfer.completedBytes)

                if nextIndex < missingParts.count {
                    let part = missingParts[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let data: Data
                        do {
                            data = try read(source: source, offset: part.offset, length: part.length)
                        } catch TransferExecutionError.shortRead {
                            throw TransferExecutionError.sourceChanged
                        }
                        let checksum = sha256(data)
                        let uploaded = try await objectStore.uploadPart(
                            key: multipartRemoteKey,
                            uploadID: currentUploadID,
                            partNumber: part.number,
                            data: data,
                            progress: { bytesSent in
                                await liveProgress.report(
                                    requestID: part.number,
                                    bytesSent: bytesSent,
                                    requestByteCount: part.length
                                )
                            }
                        )
                        try Task.checkCancellation()
                        return UploadedPartCheckpoint(part: part, uploaded: uploaded, checksum: checksum)
                    }
                }
            }
        }

        try Task.checkCancellation()
        let after = try scanner.fingerprint(url: sourceURL, relativePath: transfer.relativePath)
        try validateSourceAfterUpload(after, against: before)
        let orderedCompleted = try plannedParts.map { part -> UploadedPart in
            guard let uploaded = completed[part.number] else { throw TransferExecutionError.invalidTransfer }
            return uploaded
        }
        remote = try await objectStore.completeMultipartUpload(
            key: transfer.remoteKey,
            uploadID: uploadID,
            parts: orderedCompleted,
            precondition: condition
        )
        guard remote.size == before.size else {
            throw TransferExecutionError.unexpectedObjectSize(expected: before.size, actual: remote.size)
        }
        guard remote.metadata["storagesync-transfer-id"] == transfer.id.description else {
            throw ObjectStoreError.invalidResponse(
                "S3 did not expose the metadata needed to verify the completed multipart upload."
            )
        }
        return ReconciliationBaseline(
            relativePath: transfer.relativePath,
            localFingerprint: after,
            remoteETag: remote.eTag,
            remoteChecksum: remote.checksum,
            remoteSize: remote.size,
            remoteLastModified: remote.lastModified
        )
    }

    /// What the destination must still look like when this upload lands: as it
    /// was listed when the upload was planned, or absent if it was absent.
    static func writePrecondition(for transfer: TransferRecord) throws -> WritePrecondition {
        guard let planned = transfer.remoteSource else { return .absent }
        guard planned.key.utf8.elementsEqual(transfer.remoteKey.utf8),
              let eTag = RemoteObject.comparableETag(planned.eTag) else {
            throw ObjectStoreError.invalidResponse("The listed object has no strong ETag for a safe replacement.")
        }
        return .matching(eTag: eTag)
    }

    /// HEAD for a key that may not exist yet. With `s3:ListBucket` granted only
    /// for a prefix, as the least-privilege policy in the runbook does, S3
    /// answers 403 rather than 404 for a missing key — which, read as bad keys,
    /// parked the whole sync every time a large upload resumed.
    private func headTreatingDenialAsAbsent(key: String) async throws -> RemoteObject? {
        do {
            return try await objectStore.head(key: key)
        } catch ObjectStoreError.accessDenied {
            return nil
        }
    }

    /// The object already at the key, if it provably holds exactly the source's
    /// bytes.
    ///
    /// A source whose size is unchanged but whose timestamp moved — `touch`, a
    /// photo app that rewrites dates, or a FAT-family drive whose local-time
    /// stamps shift an hour at daylight saving — looks changed by size and
    /// time alone, and was uploaded again in full; for a whole library that is
    /// days of uploading for nothing. Where the ETag is an MD5 digest (a
    /// single-request upload, or a multipart one whose part layout this
    /// policy reproduces) the bytes can be compared without sending them. Any
    /// other ETag simply fails to match, and the upload goes ahead.
    private func remoteObjectHoldingSource(
        _ transfer: TransferRecord,
        source: FileHandle,
        size: Int64,
        loadedData: Data?
    ) async throws -> RemoteObject? {
        guard verifiesETagDigests, let planned = transfer.remoteSource,
              planned.key.utf8.elementsEqual(transfer.remoteKey.utf8),
              planned.size == size,
              let expected = Self.md5ETag(planned.eTag) else { return nil }
        guard let current = try await headTreatingDenialAsAbsent(key: transfer.remoteKey),
              current.size == size,
              current.serverSideEncryption.map({ $0.lowercased() == "aes256" }) ?? true,
              RemoteObject.comparableETag(current.eTag) == RemoteObject.comparableETag(planned.eTag) else {
            return nil
        }
        let local: String?
        if let partCount = expected.partCount {
            local = try multipartETag(handle: source, size: size, partCount: partCount)
        } else if let loadedData {
            local = Insecure.MD5.hash(data: loadedData).hexadecimalString
        } else {
            local = try md5(handle: source)
        }
        return local == expected.digest ? current : nil
    }

    private func alreadyPresentBaseline(
        _ transfer: TransferRecord,
        sourceURL: URL,
        before: FileFingerprint,
        remote: RemoteObject
    ) throws -> ReconciliationBaseline {
        let after = try scanner.fingerprint(url: sourceURL, relativePath: transfer.relativePath)
        try validateSourceAfterUpload(after, against: before)
        return ReconciliationBaseline(
            relativePath: transfer.relativePath,
            localFingerprint: after,
            remoteETag: remote.eTag,
            remoteChecksum: remote.checksum,
            remoteSize: remote.size,
            remoteLastModified: remote.lastModified
        )
    }

    /// An ETag that is an MD5 digest: 32 hex digits, or for a multipart object
    /// the digest of its parts' digests followed by `-` and the part count.
    static func md5ETag(_ eTag: String?) -> (digest: String, partCount: Int?)? {
        guard let value = RemoteObject.comparableETag(eTag) else { return nil }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let digest = pieces.first, digest.count == 32,
              digest.allSatisfy(\.isHexDigit) else { return nil }
        switch pieces.count {
        case 1:
            return (digest.lowercased(), nil)
        case 2:
            guard let count = Int(pieces[1]), count > 0 else { return nil }
            return (value.lowercased(), count)
        default:
            return nil
        }
    }

    /// The MD5 a finished download can be held to: a single-part ETag on an
    /// object S3 encrypted with its own keys or not at all. With KMS or
    /// customer keys the ETag is not a digest of the bytes.
    static func singlePartMD5(of object: RemoteObject) -> String? {
        if let encryption = object.serverSideEncryption?.lowercased(), encryption != "aes256" {
            return nil
        }
        guard let parsed = md5ETag(object.eTag), parsed.partCount == nil else { return nil }
        return parsed.digest
    }

    private func md5(handle: FileHandle) throws -> String {
        try handle.seek(toOffset: 0)
        var hasher = Insecure.MD5()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().hexadecimalString
    }

    /// The ETag S3 gives a multipart upload of this file cut the way this
    /// policy cuts it, or nil when that layout has a different part count from
    /// the object's — in which case it was cut some other way and cannot be
    /// compared.
    private func multipartETag(handle: FileHandle, size: Int64, partCount: Int) throws -> String? {
        let parts = try transferPolicy.parts(forFileSize: size, transferID: TransferID())
        guard parts.count == partCount else { return nil }
        var combined = Data()
        for part in parts {
            try handle.seek(toOffset: UInt64(part.offset))
            var hasher = Insecure.MD5()
            var remaining = part.length
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: Int(min(remaining, 4 * 1_024 * 1_024))) ?? Data()
                guard !chunk.isEmpty else { return nil }
                hasher.update(data: chunk)
                remaining -= Int64(chunk.count)
            }
            combined.append(contentsOf: hasher.finalize())
        }
        return Insecure.MD5.hash(data: combined).hexadecimalString + "-\(partCount)"
    }

    /// The object now at this key was written by this transfer, but the source
    /// moved on before the copy could be verified, so the transfer is about to
    /// be superseded rather than finalized.
    ///
    /// Without a record of that, the next scan would meet the object as a
    /// stranger: a first pairing whose sizes usually differ, which is left
    /// alone as a conflict, so the new version of the source would never be
    /// sent. Recording the pre-upload fingerprint as the baseline makes that
    /// scan see what actually happened — the source changed since its last
    /// copy — and send the new version over StorageSync's own object.
    private func recordUnverifiedOwnUpload(
        _ transfer: TransferRecord,
        job: SyncJob,
        uploadedFrom source: FileFingerprint,
        remote: RemoteObject,
        remoteChecksum: String?
    ) async {
        try? await repository.saveBaseline(
            ReconciliationBaseline(
                relativePath: transfer.relativePath,
                localFingerprint: source,
                remoteETag: remote.eTag,
                remoteChecksum: remoteChecksum,
                remoteSize: remote.size,
                remoteLastModified: remote.lastModified
            ),
            jobID: job.id
        )
    }

    /// Preserve the existing conservative transfer behavior while separating
    /// reliable content metadata from an opaque identity-only mismatch. Both
    /// restart safely; only the first is honest enough to show to the user.
    private func validateSourceAfterUpload(
        _ after: FileFingerprint,
        against before: FileFingerprint
    ) throws {
        guard after.representsSameContent(as: before) else {
            throw TransferExecutionError.sourceChanged
        }
        guard after.representsSameFileState(as: before) else {
            throw TransferExecutionError.sourceIdentityChanged
        }
    }

    private func download(
        _ transfer: inout TransferRecord,
        job: SyncJob,
        root: URL,
        progress: @escaping TransferProgressHandler
    ) async throws -> ReconciliationBaseline {
        guard let plannedRemote = transfer.remoteSource else { throw TransferExecutionError.invalidTransfer }
        // A provider that reports a negative object size is rejected at the
        // listing boundary, so reaching here means a queue row written before
        // that check or a store that never went through it. Fail this one file
        // rather than plan parts, preflight space, and truncate against a byte
        // count that has no unsigned equivalent.
        guard transfer.totalBytes >= 0 else {
            throw TransferExecutionError.invalidRemoteSize(transfer.totalBytes)
        }
        guard let currentRemote = try await objectStore.head(key: transfer.remoteKey) else {
            throw ObjectStoreError.notFound
        }
        guard try sameRemoteObject(plannedRemote, currentRemote) else { throw TransferExecutionError.remoteChanged }

        let initialDestination = try SafePath.resolve(transfer.relativePath, beneath: root)
        let destinationFingerprintAtStart: FileFingerprint?
        let destinationExistedAtStart = FileManager.default.fileExists(atPath: initialDestination.path)
        if let plannedLocal = transfer.sourceFingerprint {
            guard destinationExistedAtStart else { throw TransferExecutionError.destinationChanged }
            let currentLocal = try scanner.fingerprint(
                url: initialDestination,
                relativePath: transfer.relativePath
            )
            guard currentLocal.representsSameContent(as: plannedLocal) else {
                throw TransferExecutionError.destinationChanged
            }
            destinationFingerprintAtStart = currentLocal
        } else {
            if destinationExistedAtStart {
                // Directories and special files never appear in the file manifest.
                // Replanning them as newly appeared files would loop forever.
                _ = try scanner.fingerprint(url: initialDestination, relativePath: transfer.relativePath)
                throw TransferExecutionError.destinationChanged
            }
            destinationFingerprintAtStart = nil
        }

        let partial = try DownloadPartial(root: root, transferID: transfer.id)
        let partialURL = root.appendingPathComponent(ReservedName.partialsDirectory).appendingPathComponent(partial.name)
        let existingPartialSize = partial.sizeAtOpen
        let remainingBytes = max(0, transfer.totalBytes - existingPartialSize)
        let capacity = try volumeInspector.capacity(for: root)
        if let maximumFileSize = capacity.maximumFileSize, maximumFileSize > 0, transfer.totalBytes > maximumFileSize {
            throw TransferExecutionError.fileTooLarge(size: transfer.totalBytes, maximum: maximumFileSize)
        }
        // Foundation reports zero when this capacity key is unavailable on some
        // filesystems, so only positive values are reliable for preflight.
        if let availableBytes = capacity.availableBytes, availableBytes > 0, remainingBytes > availableBytes {
            throw TransferExecutionError.insufficientSpace(required: remainingBytes, available: availableBytes)
        }
        transfer.temporaryPath = partialURL.path

        let plannedParts = try transferPolicy.parts(forFileSize: transfer.totalBytes, transferID: transfer.id)
        if plannedParts.count > 1, RemoteObject.comparableETag(currentRemote.eTag) == nil, currentRemote.checksum == nil {
            throw ObjectStoreError.invalidResponse("A multi-range download requires a strong ETag or a whole-file checksum.")
        }
        var savedParts = Dictionary(uniqueKeysWithValues: try await repository.parts(transferID: transfer.id).map { ($0.number, $0) })
        let handle = partial.file
        defer { try? handle.close() }

        let planByNumber = Dictionary(uniqueKeysWithValues: plannedParts.map { ($0.number, $0) })
        var invalidSavedPartNumbers: [Int] = []
        // Parallel range responses can be checkpointed out of order. Validate
        // every completed range independently instead of assuming a contiguous
        // prefix; a missing or corrupt early part must not discard a valid
        // later checkpoint.
        for (number, saved) in savedParts {
            guard let planned = planByNumber[number],
                  saved.isComplete,
                  saved.offset == planned.offset,
                  saved.length == planned.length,
                  existingPartialSize >= saved.offset + saved.length else {
                invalidSavedPartNumbers.append(number)
                continue
            }
            let data: Data
            do {
                data = try read(handle: handle, offset: saved.offset, length: saved.length)
            } catch TransferExecutionError.shortRead {
                invalidSavedPartNumbers.append(number)
                continue
            }
            if sha256(data) != saved.checksum {
                invalidSavedPartNumbers.append(number)
            }
        }
        for number in invalidSavedPartNumbers.sorted() {
            try await repository.removePart(transferID: transfer.id, number: number)
            savedParts.removeValue(forKey: number)
        }

        transfer.completedBytes = savedParts.values
            .filter(\.isComplete)
            .reduce(0) { $0 + $1.length }
        transfer.updatedAt = Date()
        try await repository.saveTransfer(transfer)
        await progress(transfer.completedBytes)

        let missingParts = plannedParts.filter { savedParts[$0.number]?.isComplete != true }
        let maximumParallelParts = boundedPartConcurrency(for: plannedParts)
        let downloadRemoteKey = transfer.remoteKey
        try await withThrowingTaskGroup(of: DownloadedPartCheckpoint.self) { group in
            var nextIndex = 0
            let initialCount = min(maximumParallelParts, missingParts.count)
            for _ in 0..<initialCount {
                let part = missingParts[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    let data = try await fetchRange(
                        key: downloadRemoteKey,
                        matchingETag: currentRemote.eTag,
                        range: part.offset..<(part.offset + part.length)
                    )
                    // A complete response shorter than the range asked for is
                    // an object shorter than the one this download planned:
                    // the object changed, which re-planning fixes and failing
                    // the file for good does not.
                    guard data.count == part.length else {
                        throw TransferExecutionError.remoteChanged
                    }
                    try Task.checkCancellation()
                    return DownloadedPartCheckpoint(part: part, data: data, checksum: sha256(data))
                }
            }

            while let result = try await group.next() {
                try validateVolume(job: job, root: root)
                try handle.seek(toOffset: UInt64(result.part.offset))
                try handle.write(contentsOf: result.data)
                try handle.synchronize()
                var checkpoint = result.part
                checkpoint.checksum = result.checksum
                checkpoint.isComplete = true
                try await repository.savePart(checkpoint)
                savedParts[result.part.number] = checkpoint
                transfer.completedBytes += result.part.length
                transfer.updatedAt = Date()
                try await repository.saveTransfer(transfer)
                await progress(transfer.completedBytes)

                if nextIndex < missingParts.count {
                    let part = missingParts[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let data = try await fetchRange(
                            key: downloadRemoteKey,
                            matchingETag: currentRemote.eTag,
                            range: part.offset..<(part.offset + part.length)
                        )
                        guard data.count == part.length else {
                            throw TransferExecutionError.remoteChanged
                        }
                        try Task.checkCancellation()
                        return DownloadedPartCheckpoint(part: part, data: data, checksum: sha256(data))
                    }
                }
            }
        }
        // Clamped rather than converted directly: the guard above already
        // excludes a negative total, and this conversion traps rather than
        // throws if it ever stops doing so.
        try handle.truncate(atOffset: UInt64(max(0, transfer.totalBytes)))
        try handle.synchronize()
        try Task.checkCancellation()

        guard let afterRemote = try await objectStore.head(key: transfer.remoteKey),
              try sameRemoteObject(plannedRemote, afterRemote),
              try sameRemoteObject(currentRemote, afterRemote) else {
            throw TransferExecutionError.remoteChanged
        }
        let expectedMD5 = verifiesETagDigests ? Self.singlePartMD5(of: afterRemote) : nil
        let digests = try scanner.digests(handle: handle, includingMD5: expectedMD5 != nil)
        let wholeChecksum = digests.sha256
        if [currentRemote.checksum, afterRemote.checksum].compactMap({ $0 }).contains(where: { $0 != wholeChecksum }) {
            throw ObjectStoreError.checksumMismatch
        }
        // Objects StorageSync did not upload carry no checksum of their own,
        // so before this the bytes were never compared with anything S3 said.
        if let expectedMD5, digests.md5 != expectedMD5 {
            throw ObjectStoreError.checksumMismatch
        }

        if let nanoseconds = afterRemote.metadata["storagesync-source-mtime-ns"].flatMap(Int64.init) {
            var seconds = nanoseconds / 1_000_000_000
            var nanos = nanoseconds % 1_000_000_000
            if nanos < 0 { seconds -= 1; nanos += 1_000_000_000 }
            let stamp = timespec(tv_sec: Int(seconds), tv_nsec: Int(nanos))
            guard futimens(handle.fileDescriptor, [stamp, stamp]) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        transfer.verifiedDownloadChecksum = wholeChecksum
        try await repository.saveTransfer(transfer)
        let destination = try SafePath.resolve(transfer.relativePath, beneath: root)
        try validateVolume(job: job, root: root)
        try Task.checkCancellation()
        if let destinationFingerprintAtStart {
            // Coordinate with document presenters and other StorageSync jobs through
            // the final check and rename. The absent-path case uses an exclusive rename.
            var coordinationError: NSError?
            var publicationError: Error?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                do {
                    guard coordinatedURL.standardizedFileURL == destination.standardizedFileURL,
                          FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                        throw TransferExecutionError.destinationChanged
                    }
                    let current = try scanner.fingerprint(url: coordinatedURL, relativePath: destinationFingerprintAtStart.relativePath)
                    guard current.representsSameFileState(as: destinationFingerprintAtStart) else {
                        throw TransferExecutionError.destinationChanged
                    }
                    try partial.publish(relativePath: transfer.relativePath, root: root, replacing: true)
                } catch {
                    publicationError = error
                }
            }
            if let error = publicationError ?? coordinationError { throw error }
        } else {
            try partial.publish(relativePath: transfer.relativePath, root: root, replacing: false)
        }
        let local = try scanner.fingerprint(url: destination, relativePath: transfer.relativePath)
        var verified = local
        verified.checksum = wholeChecksum
        return ReconciliationBaseline(
            relativePath: transfer.relativePath,
            localFingerprint: verified,
            remoteETag: afterRemote.eTag,
            remoteChecksum: afterRemote.checksum ?? wholeChecksum,
            remoteSize: afterRemote.size,
            remoteLastModified: afterRemote.lastModified
        )
    }

    /// A process can stop after S3 or the filesystem published a file but before
    /// SQLite committed its first baseline. Attribute only a provable prior copy.
    package func publishedBaseline(for transfer: TransferRecord, local: FileFingerprint,
                                   remote: RemoteObject, root: URL) async throws -> ReconciliationBaseline? {
        guard transfer.remoteKey.utf8.elementsEqual(remote.key.utf8) else { return nil }
        let copiedLocal: FileFingerprint
        let copiedRemote: RemoteObject
        switch transfer.kind {
        case .upload:
            guard transfer.status != .queued, let source = transfer.sourceFingerprint,
                  let current = try await headTreatingDenialAsAbsent(key: remote.key),
                  current.metadata["storagesync-transfer-id"] == transfer.id.description,
                  current.size == source.size else { return nil }
            copiedLocal = source
            copiedRemote = current
        case .download:
            guard let checksum = transfer.verifiedDownloadChecksum, let source = transfer.remoteSource,
                  local.size == source.size else { return nil }
            let url = try SafePath.resolve(transfer.relativePath, beneath: root)
            let handle = try openSource(transfer.relativePath, root: root)
            guard try scanner.digests(handle: handle, includingMD5: false).sha256 == checksum,
                  try scanner.fingerprint(url: url, relativePath: transfer.relativePath)
                    .representsSameFileState(as: local) else { return nil }
            copiedLocal = local
            copiedRemote = source
        }
        return ReconciliationBaseline(
            relativePath: transfer.relativePath, localFingerprint: copiedLocal,
            remoteETag: copiedRemote.eTag, remoteChecksum: copiedRemote.checksum,
            remoteSize: copiedRemote.size, remoteLastModified: copiedRemote.lastModified
        )
    }

    private func validateVolume(job: SyncJob, root: URL) throws {
        if let expected = job.localRoot.expectedVolume {
            _ = try volumeInspector.validate(expected: expected, selectedURL: root)
        } else if !FileManager.default.fileExists(atPath: root.path) {
            throw VolumeInspectorError.notMounted
        }
    }

    /// A ranged read of an object this download has already HEADed.
    ///
    /// HEAD needs the same `s3:GetObject` permission GET does, so a refusal
    /// here is about this object and not about the keys: typically one
    /// encrypted with a KMS key these credentials cannot decrypt. Reported as
    /// access denied it parked the entire sync as a credentials failure at the
    /// first such object. Keys that really stopped working are still caught —
    /// they fail the next file's HEAD, which keeps its job-wide meaning.
    private func fetchRange(key: String, matchingETag: String?, range: Range<Int64>) async throws -> Data {
        do {
            return try await objectStore.getRange(key: key, range: range, matchingETag: matchingETag)
        } catch ObjectStoreError.accessDenied(let message) {
            throw ObjectStoreError.objectUnavailable(
                "S3 lists this object but refused to send it, for example because it is encrypted with a KMS key these credentials cannot use. \(message)"
            )
        }
    }

    private func sameRemoteObject(_ left: RemoteObject, _ right: RemoteObject) throws -> Bool {
        guard left.size == right.size else { return false }
        if let leftChecksum = left.checksum, let rightChecksum = right.checksum {
            return leftChecksum == rightChecksum
        }
        if let leftETag = RemoteObject.comparableETag(left.eTag),
           let rightETag = RemoteObject.comparableETag(right.eTag) {
            return leftETag == rightETag
        }
        if let leftModified = left.lastModified, let rightModified = right.lastModified {
            return leftModified == rightModified
        }
        throw ObjectStoreError.invalidResponse(
            "The S3 provider did not return an ETag, checksum, or modification date needed to verify a stable download."
        )
    }

    private func openSource(_ path: String, root: URL) throws -> FileHandle {
        let directory = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        let descriptor = openat(directory, path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return handle
    }

    private func read(source: FileHandle, offset: Int64, length: Int64) throws -> Data {
        var data = Data(count: Int(length))
        try data.withUnsafeMutableBytes { bytes in
            var count = 0
            while count < bytes.count {
                try Task.checkCancellation()
                let n = pread(source.fileDescriptor, bytes.baseAddress!.advanced(by: count), bytes.count - count, offset + Int64(count))
                if n < 0, errno == EINTR { continue }
                guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard n > 0 else { throw TransferExecutionError.shortRead(expected: length, actual: count) }
                count += n
            }
        }
        return data
    }

    private func read(handle: FileHandle, offset: Int64, length: Int64) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        if length == 0 { return Data() }
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        guard data.count == length else {
            throw TransferExecutionError.shortRead(expected: length, actual: data.count)
        }
        return data
    }

    private func sha256(_ data: Data) -> String {
        data.sha256Hexadecimal
    }

    private func boundedPartConcurrency(for parts: [TransferPart]) -> Int {
        let configured = max(1, transferPolicy.maximumConcurrentPartsPerFile)
        guard let largestPart = parts.map(\.length).max(), largestPart > 0 else { return 1 }
        let perFileMemoryBudget: Int64 = 128 * 1_024 * 1_024
        let memoryBound = max(1, Int(perFileMemoryBudget / largestPart))
        return min(configured, memoryBound)
    }

    /// The blocker is recorded next to the message because it is the same
    /// classification this call's caller returns to the coordinator, and it is
    /// the only form of it that survives to the row a person reads.
    private func wait(_ transfer: inout TransferRecord, blocker: SyncBlocker, error: Error) async {
        transfer.retryCount += 1
        transfer.status = .waiting
        transfer.lastError = error.localizedDescription
        transfer.waitingBlocker = blocker
        transfer.updatedAt = Date()
        let unit = Double.random(in: 0...1)
        if let delay = retryPolicy.delay(forAttempt: transfer.retryCount - 1, randomUnit: unit) {
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            transfer.nextAttemptAt = Date().addingTimeInterval(seconds)
        } else {
            transfer.status = .failed
            transfer.nextAttemptAt = nil
        }
        try? await repository.saveTransfer(transfer)
    }

    private func mark(_ transfer: inout TransferRecord, status: TransferStatus, message: String) async {
        transfer.status = status
        transfer.lastError = message
        transfer.nextAttemptAt = nil
        transfer.updatedAt = Date()
        try? await repository.saveTransfer(transfer)
    }

    private func deferAfterCancellation(_ transfer: inout TransferRecord) async {
        transfer.status = .waiting
        transfer.lastError = nil
        transfer.waitingBlocker = nil
        transfer.nextAttemptAt = nil
        transfer.updatedAt = Date()
        try? await repository.saveTransfer(transfer)
    }

    private func discardCheckpoints(for transfer: TransferRecord, job: SyncJob, root: URL) async {
        try? await repository.removeParts(transferID: transfer.id, fromPartNumber: 1)
        guard transfer.kind == .download, (try? validateVolume(job: job, root: root)) != nil else { return }
        DownloadPartial.remove(transfer.id.description + ".partial", beneath: root)
    }

    private func abortIfNecessary(_ transfer: TransferRecord) async {
        guard let uploadID = transfer.multipartUploadID else { return }
        try? await objectStore.abortMultipartUpload(key: transfer.remoteKey, uploadID: uploadID)
    }
}
