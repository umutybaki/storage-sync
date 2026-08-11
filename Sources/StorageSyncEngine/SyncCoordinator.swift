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

    func totalCompleted() -> Int64 {
        aggregateCompleted
    }
}

private struct ManifestScanResult: Sendable {
    var generation: Int64
    var invalidRemoteKeyCount: Int
    var entryCount: Int
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
}

private actor TransferPermitPool {
    private struct Waiter {
        var weight: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private let capacity: Int
    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        capacity = max(1, limit)
        available = max(1, limit)
    }

    func perform<T: Sendable>(weight requestedWeight: Int = 1, _ operation: @Sendable () async -> T) async -> T {
        let weight = min(capacity, max(1, requestedWeight))
        await acquire(weight: weight)
        let result = await operation()
        release(weight: weight)
        return result
    }

    private func acquire(weight: Int) async {
        if waiters.isEmpty, available >= weight {
            available -= weight
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(weight: weight, continuation: continuation))
        }
    }

    private func release(weight: Int) {
        available = min(capacity, available + weight)
        while let first = waiters.first, first.weight <= available {
            available -= first.weight
            waiters.removeFirst().continuation.resume()
        }
    }
}

public actor SyncCoordinator {
    private let repository: SyncRepository
    private let bookmarks: BookmarkStore
    private let keychain: KeychainStore
    private let objectStoreFactory: ObjectStoreFactory
    private let scanner: LocalScanner
    private let reconciler: Reconciler
    private let transferPolicy: TransferPolicy
    private let scanRetryPolicy: RetryPolicy
    private let transferPermitPool: TransferPermitPool
    private var jobTasks: [SyncJobID: Task<Void, Never>] = [:]
    private var watcherTasks: [SyncJobID: Task<Void, Never>] = [:]
    private var activeJobIDs: Set<SyncJobID> = []
    private var pendingWakeJobIDs: Set<SyncJobID> = []
    private var attentionJobIDs: Set<SyncJobID> = []
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
        self.repository = repository
        self.bookmarks = bookmarks
        self.keychain = keychain
        objectStoreFactory = ObjectStoreFactory(keychain: keychain)
        self.scanner = scanner
        self.reconciler = reconciler
        self.transferPolicy = transferPolicy
        scanRetryPolicy = RetryPolicy(baseDelay: .seconds(2), maximumDelay: .seconds(5 * 60))
        transferPermitPool = TransferPermitPool(limit: transferPolicy.maximumConcurrentFiles)
    }

    public func start() async throws {
        for job in try await repository.jobs() {
            if job.isPaused {
                try await repository.setSnapshot(
                    SyncSnapshot(jobID: job.id, phase: .paused, message: "Paused")
                )
                continue
            }
            schedule(jobID: job.id, immediate: true)
            await installWatcher(for: job, replace: false)
        }
    }

    public func stop() {
        for task in jobTasks.values { task.cancel() }
        for task in watcherTasks.values { task.cancel() }
        jobTasks.removeAll()
        watcherTasks.removeAll()
    }

    public func jobs() async throws -> [SyncJob] {
        try await repository.jobs()
    }

    public func snapshots() async throws -> [SyncSnapshot] {
        try await repository.snapshots()
    }

    public func connections() async throws -> [S3Connection] {
        try await repository.connections()
    }

    public func save(connection: S3Connection, credentials: S3Credentials) async throws {
        try await keychain.save(credentials, reference: connection.credentialReference)
        try await repository.saveConnection(connection)
        for job in try await repository.jobs() where job.connectionID == connection.id && !job.isPaused {
            attentionJobIDs.remove(job.id)
            requestRun(jobID: job.id, allowAttention: true)
        }
    }

    public func save(job: SyncJob) async throws {
        precondition(job.deletionPolicy == .preserveDestination)
        try await repository.saveJob(job)
        attentionJobIDs.remove(job.id)
        schedule(jobID: job.id, immediate: true)
        await installWatcher(for: job, replace: true)
    }

    public func pause(jobID: SyncJobID) async throws {
        guard var job = try await repository.job(id: jobID) else { return }
        job.isPaused = true
        try await repository.saveJob(job)
        pendingWakeJobIDs.remove(jobID)
        let task = jobTasks.removeValue(forKey: jobID)
        task?.cancel()
        await task?.value
        watcherTasks.removeValue(forKey: jobID)?.cancel()
        try await repository.setSnapshot(
            SyncSnapshot(jobID: jobID, phase: .paused, message: "Paused")
        )
    }

    public func resume(jobID: SyncJobID) async throws {
        guard var job = try await repository.job(id: jobID) else { return }
        job.isPaused = false
        try await repository.saveJob(job)
        try await repository.makeWaitingTransfersRunnable(jobID: jobID)
        pendingWakeJobIDs.remove(jobID)
        attentionJobIDs.remove(jobID)
        schedule(jobID: jobID, immediate: true)
        await installWatcher(for: job, replace: true)
    }

    /// Removes StorageSync's configuration and resumable state for a job. This
    /// operation deliberately never removes a completed local file or S3
    /// object. Only exact job-owned download partials and incomplete multipart
    /// uploads are cleaned up on a best-effort basis.
    public func remove(jobID: SyncJobID) async throws {
        guard let job = try await repository.job(id: jobID),
              !removingJobIDs.contains(jobID) else { return }

        removingJobIDs.insert(jobID)
        pendingWakeJobIDs.remove(jobID)
        attentionJobIDs.remove(jobID)

        let jobTask = jobTasks.removeValue(forKey: jobID)
        jobTask?.cancel()
        await jobTask?.value
        let watcherTask = watcherTasks.removeValue(forKey: jobID)
        watcherTask?.cancel()
        await watcherTask?.value
        activeJobIDs.remove(jobID)

        let transfers = (try? await repository.activeTransfers(jobID: jobID)) ?? []
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
                await installWatcher(for: job, replace: true)
            }
            throw error
        }
        removingJobIDs.remove(jobID)

        // These cleanup operations cannot make removal fail after the durable
        // job row is gone. At worst, a harmless bookmark, credential, partial,
        // or provider-side multipart upload remains orphaned.
        try? await bookmarks.remove(reference: job.localRoot.bookmarkReference)
        if let scopedRoot {
            // The security-scoped access has to outlive the deletions, not just
            // the read of its URL, or the sandbox can revoke it mid-cleanup.
            withExtendedLifetime(scopedRoot) {
                Self.removeDownloadPartials(for: transfers, beneath: scopedRoot.url)
            }
        }

        let connectionStillUsed = (try? await repository.jobs())?.contains {
            $0.connectionID == job.connectionID
        } ?? true
        if !connectionStillUsed, let connection {
            try? await keychain.remove(reference: connection.credentialReference)
            try? await repository.removeConnection(id: connection.id)
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

    public func syncNow(jobID: SyncJobID) async {
        try? await repository.makeWaitingTransfersRunnable(jobID: jobID)
        attentionJobIDs.remove(jobID)
        requestRun(jobID: jobID, allowAttention: true)
    }

    public func wakeAll() async throws {
        for job in try await repository.jobs()
        where !job.isPaused
            && !attentionJobIDs.contains(job.id)
            && !unmountingJobIDs.contains(job.id) {
            try await repository.makeWaitingTransfersRunnable(jobID: job.id)
            requestRun(jobID: job.id)
            await installWatcher(for: job, replace: true)
        }
    }

    /// Called from Disk Arbitration's approval callback. All affected work is
    /// cancelled and awaited so FileHandle defers have run and durable part
    /// checkpoints are closed before the callback approves a normal unmount.
    public func prepareForVolumeUnmount(at volumeURL: URL) async -> Bool {
        let affectedJobs: [SyncJob]
        do {
            affectedJobs = try await repository.jobs().filter {
                Self.localPath($0.localRoot.fallbackPath, isWithin: volumeURL)
            }
        } catch {
            return false
        }
        guard !affectedJobs.isEmpty else { return true }

        unmountingJobIDs.formUnion(affectedJobs.map(\.id))
        var runningTasks: [Task<Void, Never>] = []
        var watchers: [Task<Void, Never>] = []
        for job in affectedJobs {
            pendingWakeJobIDs.remove(job.id)
            if let task = jobTasks.removeValue(forKey: job.id) {
                task.cancel()
                runningTasks.append(task)
            }
            if let watcher = watcherTasks.removeValue(forKey: job.id) {
                watcher.cancel()
                watchers.append(watcher)
            }
        }
        for task in runningTasks { await task.value }
        for watcher in watchers { await watcher.value }

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
        let affectedJobs = try await repository.jobs().filter {
            Self.localPath($0.localRoot.fallbackPath, isWithin: volumeURL)
        }
        for job in affectedJobs {
            unmountingJobIDs.remove(job.id)
            guard !job.isPaused else { continue }
            try await repository.makeWaitingTransfersRunnable(jobID: job.id)
            requestRun(jobID: job.id)
            await installWatcher(for: job, replace: true)
        }
    }

    private func installWatcher(for job: SyncJob, replace: Bool) async {
        guard !removingJobIDs.contains(job.id),
              !unmountingJobIDs.contains(job.id) else { return }
        if replace {
            watcherTasks[job.id]?.cancel()
            watcherTasks[job.id] = nil
        } else if watcherTasks[job.id] != nil {
            return
        }
        guard job.direction == .upload,
              let access = try? await bookmarks.resolve(reference: job.localRoot.bookmarkReference) else { return }
        let root = access.url
        watcherTasks[job.id] = Task { [weak self] in
            for await _ in FileSystemEventMonitor().updates(root: root) {
                guard !Task.isCancelled else { return }
                await self?.requestRun(jobID: job.id)
            }
            _ = access
        }
    }

    private func requestRun(jobID: SyncJobID, allowAttention: Bool = false) {
        guard !removingJobIDs.contains(jobID),
              !unmountingJobIDs.contains(jobID) else { return }
        guard allowAttention || !attentionJobIDs.contains(jobID) else { return }
        if activeJobIDs.contains(jobID) {
            pendingWakeJobIDs.insert(jobID)
        } else {
            schedule(jobID: jobID, immediate: true)
        }
    }

    private func schedule(jobID: SyncJobID, immediate: Bool) {
        guard !removingJobIDs.contains(jobID),
              !unmountingJobIDs.contains(jobID) else { return }
        jobTasks[jobID]?.cancel()
        jobTasks[jobID] = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .seconds(2))
            }
            var transientFailureAttempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.runCycle(jobID: jobID)
                guard !Task.isCancelled else { return }
                if await self.consumePendingWake(jobID: jobID) {
                    transientFailureAttempt = 0
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
                let pollSeconds: TimeInterval = outcome.direction == .download ? 5 * 60 : 30 * 60
                let nextAttempt = try? await self.repository.nextWaitingAttempt(jobID: jobID)
                let retrySeconds = nextAttempt.map { max(1, $0.timeIntervalSinceNow) }
                let interval = Duration.seconds(min(pollSeconds, retrySeconds ?? pollSeconds))
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
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

    private func consumePendingWake(jobID: SyncJobID) -> Bool {
        pendingWakeJobIDs.remove(jobID) != nil
    }

    @discardableResult
    private func runCycle(jobID: SyncJobID) async -> CycleOutcome {
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

            var snapshot = SyncSnapshot(jobID: jobID, phase: .scanning, message: "Checking for changes…")
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

            let localCaseSensitive = job.localRoot.expectedVolume?.isCaseSensitive ?? false
            let store = try await objectStoreFactory.make(connection: connection)
            async let localTask = stageLocalManifest(
                jobID: job.id,
                root: access.url,
                caseSensitive: localCaseSensitive
            )
            async let remoteTask = stageRemoteManifest(
                jobID: job.id,
                store: store,
                prefix: job.remotePrefix,
                caseSensitive: localCaseSensitive
            )
            let (localScan, remoteScan) = try await (localTask, remoteTask)
            var invalidRemoteKeyCount = remoteScan.invalidRemoteKeyCount
            try await repository.pruneBaselinesAbsentFromManifest(
                jobID: job.id,
                side: job.direction == .upload ? .local : .remote,
                generation: job.direction == .upload ? localScan.generation : remoteScan.generation
            )

            let reconciliationPageSize = 512
            var reconciliationCursor: String?
            var alreadyPresentCount = 0
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
                for row in rows {
                    if row.hasRemotePathCollision {
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
                    if let adoption = reconciler.initialAdoptionBaseline(
                        relativePath: row.relativePath,
                        local: row.local,
                        remote: row.remote,
                        existingBaseline: row.baseline
                    ) {
                        adoptions.append(adoption)
                        alreadyPresentCount += 1
                        continue
                    }
                    let remoteKeyOverride: String?
                    if job.direction == .upload, !localCaseSensitive, let remote = row.remote,
                       Reconciler.relativePath(for: remote.key, prefix: job.remotePrefix) != row.relativePath {
                        remoteKeyOverride = remote.key
                    } else {
                        remoteKeyOverride = nil
                    }
                    if let plan = reconciler.transferPlan(
                        direction: job.direction,
                        prefix: job.remotePrefix,
                        relativePath: row.relativePath,
                        local: row.local,
                        remote: row.remote,
                        baseline: row.baseline,
                        remoteKeyOverride: remoteKeyOverride
                    ) {
                        plans.append(plan)
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
                    let pathsWithQueuedWork = Array(Set(obsolete.map(\.relativePath)))
                    if !pathsWithQueuedWork.isEmpty {
                        try await repository.discardTransfers(
                            jobID: job.id,
                            relativePaths: pathsWithQueuedWork
                        )
                    }
                }
                try await repository.enqueueTransfersIfNeeded(plans, jobID: job.id)
                reconciliationCursor = rows.last?.relativePath
                if rows.count < reconciliationPageSize { break }
            }

            let queue = try await repository.activeTransferSummary(jobID: job.id)
            snapshot.phase = queue.count == 0 ? .watching : .transferring
            snapshot.filesTotal = queue.count
            snapshot.bytesTotal = queue.totalBytes
            snapshot.bytesCompleted = queue.completedBytes
            snapshot.sourceFilesFound = job.direction == .upload
                ? localScan.entryCount
                : remoteScan.entryCount
            snapshot.destinationFilesFound = job.direction == .upload
                ? remoteScan.entryCount
                : localScan.entryCount
            snapshot.filesAlreadyPresent = alreadyPresentCount
            snapshot.message = queue.count == 0
                ? "All caught up"
                : "Syncing \(queue.count) item\(queue.count == 1 ? "" : "s")…"
            if invalidRemoteKeyCount > 0 {
                let skipped = "Skipped \(invalidRemoteKeyCount) unsafe object path\(invalidRemoteKeyCount == 1 ? "" : "s")"
                snapshot.message = queue.count == 0 ? skipped : snapshot.message + " \(skipped)."
            }
            try await repository.setSnapshot(snapshot)

            let executor = TransferExecutor(
                repository: repository,
                objectStore: store,
                transferPolicy: transferPolicy
            )
            let maximumParallelFiles = max(1, transferPolicy.maximumConcurrentFiles)
            let transferBatchSize = max(16, maximumParallelFiles * 4)
            let progressRepository = repository
            let permitPool = transferPermitPool
            let progressAccumulator = TransferProgressAccumulator(initialCompleted: queue.completedBytes)
            var shouldStopScheduling = false
            while !shouldStopScheduling {
                try Task.checkCancellation()
                let transfers = try await repository.runnableTransfers(
                    jobID: job.id,
                    limit: transferBatchSize
                )
                guard !transfers.isEmpty else { break }
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
                            snapshot.filesCompleted += 1
                            snapshot.filesAlreadyPresent = (snapshot.filesAlreadyPresent ?? 0) + 1
                            let destinationExisted = attempt.transfer.kind == .upload
                                ? attempt.transfer.remoteSource != nil
                                : attempt.transfer.sourceFingerprint != nil
                            if !destinationExisted {
                                snapshot.destinationFilesFound = (snapshot.destinationFilesFound ?? 0) + 1
                            }
                            // A finished file may have reported less than its
                            // full size, so settle its contribution at the total.
                            _ = await progressAccumulator.update(
                                transferID: attempt.transfer.id,
                                completedBytes: attempt.transfer.totalBytes
                            )
                        case .cancelled:
                            break
                        case .waiting(let blocker, let message):
                            snapshot.blockers.insert(blocker)
                            snapshot.message = message
                            shouldStopScheduling = true
                            group.cancelAll()
                        case .attention(let blocker, let message):
                            snapshot.phase = .attention
                            if let blocker { snapshot.blockers.insert(blocker) }
                            snapshot.message = message
                            shouldStopScheduling = true
                            group.cancelAll()
                        case .superseded(let message):
                            snapshot.message = message
                            // The source or destination changed after this scan.
                            // Reconcile the new version immediately instead of
                            // reporting success until the next polling interval.
                            pendingWakeJobIDs.insert(job.id)
                        }
                        snapshot.bytesCompleted = await progressAccumulator.totalCompleted()
                        try await repository.setSnapshot(snapshot)

                        if !shouldStopScheduling { startNextTransfer() }
                    }
                }
            }

            if snapshot.phase != .attention, snapshot.blockers.isEmpty {
                snapshot.phase = .watching
                snapshot.currentRelativePath = nil
                snapshot.filesCompleted = 0
                let remaining = try await repository.activeTransferSummary(jobID: job.id)
                snapshot.filesTotal = remaining.count
                snapshot.bytesCompleted = remaining.completedBytes
                snapshot.bytesTotal = remaining.totalBytes
                if remaining.count == 0 {
                    snapshot.lastSuccessfulSync = Date()
                    snapshot.message = invalidRemoteKeyCount == 0
                        ? "All caught up"
                        : "Skipped \(invalidRemoteKeyCount) unsafe object path\(invalidRemoteKeyCount == 1 ? "" : "s")"
                } else {
                    snapshot.message = "Waiting to retry \(remaining.count) item\(remaining.count == 1 ? "" : "s")…"
                }
                try await repository.setSnapshot(snapshot)
            }
            return CycleOutcome(
                direction: direction,
                disposition: snapshot.phase == .attention ? .attention : .normal
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
                attentionBlockers = []
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

    private func stageLocalManifest(
        jobID: SyncJobID,
        root: URL,
        caseSensitive: Bool
    ) async throws -> ManifestScanResult {
        let generation = try await repository.nextManifestGeneration(jobID: jobID, side: .local)
        var batch: [FileFingerprint] = []
        var entryCount = 0
        batch.reserveCapacity(512)
        for try await file in scanner.files(at: root) {
            try Task.checkCancellation()
            batch.append(file)
            entryCount += 1
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
        return ManifestScanResult(
            generation: generation,
            invalidRemoteKeyCount: 0,
            entryCount: entryCount
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
        caseSensitive: Bool
    ) async throws -> ManifestScanResult {
        let generation = try await repository.nextManifestGeneration(jobID: jobID, side: .remote)
        var batch: [RemoteManifestRecord] = []
        batch.reserveCapacity(512)
        var invalidRemoteKeyCount = 0
        var entryCount = 0
        var token: String?
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
                if Reconciler.isReservedInternalPath(relativePath) { continue }
                guard Reconciler.isSafeRelativePath(relativePath) else {
                    invalidRemoteKeyCount += 1
                    continue
                }
                entryCount += 1
                batch.append(
                    RemoteManifestRecord(
                        relativePath: relativePath,
                        canonicalPath: caseSensitive
                            ? relativePath
                            : Reconciler.canonicalLocalPath(relativePath),
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
        } while token != nil
        if !batch.isEmpty {
            try await repository.upsertRemoteManifestEntries(
                batch,
                jobID: jobID,
                generation: generation
            )
        }
        try await repository.finishManifestScan(jobID: jobID, side: .remote, generation: generation)
        if !caseSensitive {
            invalidRemoteKeyCount += try await repository.removeCaseCollidingRemoteManifestEntries(
                jobID: jobID,
                generation: generation
            )
        }
        return ManifestScanResult(
            generation: generation,
            invalidRemoteKeyCount: invalidRemoteKeyCount,
            entryCount: entryCount
        )
    }

    private nonisolated static func removeDownloadPartials(
        for transfers: [TransferRecord],
        beneath root: URL
    ) {
        let partialDirectory = root
            .appendingPathComponent(ReservedName.partialsDirectory, isDirectory: true)
            .standardizedFileURL
        // Never follow a replaced internal directory outside the selected
        // root. TransferExecutor applies the same defensive rule when writing.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: partialDirectory.path)) != nil {
            return
        }
        for transfer in transfers where transfer.kind == .download {
            let partial = partialDirectory
                .appendingPathComponent(transfer.id.description + ".partial", isDirectory: false)
                .standardizedFileURL
            guard partial.deletingLastPathComponent() == partialDirectory,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: partial.path)) == nil else {
                continue
            }
            try? FileManager.default.removeItem(at: partial)
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

    public var errorDescription: String? {
        switch self {
        case .missingConnection: "The S3 connection for this sync no longer exists."
        }
    }
}
