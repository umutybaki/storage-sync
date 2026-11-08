import Foundation
import StorageSyncCore
import StorageSyncPersistence
import StorageSyncSystem

private struct FileTransferAttempt: Sendable {
    var transfer: TransferRecord
    var result: TransferExecutionResult
}

private actor TransferProgressAccumulator {
    private var totals: [TransferID: Int64] = [:]
    private var completed: [TransferID: Int64] = [:]
    private var aggregateCompleted: Int64

    init(initialCompleted: Int64) {
        aggregateCompleted = max(0, initialCompleted)
    }

    func register(_ transfer: TransferRecord) {
        totals[transfer.id] = transfer.totalBytes
        completed[transfer.id] = min(transfer.totalBytes, max(0, transfer.completedBytes))
    }

    func update(transferID: TransferID, completedBytes: Int64) -> Int64 {
        let maximum = totals[transferID] ?? completedBytes
        let previous = completed[transferID] ?? 0
        let value = min(maximum, max(previous, completedBytes))
        completed[transferID] = value
        aggregateCompleted += value - previous
        return aggregateCompleted
    }

    func finish(transferID: TransferID) {
        totals.removeValue(forKey: transferID)
        completed.removeValue(forKey: transferID)
    }

    func totalCompleted() -> Int64 {
        aggregateCompleted
    }
}

private struct ManifestScanResult: Sendable {
    var generation: Int64
    var invalidRemoteKeyCount: Int
    /// Entries this side could not offer for reconciliation because another
    /// entry on the same side folds to the same canonical path.
    var caseCollisionCount: Int
    var entryCount: Int
    /// Summed while scanning. The manifest keeps each entry as an encoded
    /// payload, so there is no column for SQLite to total afterwards.
    var byteCount: Int64
    /// Entries the scan could not read and stepped over. Nonzero means the
    /// manifest is not a complete picture of this side, so absence from it
    /// proves nothing about deletion.
    var skippedEntryCount: Int = 0
}

private enum CycleDisposition: Sendable {
    case normal
    case transientFailure
    case attention
    case paused
}

private struct CycleOutcome: Sendable {
    var direction: SyncDirection
    var disposition: CycleDisposition
    /// Transfers this cycle abandoned because their source or destination
    /// changed underneath them. Each one asks for a rescan, and a file that
    /// never stops changing asks for one every cycle.
    var supersededTransferCount: Int = 0
}

/// Bounds how many files move at once across every sync, not just one.
///
/// That sharing is why the wait below has to be cancellable: a transfer parked
/// here can be behind work belonging to a job the user is not touching at all.
public actor TransferPermitPool {
    private struct Waiter {
        var id: UInt64
        var weight: Int
        var continuation: CheckedContinuation<Bool, Never>
    }

    private let capacity: Int
    private var available: Int
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    public init(limit: Int) {
        capacity = max(1, limit)
        available = max(1, limit)
    }

    public func perform<T: Sendable>(
        weight requestedWeight: Int = 1,
        _ operation: @Sendable () async -> T
    ) async -> T {
        let weight = min(capacity, max(1, requestedWeight))
        let admitted = await acquire(weight: weight)
        let result = await operation()
        // Only a permit that was actually taken is handed back. A cancelled
        // waiter holds nothing, and releasing on its behalf would credit the
        // pool with capacity it never had.
        if admitted { release(weight: weight) }
        return result
    }

    /// Waits for `weight` permits and answers whether it got them.
    ///
    /// A cancelled waiter stops waiting and returns `false`. Its operation
    /// still runs, unadmitted: `TransferExecutor.execute` checks cancellation
    /// before it opens a file or a connection, so an already-cancelled
    /// transfer costs nothing this pool exists to bound. Holding it here costs
    /// a great deal — `prepareForVolumeUnmount` cancels the affected job's
    /// work and awaits it, and Disk Arbitration allows that twenty seconds
    /// before it refuses the eject. A wait that ignored cancellation could
    /// spend all twenty of them behind another job's 128 MiB part.
    ///
    /// Cancellation arriving before the continuation exists has no waiter to
    /// find, so the body answers it directly; in the other order the handler
    /// finds it queued. Every resume path removes the waiter from the queue
    /// first, so no continuation can be resumed twice.
    private func acquire(weight: Int) async -> Bool {
        if waiters.isEmpty, available >= weight {
            available -= weight
            return true
        }
        let id = nextWaiterID
        nextWaiterID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, weight: weight, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
        // Nothing was freed, but the queue is served strictly in order, so
        // dropping one waiter can let those behind it fit what is already
        // available.
        admitEligibleWaiters()
    }

    private func release(weight: Int) {
        available = min(capacity, available + weight)
        admitEligibleWaiters()
    }

    private func admitEligibleWaiters() {
        while let first = waiters.first, first.weight <= available {
            available -= first.weight
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}

public actor SyncCoordinator {
    private let repository: SyncRepository
    private let bookmarks: BookmarkStore
    private let keychain: KeychainStore
    private let objectStoreFactory: any ObjectStoreProviding
    private let scanner: LocalScanner
    private let reconciler: Reconciler
    private let transferPolicy: TransferPolicy
    private let scanRetryPolicy: RetryPolicy
    private let transferPermitPool: TransferPermitPool
    private var jobTasks: [SyncJobID: Task<Void, Never>] = [:]
    private var isStopping = false
    private var activeJobIDs: Set<SyncJobID> = []
    private var pendingWakeJobIDs: Set<SyncJobID> = []
    /// The subset of pending wakes that came from outside the cycle — Sync Now,
    /// a volume or network event, new keys — rather than from a transfer the
    /// cycle itself superseded. Only the cycle's own requests are slowed down.
    private var externalWakeJobIDs: Set<SyncJobID> = []
    private var attentionJobIDs: Set<SyncJobID> = []
    /// What the last scan of each job had to report, kept for the cycles that
    /// run only because a retry came due and so do not scan.
    private var lastScanNotices: [SyncJobID: ScanNotices] = [:]
    /// Each job's folder as its bookmark last resolved it.
    private var resolvedRootPaths: [SyncJobID: String] = [:]
    private var removingJobIDs: Set<SyncJobID> = []
    private var unmountingJobIDs: Set<SyncJobID> = []

    public init(
        repository: SyncRepository,
        bookmarks: BookmarkStore,
        keychain: KeychainStore,
        scanner: LocalScanner = LocalScanner(),
        reconciler: Reconciler = Reconciler(),
        transferPolicy: TransferPolicy = TransferPolicy()
    ) {
        self.init(repository: repository, bookmarks: bookmarks, keychain: keychain, scanner: scanner,
                  reconciler: reconciler, transferPolicy: transferPolicy, objectStoreFactory: ObjectStoreFactory(keychain: keychain))
    }

    package init(repository: SyncRepository, bookmarks: BookmarkStore, keychain: KeychainStore,
                 scanner: LocalScanner = LocalScanner(), reconciler: Reconciler = Reconciler(),
                 transferPolicy: TransferPolicy = TransferPolicy(), objectStoreFactory: any ObjectStoreProviding) {
        self.repository = repository
        self.bookmarks = bookmarks
        self.keychain = keychain
        self.objectStoreFactory = objectStoreFactory
        self.scanner = scanner
        self.reconciler = reconciler
        self.transferPolicy = transferPolicy
        scanRetryPolicy = RetryPolicy(baseDelay: .seconds(2), maximumDelay: .seconds(5 * 60))
        transferPermitPool = TransferPermitPool(limit: transferPolicy.maximumConcurrentFiles)
    }

    public func start() async throws {
        isStopping = false
        await adoptCredentialsFromConnections()
        for job in try await repository.jobs() {
            if job.isPaused {
                try await repository.setSnapshot(
                    SyncSnapshot(jobID: job.id, phase: .paused, message: "Paused")
                )
                continue
            }
            schedule(jobID: job.id, immediate: true)
        }
    }

    /// Cancels every running job and waits for the cancelled work to unwind.
    ///
    /// The waiting is the point. A download can be one statement short of
    /// `savePart` with its 32 MiB already written and synchronized, and an
    /// upload can be between `uploadPart` returning and the checkpoint that
    /// records the part S3 has already acknowledged. Returning before those
    /// finish loses the checkpoint and re-transfers the part on the next run,
    /// which on a multi-day sync is exactly the progress this app promises to
    /// keep. `pause`, `remove` and `prepareForVolumeUnmount` all await their
    /// cancelled tasks for the same reason; only quitting did not.
    ///
    /// The tasks are collected and the dictionary emptied before the first
    /// suspension, so nothing can observe the actor still holding jobs it has
    /// already cancelled.
    public func stop() async {
        isStopping = true
        let runningTasks = Array(jobTasks.values)
        jobTasks.removeAll()
        for task in runningTasks { task.cancel() }
        for task in runningTasks { await task.value }
    }

    public func jobs() async throws -> [SyncJob] {
        try await repository.jobs()
    }

    public func snapshots() async throws -> [SyncSnapshot] {
        try await repository.snapshots()
    }

    public func transferActivityPage(
        _ request: TransferActivityPageRequest
    ) async throws -> TransferActivityPage {
        try await repository.transferActivityPage(request)
    }

    public func connections() async throws -> [S3Connection] {
        try await repository.connections()
    }

    /// Proves keys and bucket work together before anything durable is written.
    ///
    /// The keys are either the ones being typed in — which is the only moment
    /// a secret travels anywhere — or, when none are passed, the saved ones the
    /// connection already names. Listing the prefix is the smallest request
    /// that exercises signing, addressing, and access in one go.
    public func test(
        connection: S3Connection,
        credentials: S3Credentials?,
        remotePrefix: String?
    ) async throws {
        let store = try await objectStoreFactory.make(
            connection: connection,
            credentials: credentials,
            timeout: 30
        )
        let normalizedPrefix = SyncJob.normalizedPrefix(remotePrefix ?? "")
        _ = try await store.list(
            prefix: normalizedPrefix.isEmpty ? "" : normalizedPrefix + "/",
            continuationToken: nil
        )
    }

    /// Connections carry no secret of their own: they name a saved credential
    /// and the engine resolves it at the moment it needs one. Saving a
    /// connection therefore never writes to the Keychain — `saveCredential` is
    /// the only thing that does — but it does insist the credential it points
    /// at is really there, so a sync cannot be pointed at keys that are gone.
    public func save(connection: S3Connection) async throws {
        guard try await keychain.contains(reference: connection.credentialReference) else {
            throw CoordinatorError.missingCredential
        }
        try await repository.saveConnection(connection)
        for job in try await repository.jobs() where job.connectionID == connection.id && !job.isPaused {
            attentionJobIDs.remove(job.id)
            await requestRun(jobID: job.id, allowAttention: true)
        }
    }

    public func credentials() async throws -> [StoredCredential] {
        try await repository.credentials()
    }

    /// Creates a credential, renames one, or replaces the keys inside one.
    ///
    /// This is the only place in StorageSync that writes a secret. Passing no
    /// keys leaves the saved ones untouched, which is how a rename works
    /// without the secret ever being read, let alone sent anywhere.
    @discardableResult
    public func saveCredential(
        id: CredentialID?,
        name: String,
        credentials: S3Credentials?
    ) async throws -> StoredCredential {
        let requestedName = StoredCredential.normalizedName(name)
        guard !requestedName.isEmpty else { throw CoordinatorError.credentialNameMissing }
        let existing = try await repository.credentials()
        guard !existing.contains(where: {
            $0.id != id && $0.name.lowercased() == requestedName.lowercased()
        }) else {
            throw CoordinatorError.credentialNameTaken(requestedName)
        }

        var record: StoredCredential
        if let id {
            guard var stored = try await repository.credential(id: id) else {
                throw CoordinatorError.missingCredential
            }
            stored.name = requestedName
            record = stored
        } else {
            guard credentials != nil else { throw CoordinatorError.credentialKeysMissing }
            record = StoredCredential(name: requestedName)
        }

        if let credentials {
            try await keychain.save(
                credentials,
                reference: record.keychainReference,
                label: Self.keychainLabel(for: requestedName)
            )
            record.accessKeySummary = StoredCredential.summary(forAccessKeyID: credentials.accessKeyID)
            record.hasSessionToken = credentials.sessionToken != nil
            record.keysUpdatedAt = Date()
        } else {
            // Cosmetic, and deliberately not fatal: a rename that could not
            // reach the Keychain still renames the credential in StorageSync.
            try? await keychain.relabel(
                reference: record.keychainReference,
                label: Self.keychainLabel(for: requestedName)
            )
        }

        do {
            try await repository.saveCredential(record)
        } catch {
            // A secret nobody can see is worse than none, so a credential that
            // failed to become a record takes its Keychain item back out.
            if id == nil { try? await keychain.remove(reference: record.keychainReference) }
            throw error
        }

        await wakeJobsUsing(credentialReference: record.keychainReference)
        return record
    }

    /// Refuses while a sync still depends on it. Deleting keys out from under a
    /// running sync would look like an unexplained authentication failure some
    /// time later, so the answer names the syncs instead.
    public func removeCredential(id: CredentialID) async throws {
        guard let credential = try await repository.credential(id: id) else { return }
        let dependents = try await jobsUsing(credentialReference: credential.keychainReference)
        guard dependents.isEmpty else {
            throw CoordinatorError.credentialInUse(dependents.map(\.name))
        }
        // The secret goes first. If the record survived and the item did not,
        // the credential is visibly broken and can be deleted again; the other
        // order would leave a secret with nothing left pointing at it.
        try await keychain.remove(reference: credential.keychainReference)
        try await repository.removeCredential(id: id)
    }

    /// Removing a sync used to delete the Keychain item its connection pointed
    /// at. That is right only while the keys belong to that one sync. A saved
    /// credential is the user's, not the sync's: it can be shared with other
    /// syncs and is meant to outlive them, so it is deleted only from the
    /// Credentials list. What is still cleaned up here is a secret nothing
    /// refers to any more.
    ///
    /// Every uncertain answer counts as "still in use". Leaving an orphaned
    /// item behind is a mess; deleting one that is still referenced is data
    /// loss the user cannot undo.
    private func removeCredentialMaterialIfOrphaned(reference: String) async {
        let ownedByCredential = (try? await repository.credentials())?.contains {
            $0.keychainReference == reference
        } ?? true
        let usedByConnection = (try? await repository.connections())?.contains {
            $0.credentialReference == reference
        } ?? true
        guard !ownedByCredential, !usedByConnection else { return }
        try? await keychain.remove(reference: reference)
    }

    private func jobsUsing(credentialReference: String) async throws -> [SyncJob] {
        let connectionIDs = Set(
            try await repository.connections()
                .filter { $0.credentialReference == credentialReference }
                .map(\.id)
        )
        guard !connectionIDs.isEmpty else { return [] }
        return try await repository.jobs().filter { connectionIDs.contains($0.connectionID) }
    }

    /// New keys are worth acting on immediately: the syncs that were parked on
    /// an authentication failure are exactly the ones the user just fixed.
    private func wakeJobsUsing(credentialReference: String) async {
        guard let dependents = try? await jobsUsing(credentialReference: credentialReference) else { return }
        for job in dependents where !job.isPaused {
            attentionJobIDs.remove(job.id)
            await requestRun(jobID: job.id, allowAttention: true)
        }
    }

    private static func keychainLabel(for name: String) -> String {
        "StorageSync — \(name)"
    }

    /// Brings keys saved before the credential store existed into it.
    ///
    /// The Keychain reference is adopted exactly as it was written, so every
    /// existing sync keeps resolving the same item and no secret is moved,
    /// rewritten, or copied. Reading it at all is only to fill in the masked
    /// access key for display, and failing that read is not a reason to skip
    /// the adoption.
    private func adoptCredentialsFromConnections() async {
        guard let connections = try? await repository.connections(),
              var known = try? await repository.credentials() else { return }
        let jobs = (try? await repository.jobs()) ?? []
        var references = Set(known.map(\.keychainReference))

        for connection in connections where !references.contains(connection.credentialReference) {
            // A connection whose keys are already gone is not a credential
            // worth listing. Its sync reports that it needs new ones, and
            // supplying them creates the credential properly.
            guard (try? await keychain.contains(reference: connection.credentialReference)) == true else { continue }

            let users = jobs.filter { $0.connectionID == connection.id }
            var record = StoredCredential(
                name: StoredCredential.uniqueName(
                    Self.adoptedName(for: connection),
                    avoiding: known.map(\.name)
                ),
                keychainReference: connection.credentialReference,
                createdAt: users.map(\.createdAt).min() ?? Date(),
                keysUpdatedAt: users.map(\.createdAt).min() ?? Date()
            )
            if let secret = try? await keychain.load(reference: connection.credentialReference) {
                record.accessKeySummary = StoredCredential.summary(forAccessKeyID: secret.accessKeyID)
                record.hasSessionToken = secret.sessionToken != nil
            }
            do {
                try await repository.saveCredential(record)
            } catch {
                continue
            }
            known.append(record)
            references.insert(record.keychainReference)
        }
    }

    /// Enough to tell two adopted credentials apart at a glance. The user can
    /// rename it to whatever they actually call the account.
    private static func adoptedName(for connection: S3Connection) -> String {
        connection.bucket.isEmpty ? connection.name : "\(connection.name) (\(connection.bucket))"
    }

    public func save(job: SyncJob) async throws {
        precondition(job.deletionPolicy == .preserveDestination)
        try await repository.saveJob(job)
        attentionJobIDs.remove(job.id)
        schedule(jobID: job.id, immediate: true)
    }

    public func pause(jobID: SyncJobID) async throws {
        guard var job = try await repository.job(id: jobID), !removingJobIDs.contains(jobID) else { return }
        job.isPaused = true
        try await repository.saveJob(job)
        clearPendingWake(jobID)
        // The task stays in `jobTasks` for as long as it takes to unwind.
        // `remove` and `prepareForVolumeUnmount` set a flag that keeps
        // `schedule` from starting anything while they wait; pausing sets
        // none, so a Resume arriving during this await is precisely what
        // `schedule` has to find and wait for. Whoever installed a
        // replacement owns the entry, so it is cleared only while still ours.
        let task = jobTasks[jobID]
        task?.cancel()
        await task?.value
        guard try await repository.job(id: jobID)?.isPaused == true, jobTasks[jobID] == task else { return }
        jobTasks.removeValue(forKey: jobID)
        try await repository.setSnapshot(
            SyncSnapshot(jobID: jobID, phase: .paused, message: "Paused")
        )
    }

    public func resume(jobID: SyncJobID) async throws {
        guard var job = try await repository.job(id: jobID), !removingJobIDs.contains(jobID) else { return }
        job.isPaused = false
        try await repository.saveJob(job)
        try await repository.makeWaitingTransfersRunnable(jobID: jobID)
        clearPendingWake(jobID)
        attentionJobIDs.remove(jobID)
        schedule(jobID: jobID, immediate: true)
    }

    /// Removes StorageSync's configuration and resumable state for a job. This
    /// operation deliberately never removes a completed local file or S3
    /// object. Only exact job-owned download partials and incomplete multipart
    /// uploads are cleaned up on a best-effort basis.
    public func remove(jobID: SyncJobID) async throws {
        guard let job = try await repository.job(id: jobID),
              !removingJobIDs.contains(jobID) else { return }

        removingJobIDs.insert(jobID)
        clearPendingWake(jobID)
        attentionJobIDs.remove(jobID)

        let jobTask = jobTasks.removeValue(forKey: jobID)
        jobTask?.cancel()
        await jobTask?.value
        activeJobIDs.remove(jobID)

        let transfers = (try? await repository.transfersWithArtifacts(jobID: jobID)) ?? []
        let partialIDs = transfers.filter { $0.kind == .download }.map(\.id)
        let connection = try? await repository.connection(id: job.connectionID)
        let scopedRoot = try? await bookmarks.resolve(reference: job.localRoot.bookmarkReference)
        let store: (any ObjectStore)?
        if let connection {
            store = try? await objectStoreFactory.make(connection: connection)
        } else {
            store = nil
        }

        do {
            try await repository.removeJobState(id: jobID)
        } catch {
            removingJobIDs.remove(jobID)
            if !job.isPaused {
                schedule(jobID: jobID, immediate: true)
            }
            throw error
        }
        removingJobIDs.remove(jobID)
        lastScanNotices.removeValue(forKey: jobID)
        resolvedRootPaths.removeValue(forKey: jobID)

        // These cleanup operations cannot make removal fail after the durable
        // job row is gone. At worst, a harmless bookmark, credential, partial,
        // or provider-side multipart upload remains orphaned.
        try? await bookmarks.remove(reference: job.localRoot.bookmarkReference)
        if let scopedRoot {
            // The security-scoped access has to outlive the deletions, not just
            // the read of its URL, or the sandbox can revoke it mid-cleanup.
            withExtendedLifetime(scopedRoot) {
                if let expected = job.localRoot.expectedVolume,
                   (try? VolumeInspector().validate(expected: expected, selectedURL: scopedRoot.url)) == nil { return }
                Self.removeDownloadPartials(named: partialIDs, beneath: scopedRoot.url)
            }
        }

        let connectionStillUsed = (try? await repository.jobs())?.contains {
            $0.connectionID == job.connectionID
        } ?? true
        if !connectionStillUsed, let connection {
            try? await repository.removeConnection(id: connection.id)
            await removeCredentialMaterialIfOrphaned(reference: connection.credentialReference)
        }

        if let store {
            let multipartUploads = transfers.compactMap { transfer -> (String, String)? in
                guard let uploadID = transfer.multipartUploadID else { return nil }
                return (transfer.remoteKey, uploadID)
            }
            Task.detached(priority: .utility) {
                for (key, uploadID) in multipartUploads {
                    try? await store.abortMultipartUpload(key: key, uploadID: uploadID)
                }
            }
        }
    }

    public func syncNow(jobID: SyncJobID) async throws {
        guard let job = try await repository.job(id: jobID),
              !job.isPaused,
              !removingJobIDs.contains(jobID),
              !unmountingJobIDs.contains(jobID) else { return }

        try await repository.makeWaitingTransfersRunnable(jobID: jobID)
        attentionJobIDs.remove(jobID)

        await requestRun(jobID: jobID, allowAttention: true)
    }

    public func wakeAll() async throws {
        for job in try await repository.jobs()
        where !job.isPaused
            && !attentionJobIDs.contains(job.id)
            && !unmountingJobIDs.contains(job.id) {
            try await repository.makeWaitingTransfersRunnable(jobID: job.id)
            await requestRun(jobID: job.id)
        }
    }

    /// Called from Disk Arbitration's approval callback. All affected work is
    /// cancelled and awaited so FileHandle defers have run and durable part
    /// checkpoints are closed before the callback approves a normal unmount.
    public func prepareForVolumeUnmount(at volumeURL: URL) async -> Bool {
        let affectedJobs: [SyncJob]
        do {
            affectedJobs = try await jobs(onVolumeAt: volumeURL)
        } catch {
            return false
        }
        guard !affectedJobs.isEmpty else { return true }

        unmountingJobIDs.formUnion(affectedJobs.map(\.id))
        var runningTasks: [SyncJobID: Task<Void, Never>] = [:]
        for job in affectedJobs {
            clearPendingWake(job.id)
            if let task = jobTasks[job.id] {
                task.cancel()
                runningTasks[job.id] = task
            }
        }
        for (id, task) in runningTasks {
            await task.value
            if jobTasks[id] == task { jobTasks.removeValue(forKey: id) }
        }

        for job in affectedJobs {
            activeJobIDs.remove(job.id)
            guard !job.isPaused else { continue }
            try? await repository.setSnapshot(
                SyncSnapshot(
                    jobID: job.id,
                    phase: .watching,
                    blockers: [.localVolumeUnavailable],
                    message: "StorageSync checkpointed its work. This drive can be safely disconnected."
                )
            )
        }
        return true
    }

    /// Releases the short unmount-preparation hold after macOS reports a
    /// volume event, or after an eject attempt was declined by another app.
    public func finishVolumeChange(at volumeURL: URL) async throws {
        let affectedJobs = try await jobs(onVolumeAt: volumeURL)
        for job in affectedJobs {
            unmountingJobIDs.remove(job.id)
            guard !job.isPaused else { continue }
            try await repository.makeWaitingTransfersRunnable(jobID: job.id)
            await requestRun(jobID: job.id)
        }
    }

    /// The jobs whose folder lives on this volume.
    ///
    /// The path saved at setup is not enough on its own. A drive that mounts
    /// while another of the same name is attached, or after an unclean eject
    /// left its old mount point behind, appears as `/Volumes/Name 1`; a renamed
    /// drive moves too. The bookmark follows the folder and syncing carries on,
    /// but matching only the saved path meant an eject no longer waited for a
    /// checkpoint and reconnecting the drive no longer woke the sync. Where the
    /// folder last resolved and the volume's own identifier are checked as
    /// well; the identifier can only be read while the volume is mounted, and
    /// the resolved path covers the unmount that follows.
    private func jobs(onVolumeAt volumeURL: URL) async throws -> [SyncJob] {
        let volumeUUID = Self.volumeUUID(at: volumeURL)
        return try await repository.jobs().filter { job in
            if Self.localPath(job.localRoot.fallbackPath, isWithin: volumeURL) { return true }
            if let resolved = resolvedRootPaths[job.id], Self.localPath(resolved, isWithin: volumeURL) {
                return true
            }
            if let volumeUUID, let expected = job.localRoot.expectedVolume?.persistentUUID {
                return expected == volumeUUID
            }
            return false
        }
    }

    private nonisolated static func volumeUUID(at volumeURL: URL) -> String? {
        var uncached = volumeURL
        uncached.removeAllCachedResourceValues()
        return try? uncached.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    private func requestRun(jobID: SyncJobID, allowAttention: Bool = false) async {
        guard !isStopping, !removingJobIDs.contains(jobID),
              !unmountingJobIDs.contains(jobID) else { return }
        guard allowAttention || !attentionJobIDs.contains(jobID) else { return }
        if activeJobIDs.contains(jobID) {
            externalWakeJobIDs.insert(jobID)
            let isNewRequest = pendingWakeJobIDs.insert(jobID).inserted
            if isNewRequest, var snapshot = try? await repository.snapshot(jobID: jobID) {
                snapshot.isRescanPending = true
                try? await repository.setSnapshot(snapshot)
            }
        } else {
            if var snapshot = try? await repository.snapshot(jobID: jobID) {
                snapshot.phase = .scanning
                snapshot.blockers = []
                snapshot.currentRelativePath = nil
                snapshot.isRescanPending = false
                snapshot.sourceChangeNotice = nil
                snapshot.message = "Checking for changes…"
                try? await repository.setSnapshot(snapshot)
            }
            schedule(jobID: jobID, immediate: true)
        }
    }

    private func schedule(jobID: SyncJobID, immediate: Bool) {
        guard !isStopping, !removingJobIDs.contains(jobID),
              !unmountingJobIDs.contains(jobID) else { return }
        // Cancellation is cooperative, so the outgoing cycle can still be
        // inside an upload or a listing long after it was cancelled. Two
        // cycles for one job take independent manifest generations and then
        // delete each other's rows in `finishManifestScan`, prune the
        // baselines the shredded manifest no longer covers, and are handed the
        // same queued transfers — two multipart uploads on one key, or two
        // handles writing one `.partial`. So a replacement waits for its
        // predecessor, exactly as `pause`, `remove` and `prepareForVolumeUnmount`
        // already wait for theirs.
        //
        // The waiting happens inside the new task rather than here. `schedule`
        // is reached straight from the XPC command paths, which must not park
        // behind a part that is still checkpointing, and a job task never
        // calls back into `schedule`, so nothing can wait on itself.
        let previous = jobTasks.removeValue(forKey: jobID)
        previous?.cancel()
        jobTasks[jobID] = Task { [weak self] in
            await previous?.value
            if !immediate {
                try? await Task.sleep(for: .seconds(2))
            }
            var transientFailureAttempt = 0
            var changeRescanAttempt = 0
            var scanNextCycle = true
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.runCycle(jobID: jobID, scan: scanNextCycle)
                scanNextCycle = true
                guard !Task.isCancelled else { return }
                if outcome.supersededTransferCount == 0 { changeRescanAttempt = 0 }
                if let wake = await self.consumePendingWake(jobID: jobID) {
                    transientFailureAttempt = 0
                    // A rescan the cycle asked for itself, because something it
                    // was copying changed, used to start at once every time. A
                    // file that never stops changing — a Lightroom catalog in
                    // use, a video still being copied in, an object whose
                    // listed and fetched versions never agree — then drove
                    // full bucket listings and drive walks back to back for as
                    // long as it lasted. The first such rescan is still
                    // immediate; consecutive ones back off. Anything from
                    // outside — Sync Now, a drive or network event — replaces
                    // this task and so is never made to wait.
                    if !wake.isExternal, outcome.supersededTransferCount > 0 {
                        if changeRescanAttempt > 0 {
                            let delay = await self.scanRetryDelay(forAttempt: changeRescanAttempt - 1)
                            if delay >= .seconds(10) {
                                await self.noteDelayedChangeRescan(jobID: jobID)
                            }
                            do {
                                try await Task.sleep(for: delay)
                            } catch {
                                return
                            }
                        }
                        changeRescanAttempt += 1
                    } else {
                        changeRescanAttempt = 0
                    }
                    continue
                }
                switch outcome.disposition {
                case .attention:
                    await self.markAttention(jobID: jobID)
                    return
                case .paused:
                    return
                case .transientFailure:
                    let delay = await self.scanRetryDelay(forAttempt: transientFailureAttempt)
                    transientFailureAttempt += 1
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                    continue
                case .normal:
                    transientFailureAttempt = 0
                    await self.clearAttention(jobID: jobID)
                }
                // A caught-up or completed run stays parked until an explicit
                // Sync Now or a real lifecycle/recovery event wakes it. The
                // only timer retained here belongs to already-interrupted work
                // whose durable retry time has arrived; it is not an inventory
                // polling interval.
                guard let nextAttempt = try? await self.repository.nextWaitingAttempt(jobID: jobID) else {
                    return
                }
                let interval = Duration.seconds(max(1, nextAttempt.timeIntervalSinceNow))
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                // Only a retry came due; the next cycle runs the queue alone.
                scanNextCycle = false
            }
        }
    }

    private func markAttention(jobID: SyncJobID) {
        attentionJobIDs.insert(jobID)
    }

    private func clearAttention(jobID: SyncJobID) {
        attentionJobIDs.remove(jobID)
    }

    private func scanRetryDelay(forAttempt attempt: Int) -> Duration {
        scanRetryPolicy.delay(forAttempt: attempt, randomUnit: 1) ?? .seconds(5 * 60)
    }

    private struct PendingWake {
        var isExternal: Bool
    }

    private struct ScanNotices {
        var invalidRemoteKeys: Int
        var caseCollisions: Int
        var destinationConflicts: Int
        var skippedLocalEntries: Int
        var failedFiles: Int = 0
    }

    private static func isTerminal(_ status: TransferStatus) -> Bool {
        status == .completed || status == .failed || status == .superseded
    }

    /// Amazon's own endpoints, where an unencrypted or SSE-S3 single-part ETag
    /// is documented to be the object's MD5.
    private nonisolated static func isAmazonS3(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host?.lowercased() else { return false }
        return host.hasSuffix(".amazonaws.com") || host.hasSuffix(".amazonaws.com.cn")
    }

    /// Deletes partial downloads that no transfer row names any more.
    ///
    /// A partial is resumable only by the transfer it is named after. Rows go
    /// away in several ordinary ways — a path adopted or withdrawn, a failed
    /// row replaced by a fresh attempt, a sync removed — and each left its
    /// partial behind, gigabytes at a time, in a hidden folder on the user's
    /// drive. Rows of every job count, because two syncs can share a folder.
    private func sweepOrphanedPartials(beneath root: URL) async {
        let directory = root
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(ReservedName.partialsDirectory, isDirectory: true)
        var uncached = directory
        uncached.removeAllCachedResourceValues()
        guard let values = try? uncached.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink != true,
              values.isDirectory == true,
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [],
                                                          options: [.skipsSubdirectoryDescendants]) else { return }
        var candidates: [(TransferID, String)] = []
        func cleanBatch(_ candidates: [(TransferID, String)]) async {
            guard let existing = try? await repository.existingTransferIDs(candidates.map { $0.0 }) else { return }
            for (id, name) in candidates where !existing.contains(id) {
                DownloadPartial.remove(name, beneath: root)
            }
        }
        while let file = files.nextObject() as? URL {
            if Task.isCancelled { return }
            let name = file.lastPathComponent
            if name.hasSuffix(".partial"), let uuid = UUID(uuidString: String(name.dropLast(".partial".count))) {
                candidates.append((TransferID(rawValue: uuid), name))
            }
            if candidates.count == 256 {
                await cleanBatch(candidates)
                candidates.removeAll(keepingCapacity: true)
            }
        }
        if !candidates.isEmpty { await cleanBatch(candidates) }
    }

    private func consumePendingWake(jobID: SyncJobID) -> PendingWake? {
        let isExternal = externalWakeJobIDs.remove(jobID) != nil
        guard pendingWakeJobIDs.remove(jobID) != nil else { return nil }
        return PendingWake(isExternal: isExternal)
    }

    private func clearPendingWake(_ jobID: SyncJobID) {
        pendingWakeJobIDs.remove(jobID)
        externalWakeJobIDs.remove(jobID)
    }

    /// Only for a wait long enough to notice. The cycle left the snapshot
    /// reading "Checking for changes…" with a rescan pending, which also greys
    /// out Sync Now; across a wait of minutes that is untrue and leaves the
    /// user no way to say "check now". Snapshots that ended blocked or in
    /// attention are not in the scanning phase and are left as they are.
    private func noteDelayedChangeRescan(jobID: SyncJobID) async {
        guard var snapshot = try? await repository.snapshot(jobID: jobID),
              snapshot.phase == .scanning,
              snapshot.blockers.isEmpty else { return }
        snapshot.phase = .watching
        snapshot.isRescanPending = false
        snapshot.message = "Some files are still changing. StorageSync checks them again shortly."
        try? await repository.setSnapshot(snapshot)
    }

    @discardableResult
    private func runCycle(jobID: SyncJobID, scan: Bool = true) async -> CycleOutcome {
        activeJobIDs.insert(jobID)
        defer { activeJobIDs.remove(jobID) }
        var direction: SyncDirection = .upload
        do {
            guard let job = try await repository.job(id: jobID) else {
                return CycleOutcome(direction: direction, disposition: .normal)
            }
            direction = job.direction
            guard !job.isPaused else {
                try await repository.setSnapshot(SyncSnapshot(jobID: jobID, phase: .paused, message: "Paused"))
                return CycleOutcome(direction: direction, disposition: .paused)
            }
            guard let connection = try await repository.connection(id: job.connectionID) else {
                throw CoordinatorError.missingConnection
            }

            let previousSnapshot = try await repository.snapshot(jobID: jobID)
            // A cycle woken only because a durable retry came due has nothing
            // new to look for: the waiting transfer re-checks its own source
            // and destination before it moves a byte. Rescanning the whole
            // folder and bucket first made every retry of every file cost a
            // full scan. Such a cycle reuses the notices the last scan
            // produced and goes straight to the queue; without one to reuse —
            // a freshly started agent — it scans as usual.
            let cachedScan = scan ? nil : lastScanNotices[jobID]
            let scans = cachedScan == nil
            var snapshot: SyncSnapshot
            if scans {
                // Completed activity belongs to one scan batch. A new scan clears
                // it only after the prior resumable queue is empty; interrupted or
                // restarted backlogs keep their exact batch and history.
                _ = try await repository.beginTransferActivityBatchIfIdle(jobID: jobID)
                snapshot = SyncSnapshot(
                    jobID: jobID,
                    phase: .scanning,
                    message: "Checking for changes…",
                    isRescanPending: false,
                    recentlyQueuedCount: previousSnapshot?.recentlyQueuedCount,
                    recentlyQueuedPaths: previousSnapshot?.recentlyQueuedPaths,
                    recentlyQueuedAt: previousSnapshot?.recentlyQueuedAt
                )
            } else {
                snapshot = previousSnapshot ?? SyncSnapshot(jobID: jobID, phase: .transferring)
                snapshot.phase = .transferring
                snapshot.blockers = []
                snapshot.isRescanPending = false
                snapshot.currentRelativePath = nil
                snapshot.message = "Retrying…"
            }
            snapshot.lastSuccessfulSync = previousSnapshot?.lastSuccessfulSync
            try await repository.setSnapshot(snapshot)
            let access: ScopedURLAccess
            do {
                access = try await bookmarks.resolve(reference: job.localRoot.bookmarkReference)
            } catch {
                if FileManager.default.fileExists(atPath: job.localRoot.fallbackPath) {
                    access = ScopedURLAccess(url: URL(fileURLWithPath: job.localRoot.fallbackPath), didStartAccess: false)
                } else {
                    throw error
                }
            }
            if let expected = job.localRoot.expectedVolume {
                _ = try VolumeInspector().validate(expected: expected, selectedURL: access.url)
            }
            // Where the folder really is now. The saved path goes stale when a
            // drive mounts under another name, and eject handling matches on
            // this as well so it still finds the job.
            resolvedRootPaths[jobID] = access.url.standardizedFileURL.path

            let localCaseSensitive = job.localRoot.expectedVolume?.isCaseSensitive ?? false
            let store = try await objectStoreFactory.make(connection: connection)
            let executor = TransferExecutor(
                repository: repository,
                objectStore: store,
                transferPolicy: transferPolicy,
                verifiesETagDigests: Self.isAmazonS3(connection.endpoint)
            )
            var invalidRemoteKeyCount = cachedScan?.invalidRemoteKeys ?? 0
            var caseCollisionCount = cachedScan?.caseCollisions ?? 0
            var destinationConflictCount = cachedScan?.destinationConflicts ?? 0
            var skippedLocalEntries = cachedScan?.skippedLocalEntries ?? 0
            let destinationBytesAtScan: Int64
            let queue: TransferQueueSummary
            if scans {
                async let localTask = stageLocalManifest(
                    jobID: job.id,
                    root: access.url,
                    caseSensitive: localCaseSensitive
                )
                async let remoteTask = stageRemoteManifest(
                    jobID: job.id,
                    store: store,
                    prefix: job.remotePrefix,
                    downloading: job.direction == .download,
                    caseSensitive: localCaseSensitive
                )
                let (localScan, remoteScan) = try await (localTask, remoteTask)
                skippedLocalEntries = localScan.skippedEntryCount
                if let expected = job.localRoot.expectedVolume {
                    _ = try VolumeInspector().validate(expected: expected, selectedURL: access.url)
                }
                invalidRemoteKeyCount = remoteScan.invalidRemoteKeyCount
                caseCollisionCount = localScan.caseCollisionCount + remoteScan.caseCollisionCount
                // A baseline is retired when its source path is absent, which is
                // only evidence of deletion when the scan saw everything. A folder
                // the scan could not read is absent too, and retiring its
                // baselines turned the next successful scan into a first pairing
                // that took whatever the destination held as the copy — so an edit
                // made in between was never sent. The remote side has no partial
                // scan: a listing either completes or throws.
                let sourceScanIsComplete = job.direction == .download || localScan.skippedEntryCount == 0
                if sourceScanIsComplete {
                    let sourceSide: ManifestSide = job.direction == .upload ? .local : .remote
                    let generation = job.direction == .upload ? localScan.generation : remoteScan.generation
                    try await repository.pruneBaselinesAbsentFromManifest(jobID: job.id, side: sourceSide, generation: generation)
                    while true {
                        try Task.checkCancellation()
                        let stale = try await repository.transfersAbsentFromSource(jobID: job.id, side: sourceSide, generation: generation)
                        guard !stale.isEmpty else { break }
                        for transfer in stale {
                            if let uploadID = transfer.multipartUploadID {
                                try? await store.abortMultipartUpload(key: transfer.remoteKey, uploadID: uploadID)
                            }
                        }
                        try await repository.discardTransfers(jobID: job.id, relativePaths: stale.map(\.relativePath))
                    }
                }

                let reconciliationPageSize = 512
                var reconciliationCursor: String?
                var alreadyPresentCount = 0
                var supersededDestinationBytes: Int64 = 0
                var newlyQueuedCount = 0
                // A bounded sample makes detection visible without letting an
                // initial multi-million-file pairing grow the snapshot in memory.
                var recentlyQueuedPaths: [String] = []
                while true {
                    try Task.checkCancellation()
                    let rows = try await repository.reconciliationRows(
                        jobID: job.id,
                        direction: job.direction,
                        localGeneration: localScan.generation,
                        remoteGeneration: remoteScan.generation,
                        localCaseSensitive: localCaseSensitive,
                        after: reconciliationCursor,
                        limit: reconciliationPageSize
                    )
                    guard !rows.isEmpty else { break }
                    var plans: [TransferPlan] = []
                    var adoptions: [ReconciliationBaseline] = []
                    var obsoleteTransferPaths: [String] = []
                    plans.reserveCapacity(rows.count)
                    adoptions.reserveCapacity(rows.count)
                    obsoleteTransferPaths.reserveCapacity(rows.count)
                    let firstPairs = rows.filter { $0.baseline == nil && $0.local != nil && $0.remote != nil }
                    let previousAttempts = try await repository.transfers(jobID: job.id, relativePaths: firstPairs.map(\.relativePath))
                    let attemptsByPath = Dictionary(grouping: previousAttempts, by: \.relativePath)
                    for row in rows {
                        // An ambiguous pairing on either side is skipped whole,
                        // and any transfer already queued for it is discarded
                        // before it can run. A local collision is the dangerous
                        // one: without this, the second of two files that differ
                        // only by capitalization is handed the first one's remote
                        // key below and uploaded over its contents.
                        if row.hasRemotePathCollision || row.hasLocalPathCollision {
                            obsoleteTransferPaths.append(row.relativePath)
                            continue
                        }
                        if job.direction == .upload {
                            let key = Reconciler.remoteKey(relativePath: row.relativePath, prefix: job.remotePrefix)
                            guard Reconciler.isValidRemoteKey(key) else {
                                invalidRemoteKeyCount += 1
                                obsoleteTransferPaths.append(row.relativePath)
                                continue
                            }
                        }
                        var baseline = row.baseline
                        if baseline == nil, let attempt = attemptsByPath[row.relativePath]?.first,
                           let local = row.local, let remote = row.remote,
                           let published = try await executor.publishedBaseline(for: attempt, local: local, remote: remote, root: access.url) {
                            try await repository.saveBaseline(published, jobID: job.id)
                            baseline = published
                        }
                        // A first pairing with a visibly different file on the
                        // other side: neither adopted as a copy nor overwritten.
                        // Anything already queued for the path is withdrawn too,
                        // because it was planned before that file was seen.
                        if reconciler.isConflictingExistingDestination(
                            local: row.local,
                            remote: row.remote,
                            baseline: baseline
                        ) {
                            destinationConflictCount += 1
                            obsoleteTransferPaths.append(row.relativePath)
                            continue
                        }
                        // The destination changed since StorageSync last copied to
                        // it while the source did not. Copying again would
                        // overwrite that change — someone's edit to a restored
                        // photo, or another writer's object in the bucket — on
                        // nothing but StorageSync's say-so. A change that kept the
                        // size (a timestamp moved, an object re-encrypted in place)
                        // is taken as the current copy; any other is reported.
                        switch reconciler.destinationDrift(
                            direction: job.direction,
                            local: row.local,
                            remote: row.remote,
                            baseline: baseline
                        ) {
                        case .refreshed(let baseline):
                            adoptions.append(baseline)
                            alreadyPresentCount += 1
                            continue
                        case .conflict:
                            destinationConflictCount += 1
                            obsoleteTransferPaths.append(row.relativePath)
                            continue
                        case .unchanged:
                            break
                        }
                        if let adoption = reconciler.initialAdoptionBaseline(
                            relativePath: row.relativePath,
                            local: row.local,
                            remote: row.remote,
                            existingBaseline: baseline
                        ) {
                            adoptions.append(adoption)
                            alreadyPresentCount += 1
                            continue
                        }
                        if let plan = reconciler.transferPlan(
                            direction: job.direction,
                            prefix: job.remotePrefix,
                            relativePath: row.relativePath,
                            local: row.local,
                            remote: row.remote,
                            baseline: baseline,
                            remoteKeyOverride: row.remote?.key
                        ) {
                            plans.append(plan)
                            // Whatever this transfer lands on is about to be
                            // replaced, so it is not content the destination
                            // already has. Counting it would put one file at both
                            // ends of the storage balance and stretch the total.
                            supersededDestinationBytes += (
                                job.direction == .upload ? row.remote?.size : row.local?.size
                            ) ?? 0
                        } else if row.local != nil, row.remote != nil {
                            alreadyPresentCount += 1
                            obsoleteTransferPaths.append(row.relativePath)
                        }
                    }
                    if !adoptions.isEmpty {
                        // A previous build may already have staged multipart work
                        // for a path that is now being adopted. Abort it before the
                        // durable queue row is removed so it does not leak remotely.
                        let staleTransfers = try await repository.transfers(
                            jobID: job.id,
                            relativePaths: adoptions.map(\.relativePath)
                        )
                        for stale in staleTransfers {
                            if let uploadID = stale.multipartUploadID {
                                try? await store.abortMultipartUpload(
                                    key: stale.remoteKey,
                                    uploadID: uploadID
                                )
                            }
                        }
                        try await repository.adoptExistingDestinations(adoptions, jobID: job.id)
                    }
                    if !obsoleteTransferPaths.isEmpty {
                        let obsolete = try await repository.transfers(
                            jobID: job.id,
                            relativePaths: obsoleteTransferPaths
                        )
                        for transfer in obsolete {
                            if let uploadID = transfer.multipartUploadID {
                                try? await store.abortMultipartUpload(
                                    key: transfer.remoteKey,
                                    uploadID: uploadID
                                )
                            }
                        }
                        // Every already-present path lands in `obsoleteTransferPaths`,
                        // which in a caught-up sync is the entire library. Only the
                        // paths that actually have a queue row need deleting, and the
                        // query above already named them, so the steady-state cost of
                        // a cycle stays proportional to outstanding work rather than
                        // to the number of files being watched.
                        let pathsWithQueuedWork = obsolete.map(\.relativePath)
                        if !pathsWithQueuedWork.isEmpty {
                            try await repository.discardTransfers(
                                jobID: job.id,
                                relativePaths: pathsWithQueuedWork
                            )
                        }
                    }
                    if !plans.isEmpty {
                        // Enqueueing replaces a path's finished, failed or
                        // superseded row with a fresh one. A failed upload's row
                        // can still name an open multipart upload, which the
                        // provider keeps — and bills for — until it is aborted.
                        let replaced = try await repository.transfers(
                            jobID: job.id,
                            relativePaths: plans.map(\.relativePath)
                        )
                        for stale in replaced where Self.isTerminal(stale.status) {
                            if let uploadID = stale.multipartUploadID {
                                try? await store.abortMultipartUpload(key: stale.remoteKey, uploadID: uploadID)
                            }
                        }
                    }
                    let enqueuedPaths = try await repository.enqueueTransfersIfNeeded(plans, jobID: job.id)
                    newlyQueuedCount += enqueuedPaths.count
                    for path in enqueuedPaths {
                        recentlyQueuedPaths.append(path)
                        if recentlyQueuedPaths.count > 3 { recentlyQueuedPaths.removeFirst() }
                    }
                    reconciliationCursor = rows.last?.relativePath
                    if rows.count < reconciliationPageSize { break }
                }

                lastScanNotices[jobID] = ScanNotices(
                    invalidRemoteKeys: invalidRemoteKeyCount,
                    caseCollisions: caseCollisionCount,
                    destinationConflicts: destinationConflictCount,
                    skippedLocalEntries: skippedLocalEntries
                )
                await sweepOrphanedPartials(beneath: access.url)

                queue = try await repository.activeTransferSummary(jobID: job.id)
                snapshot.sourceFilesFound = job.direction == .upload
                    ? localScan.entryCount
                    : remoteScan.entryCount
                snapshot.destinationFilesFound = job.direction == .upload
                    ? remoteScan.entryCount
                    : localScan.entryCount
                snapshot.filesAlreadyPresent = alreadyPresentCount
                destinationBytesAtScan = max(
                    0,
                    (job.direction == .upload ? remoteScan.byteCount : localScan.byteCount)
                        - supersededDestinationBytes
                )
                snapshot.sourceBytesFound = job.direction == .upload
                    ? localScan.byteCount
                    : remoteScan.byteCount
                if newlyQueuedCount > 0 {
                    snapshot.recentlyQueuedCount = newlyQueuedCount
                    snapshot.recentlyQueuedPaths = recentlyQueuedPaths
                    snapshot.recentlyQueuedAt = Date()
                } else if queue.count == 0 {
                    snapshot.recentlyQueuedCount = nil
                    snapshot.recentlyQueuedPaths = nil
                    snapshot.recentlyQueuedAt = nil
                }
            } else {
                queue = try await repository.activeTransferSummary(jobID: job.id)
                // Everything already at the destination, including what earlier
                // runs moved, was folded into this when the last cycle ended.
                destinationBytesAtScan = max(0, snapshot.destinationBytesInPlace ?? 0)
            }
            snapshot.phase = queue.count == 0 ? .watching : .transferring
            snapshot.filesTotal = queue.count
            snapshot.bytesTotal = queue.totalBytes
            snapshot.bytesCompleted = queue.completedBytes
            snapshot.destinationBytesInPlace = destinationBytesAtScan
            snapshot.isRescanPending = pendingWakeJobIDs.contains(job.id)
            // Files that fail outright are counted rather than allowed to stop
            // the run, so the headline has to be rebuilt as they accumulate.
            var failedFileCount = cachedScan?.failedFiles ?? 0
            var supersededTransferCount = 0
            var copiedBytes: Int64 = 0
            var jobWideAttention = false
            let transferHeadline = queue.count == 0
                ? nil
                : "Syncing \(queue.count) item\(queue.count == 1 ? "" : "s")…"
            func cycleNotices() -> [String] {
                Self.notices(
                    invalidRemoteKeys: invalidRemoteKeyCount,
                    caseCollisions: caseCollisionCount,
                    destinationConflicts: destinationConflictCount,
                    skippedLocalEntries: skippedLocalEntries,
                    failedFiles: failedFileCount
                )
            }
            snapshot.message = Self.message(headline: transferHeadline, notices: cycleNotices())
            try await repository.setSnapshot(snapshot)

            let maximumParallelFiles = max(1, transferPolicy.maximumConcurrentFiles)
            let transferBatchSize = max(16, maximumParallelFiles * 4)
            let progressRepository = repository
            let permitPool = transferPermitPool
            let progressAccumulator = TransferProgressAccumulator(initialCompleted: queue.completedBytes)
            var shouldStopScheduling = false
            while !shouldStopScheduling {
                try Task.checkCancellation()
                // A pending Sync Now or recovery request never cancels an
                // admitted upload/download. It stops the next in-flight batch
                // from being admitted, which bounds rescan latency without
                // losing a part checkpoint.
                if pendingWakeJobIDs.contains(job.id) { break }
                let fetched = try await repository.runnableTransfers(
                    jobID: job.id,
                    limit: transferBatchSize
                )
                guard !fetched.isEmpty else { break }
                // Work queued for a name StorageSync now ignores — Finder's
                // .DS_Store, Windows' Thumbs.db — before it was ignored. The
                // scan no longer lists these paths, so nothing else would
                // ever withdraw them.
                let ignored = fetched.filter { IgnoredName.isIgnoredPath($0.relativePath) }
                if !ignored.isEmpty {
                    for transfer in ignored {
                        if let uploadID = transfer.multipartUploadID {
                            try? await store.abortMultipartUpload(key: transfer.remoteKey, uploadID: uploadID)
                        }
                    }
                    try await repository.discardTransfers(
                        jobID: job.id,
                        relativePaths: ignored.map(\.relativePath)
                    )
                }
                let transfers = fetched.filter { !IgnoredName.isIgnoredPath($0.relativePath) }
                guard !transfers.isEmpty else { continue }
                for transfer in transfers { await progressAccumulator.register(transfer) }
                snapshot.currentRelativePath = transfers.first?.relativePath
                try await repository.setSnapshot(snapshot)

                try await withThrowingTaskGroup(of: FileTransferAttempt.self) { group in
                    var nextIndex = 0
                    // Starting a file and starting the next one after a slot
                    // frees up are the same operation, so they are written once.
                    // They drifted apart easily when they were two copies.
                    func startNextTransfer() {
                        guard nextIndex < transfers.count else { return }
                        let transfer = transfers[nextIndex]
                        nextIndex += 1
                        let permitWeight = filePermitWeight(
                            for: transfer,
                            maximumParallelFiles: maximumParallelFiles
                        )
                        group.addTask {
                            FileTransferAttempt(
                                transfer: transfer,
                                result: await permitPool.perform(weight: permitWeight) {
                                    await executor.execute(
                                        transfer,
                                        job: job,
                                        root: access.url,
                                        progress: { completedBytes in
                                            let aggregate = await progressAccumulator.update(
                                                transferID: transfer.id,
                                                completedBytes: completedBytes
                                            )
                                            try? await progressRepository.updateSnapshotProgress(
                                                jobID: job.id,
                                                bytesCompleted: aggregate,
                                                currentRelativePath: transfer.relativePath
                                            )
                                        }
                                    )
                                }
                            )
                        }
                    }

                    for _ in 0..<min(maximumParallelFiles, transfers.count) {
                        startNextTransfer()
                    }

                    while let attempt = try await group.next() {
                        try Task.checkCancellation()
                        snapshot.currentRelativePath = attempt.transfer.relativePath
                        switch attempt.result {
                        case .completed:
                            copiedBytes += attempt.transfer.totalBytes
                            snapshot.filesCompleted += 1
                            snapshot.filesAlreadyPresent = (snapshot.filesAlreadyPresent ?? 0) + 1
                            let destinationExisted = attempt.transfer.kind == .upload
                                ? attempt.transfer.remoteSource != nil
                                : attempt.transfer.sourceFingerprint != nil
                            if !destinationExisted {
                                snapshot.destinationFilesFound = (snapshot.destinationFilesFound ?? 0) + 1
                            }
                            // The byte totals deliberately have no equivalent
                            // line here. `StorageBalance` already adds
                            // `bytesCompleted` to `destinationBytesInPlace`, so
                            // crediting the destination per file as well would
                            // count the same bytes twice. The run's finished
                            // work is folded in once, below.
                            // A finished file may have reported less than its
                            // full size, so settle its contribution at the total.
                            _ = await progressAccumulator.update(
                                transferID: attempt.transfer.id,
                                completedBytes: attempt.transfer.totalBytes
                            )
                        case .cancelled:
                            break
                        case .waiting(let blocker, let message):
                            // Nothing new is started, but what is already in
                            // flight is left to finish. Cancelling it threw
                            // away a part that might be minutes from done
                            // whenever any one file hit a brief error; if the
                            // whole network or drive is really gone, those
                            // transfers fail and park themselves soon enough.
                            snapshot.blockers.insert(blocker)
                            snapshot.message = message
                            shouldStopScheduling = true
                        case .retryingFile:
                            // One file waits for its own retry. The job is fine.
                            break
                        case .attention(let blocker, let message):
                            if let blocker {
                                // A blocker names something the whole job runs
                                // on — keys that no longer work fail every
                                // remaining file — so there is nothing to gain
                                // from starting the rest of the batch.
                                jobWideAttention = true
                                snapshot.phase = .attention
                                snapshot.blockers.insert(blocker)
                                snapshot.message = message
                                shouldStopScheduling = true
                                group.cancelAll()
                            } else {
                                // Without a blocker this is one file that will
                                // never transfer: larger than S3 or the
                                // destination filesystem allows, unplannable
                                // parts, a response that cannot be read. It is
                                // already `.failed` in the database and so is
                                // out of this cycle's queue. Cancelling the
                                // group here parked the entire job on it: one
                                // oversized file stopped a healthy 5,000-file
                                // library for good, and Sync Now only re-hit
                                // the same file. The rest of the batch runs;
                                // the count is reported with the cycle.
                                failedFileCount += 1
                                lastScanNotices[jobID]?.failedFiles = failedFileCount
                                snapshot.message = Self.message(
                                    headline: transferHeadline,
                                    notices: cycleNotices()
                                )
                            }
                        case .superseded(let reliableNotice):
                            if let reliableNotice {
                                snapshot.sourceChangeNotice = "\(attempt.transfer.relativePath): \(reliableNotice) The latest version will be checked automatically."
                            }
                            // The source or destination changed after this scan.
                            // Reconcile the new version immediately instead of
                            // reporting success until the next polling interval.
                            // The count lets the scheduler back off when the
                            // same thing happens cycle after cycle.
                            supersededTransferCount += 1
                            pendingWakeJobIDs.insert(job.id)
                        }
                        await progressAccumulator.finish(transferID: attempt.transfer.id)
                        snapshot.bytesCompleted = await progressAccumulator.totalCompleted()
                        snapshot.isRescanPending = pendingWakeJobIDs.contains(job.id)
                        try await repository.setSnapshot(snapshot)

                        // Drain only the files already in flight after a rescan
                        // request. The rest of this disk-backed fetch remains
                        // queued and is reconsidered after the new manifest.
                        if !shouldStopScheduling,
                           !pendingWakeJobIDs.contains(job.id) {
                            startNextTransfer()
                        }
                    }
                }
            }

            // Only successfully published files have left the queue for the destination.
            // An abandoned partial is not a completed copy, even if every byte was fetched.
            let remaining = try await repository.activeTransferSummary(jobID: job.id)
            let rescanPending = pendingWakeJobIDs.contains(job.id)
            snapshot.currentRelativePath = nil
            snapshot.isRescanPending = rescanPending
            snapshot.filesCompleted = 0
            snapshot.filesTotal = remaining.count
            snapshot.bytesCompleted = remaining.completedBytes
            snapshot.bytesTotal = remaining.totalBytes
            snapshot.destinationBytesInPlace = destinationBytesAtScan + min(copiedBytes, Int64.max - destinationBytesAtScan)
            if !jobWideAttention, snapshot.blockers.isEmpty {
                snapshot.phase = rescanPending ? .scanning : .watching
                if rescanPending {
                    snapshot.message = "Checking for changes…"
                } else if remaining.count == 0 {
                    snapshot.recentlyQueuedCount = nil
                    snapshot.recentlyQueuedPaths = nil
                    snapshot.recentlyQueuedAt = nil
                    snapshot.message = Self.message(headline: nil, notices: cycleNotices())
                    // Nothing is queued to retry, so a file that failed will
                    // not move again on its own. Saying "All caught up" in that
                    // state would claim a destination copy that does not exist,
                    // and the phase is what turns the count into something the
                    // user is shown rather than something they have to notice.
                    // A destination conflict is the same claim: that source
                    // file has no copy until someone decides which one wins.
                    if cycleNotices().isEmpty {
                        snapshot.lastSuccessfulSync = Date()
                    } else {
                        snapshot.phase = .attention
                    }
                } else {
                    snapshot.message = Self.message(
                        headline: "Waiting to retry \(remaining.count) item\(remaining.count == 1 ? "" : "s")…",
                        notices: cycleNotices()
                    )
                }
            }
            try await repository.setSnapshot(snapshot)
            // Deliberately not `snapshot.phase`: a cycle that ends in attention
            // over individual files is still a healthy job that should keep its
            // timers and be woken normally. Only a job-wide blocker parks it
            // until the user fixes something.
            return CycleOutcome(
                direction: direction,
                disposition: jobWideAttention ? .attention : .normal,
                supersededTransferCount: supersededTransferCount
            )
        } catch is CancellationError {
            return CycleOutcome(direction: direction, disposition: .normal)
        } catch let error as VolumeInspectorError {
            try? await repository.setSnapshot(
                SyncSnapshot(
                    jobID: jobID,
                    phase: .watching,
                    blockers: [.localVolumeUnavailable],
                    message: error.localizedDescription
                )
            )
            return CycleOutcome(direction: direction, disposition: .transientFailure)
        } catch let error as CocoaError {
            // A drive can disappear while the recursive scan is in progress,
            // before an individual transfer has a chance to classify it.
            try? await repository.setSnapshot(
                SyncSnapshot(
                    jobID: jobID,
                    phase: .watching,
                    blockers: [.localVolumeUnavailable],
                    message: error.localizedDescription
                )
            )
            return CycleOutcome(direction: direction, disposition: .transientFailure)
        } catch let error as POSIXError {
            try? await repository.setSnapshot(
                SyncSnapshot(
                    jobID: jobID,
                    phase: .watching,
                    blockers: [.localVolumeUnavailable],
                    message: error.localizedDescription
                )
            )
            return CycleOutcome(direction: direction, disposition: .transientFailure)
        } catch let error as ObjectStoreError {
            let isAttention: Bool
            let attentionBlockers: Set<SyncBlocker>
            switch error {
            case .authentication, .accessDenied:
                isAttention = true
                attentionBlockers = [.credentialsUnavailable]
            case .incompatible:
                isAttention = true
                attentionBlockers = [.providerIncompatible]
            default:
                isAttention = false
                attentionBlockers = []
            }
            try? await repository.setSnapshot(
                SyncSnapshot(
                    jobID: jobID,
                    phase: isAttention ? .attention : .watching,
                    blockers: isAttention ? attentionBlockers : [.networkUnavailable],
                    message: error.localizedDescription
                )
            )
            return CycleOutcome(
                direction: direction,
                disposition: isAttention ? .attention : .transientFailure
            )
        } catch {
            try? await repository.setSnapshot(
                SyncSnapshot(jobID: jobID, phase: .attention, message: error.localizedDescription)
            )
            return CycleOutcome(direction: direction, disposition: .attention)
        }
    }

    /// What a cycle left behind, in the order the user can act on it. These are
    /// independent of each other — an unsafe key says nothing about an
    /// ambiguous name or a file that was refused — so reporting only the first
    /// would hide the others until that one was fixed.
    private static func notices(
        invalidRemoteKeys: Int,
        caseCollisions: Int,
        destinationConflicts: Int,
        skippedLocalEntries: Int,
        failedFiles: Int
    ) -> [String] {
        var sentences: [String] = []
        if skippedLocalEntries > 0 {
            sentences.append("Could not read \(skippedLocalEntries) local entr\(skippedLocalEntries == 1 ? "y" : "ies") during the scan")
        }
        if invalidRemoteKeys > 0 {
            sentences.append(
                "Skipped \(invalidRemoteKeys) unsafe object path\(invalidRemoteKeys == 1 ? "" : "s")"
            )
        }
        if caseCollisions > 0 {
            sentences.append(
                caseCollisions == 1
                    ? "Skipped 1 ambiguous filename"
                    : "Skipped \(caseCollisions) filenames that cannot coexist locally"
            )
        }
        if destinationConflicts > 0 {
            sentences.append(
                destinationConflicts == 1
                    ? "Left 1 file untouched because a different file already has its name at the destination"
                    : "Left \(destinationConflicts) files untouched because different files already have their names at the destination"
            )
        }
        if failedFiles > 0 {
            sentences.append(
                "\(failedFiles) file\(failedFiles == 1 ? "" : "s") could not be copied"
            )
        }
        return sentences
    }

    /// A headline of `nil` means there is nothing in flight to describe, so the
    /// notices become the whole message rather than a footnote to "All caught
    /// up" — which would otherwise read as a contradiction of itself.
    private static func message(headline: String?, notices: [String]) -> String {
        guard !notices.isEmpty else { return headline ?? "All caught up" }
        let sentences = notices.joined(separator: ". ")
        guard let headline else { return sentences }
        return "\(headline) \(sentences)."
    }

    private func stageLocalManifest(
        jobID: SyncJobID,
        root: URL,
        caseSensitive: Bool
    ) async throws -> ManifestScanResult {
        let generation = try await repository.nextManifestGeneration(jobID: jobID, side: .local)
        var batch: [FileFingerprint] = []
        var entryCount = 0
        var byteCount: Int64 = 0
        let skipped = LocalScanSkipCounter()
        batch.reserveCapacity(512)
        for try await file in scanner.files(at: root, skipped: skipped) {
            try Task.checkCancellation()
            batch.append(file)
            entryCount += 1
            let (total, overflow) = byteCount.addingReportingOverflow(max(0, file.size))
            guard !overflow else { throw CocoaError(.fileReadTooLarge) }
            byteCount = total
            if batch.count == 512 {
                try await repository.upsertLocalManifestEntries(
                    batch,
                    jobID: jobID,
                    generation: generation,
                    caseSensitive: caseSensitive
                )
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try await repository.upsertLocalManifestEntries(
                batch,
                jobID: jobID,
                generation: generation,
                caseSensitive: caseSensitive
            )
        }
        try await repository.finishManifestScan(jobID: jobID, side: .local, generation: generation)
        // The mirror of the remote-side check. Both halves are needed: a
        // volume whose case-sensitivity probe returned nothing is treated as
        // case-insensitive, and on a volume that is in fact case-sensitive
        // that assumption pairs two different local files with one remote key
        // and lets them overwrite each other's contents there, cycle after
        // cycle. Neither of the pair is reconciled until the names differ by
        // more than capitalization.
        let caseCollisionCount = try await repository.recordCaseCollidingManifestEntries(
            jobID: jobID,
            side: .local,
            generation: generation
        )
        return ManifestScanResult(
            generation: generation,
            invalidRemoteKeyCount: 0,
            caseCollisionCount: caseCollisionCount,
            entryCount: entryCount,
            byteCount: byteCount,
            skippedEntryCount: skipped.count
        )
    }

    private func filePermitWeight(
        for transfer: TransferRecord,
        maximumParallelFiles: Int
    ) -> Int {
        let largePartThreshold: Int64 = 128 * 1_024 * 1_024
        guard let partSize = try? transferPolicy.partSize(forFileSize: transfer.totalBytes),
              partSize <= largePartThreshold else {
            return maximumParallelFiles
        }
        return 1
    }

    private func stageRemoteManifest(
        jobID: SyncJobID,
        store: any ObjectStore,
        prefix: String,
        downloading: Bool,
        caseSensitive: Bool
    ) async throws -> ManifestScanResult {
        let generation = try await repository.nextManifestGeneration(jobID: jobID, side: .remote)
        var batch: [RemoteManifestRecord] = []
        batch.reserveCapacity(512)
        var invalidRemoteKeyCount = 0
        var entryCount = 0
        var byteCount: Int64 = 0
        var token: String?
        // Brent cycle detection also catches A -> B -> A while retaining a
        // single opaque token for a listing of any length.
        var anchor: String?
        var span = 1
        var distance = 0
        let normalizedPrefix = SyncJob.normalizedPrefix(prefix)
        let listingPrefix = normalizedPrefix.isEmpty ? "" : normalizedPrefix + "/"
        repeat {
            try Task.checkCancellation()
            let page = try await store.list(prefix: listingPrefix, continuationToken: token)
            for object in page.objects where !object.key.hasSuffix("/") {
                guard let relativePath = Reconciler.relativePath(for: object.key, prefix: prefix) else {
                    invalidRemoteKeyCount += 1
                    continue
                }
                if Reconciler.isReservedInternalPath(relativePath) || IgnoredName.isIgnoredPath(relativePath) {
                    continue
                }
                guard Reconciler.isSafeRelativePath(relativePath) else {
                    invalidRemoteKeyCount += 1
                    continue
                }
                // The S3 listing boundary rejects a negative size, but a transfer's
                // total byte count is built from the manifest, so do not persist one
                // from any other store either.
                guard object.size >= 0 else {
                    invalidRemoteKeyCount += 1
                    continue
                }
                entryCount += 1
                let (total, overflow) = byteCount.addingReportingOverflow(object.size)
                guard !overflow else { throw ObjectStoreError.invalidResponse("The S3 inventory exceeds the supported byte count.") }
                byteCount = total
                batch.append(
                    RemoteManifestRecord(
                        relativePath: relativePath,
                        canonicalPath: Reconciler.canonicalLocalPath(relativePath, caseSensitive: caseSensitive),
                        object: object
                    )
                )
                if batch.count == 512 {
                    try await repository.upsertRemoteManifestEntries(
                        batch,
                        jobID: jobID,
                        generation: generation
                    )
                    batch.removeAll(keepingCapacity: true)
                }
            }
            token = page.nextContinuationToken
            if let token {
                guard token != anchor else {
                    throw ObjectStoreError.invalidResponse("The S3 object listing repeated a continuation token.")
                }
                distance += 1
                if distance == span {
                    anchor = token
                    span = span <= Int.max / 2 ? span * 2 : Int.max
                    distance = 0
                }
            }
        } while token != nil
        if !batch.isEmpty {
            try await repository.upsertRemoteManifestEntries(
                batch,
                jobID: jobID,
                generation: generation
            )
        }
        try await repository.finishManifestScan(jobID: jobID, side: .remote, generation: generation)
        // The colliding objects are recorded, not dropped, for the same reason
        // the local side keeps its own: a download prunes its baselines
        // against this manifest, and a group missing from it reads as objects
        // that were deleted. Reconciliation skips the group on the flag.
        let caseCollisionCount = try await repository.recordCaseCollidingManifestEntries(
            jobID: jobID,
            side: .remote,
            generation: generation,
            detectFileDirectoryConflicts: downloading
        )
        return ManifestScanResult(
            generation: generation,
            invalidRemoteKeyCount: invalidRemoteKeyCount,
            caseCollisionCount: caseCollisionCount,
            entryCount: entryCount,
            byteCount: byteCount
        )
    }

    private nonisolated static func removeDownloadPartials(
        named transferIDs: [TransferID],
        beneath root: URL
    ) {
        for transferID in transferIDs {
            DownloadPartial.remove(transferID.description + ".partial", beneath: root)
        }
    }

    private nonisolated static func localPath(_ localPath: String, isWithin volumeURL: URL) -> Bool {
        let volumePath = volumeURL.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: localPath).standardizedFileURL.path
        let prefix = volumePath == "/" ? "/" : volumePath + "/"
        return candidate == volumePath || candidate.hasPrefix(prefix)
    }
}

public enum CoordinatorError: Error, LocalizedError {
    case missingConnection
    case missingCredential
    case credentialNameMissing
    case credentialNameTaken(String)
    case credentialKeysMissing
    case credentialInUse([String])

    public var errorDescription: String? {
        switch self {
        case .missingConnection:
            "The S3 connection for this sync no longer exists."
        case .missingCredential:
            "Those saved credentials are no longer in your Keychain."
        case .credentialNameMissing:
            "Give these credentials a name."
        case .credentialNameTaken(let name):
            "Credentials named “\(name)” already exist. Choose another name."
        case .credentialKeysMissing:
            "Enter the access key and secret key."
        case .credentialInUse(let jobNames):
            switch jobNames.count {
            case 1:
                "“\(jobNames[0])” is using these credentials. Point that sync at other credentials, or remove it first."
            default:
                "\(jobNames.count) syncs are using these credentials: \(jobNames.formatted(.list(type: .and))). Point them at other credentials, or remove them first."
            }
        }
    }
}
