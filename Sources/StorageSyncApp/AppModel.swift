import AppKit
import CryptoKit
import Foundation
import StorageSyncCore
import StorageSyncShared
import StorageSyncSystem
import ServiceManagement

private struct PendingTransferProgress {
    var bytesSent: Int64
    var retryCount: Int?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var jobs: [SyncJob] = []
    @Published private(set) var connections: [ConnectionID: S3Connection] = [:]
    @Published private(set) var snapshots: [SyncJobID: SyncSnapshot] = [:]
    /// Saved provider keys, described without their secrets. Ordered by name so
    /// the sidebar and every menu built from it agree.
    @Published private(set) var credentials: [StoredCredential] = []
    /// The last complete storage balance seen for each sync, so an unplugged
    /// drive dims the picture instead of erasing it. See `BalanceReading`.
    @Published private(set) var lastKnownBalances: [SyncJobID: StorageBalance] = [:]
    @Published var selection: ManagerSelection? {
        didSet {
            guard selection != oldValue else { return }
            selectionActivityTask?.cancel()
            transferActivityItems = []
            transferActivityCounts = TransferActivityCounts()
            transferActivityRevision = 0
            transferActivityNextCursor = nil
            transferActivityError = nil
            requiredActivityRevision = 0
            pendingTransferProgress = [:]
            guard case .sync(let jobID) = selection else { return }
            selectionActivityTask = Task { [weak self] in
                await self?.loadTransferActivity(jobID: jobID, reset: true)
            }
        }
    }
    @Published var isCreatingSync = false
    @Published var credentialsJob: SyncJob?
    @Published var credentialEditor: CredentialEditorRequest?
    @Published var credentialPendingRemoval: StoredCredential?
    /// Which saved credentials the next Create Sync sheet should open on.
    @Published var newSyncCredential: CredentialID?
    @Published var jobPendingRemoval: SyncJob?
    @Published var errorMessage: String?
    @Published private(set) var isAgentAvailable = false
    /// Manual checks acknowledge the click locally instead of waiting for the
    /// agent's committed scanning snapshot. A fast no-change scan can otherwise
    /// begin and finish between UI renders, making a working button look inert.
    @Published private var manualCheckJobIDs: Set<SyncJobID> = []
    /// True only while macOS is holding the agent behind an explicit user
    /// approval in Login Items. Nothing else the app can do will start it.
    @Published private(set) var needsLoginItemsApproval = false
    @Published private(set) var transferActivityItems: [TransferActivityItem] = []
    @Published private(set) var transferActivityCounts = TransferActivityCounts()
    @Published private(set) var transferActivityRevision: Int64 = 0
    @Published private(set) var transferActivityNextCursor: TransferActivityCursor?
    @Published private(set) var isLoadingTransferActivity = false
    @Published private(set) var transferActivityError: String?
    @Published var transferActivityFilter: TransferActivityFilter = .all {
        didSet {
            guard transferActivityFilter != oldValue,
                  case .sync(let jobID) = selection else { return }
            selectionActivityTask?.cancel()
            selectionActivityTask = Task { [weak self] in
                await self?.loadTransferActivity(jobID: jobID, reset: true)
            }
        }
    }

    private let client = AgentClient()
    /// Not published: it changes on every state read and only matters once a
    /// reading has gone stale, so republishing the whole model for it is waste.
    private var balancesSeenAt: [SyncJobID: Date] = [:]
    private var initialRefreshTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var selectionActivityTask: Task<Void, Never>?
    private var stateRefreshTask: Task<Void, Never>?
    private var stateEventGeneration: UInt64 = 0
    private var requiredActivityRevision: Int64 = 0
    private var pendingTransferProgress: [TransferID: PendingTransferProgress] = [:]
    /// When the agent first stopped answering, so a momentary gap is not
    /// mistaken for a broken registration.
    private var unreachableSince: Date?

    init() {
        ActiveAppModel.current = self
        client.onTransferActivityChange { [weak self] jobID, revision in
            Task { @MainActor [weak self] in
                await self?.transferActivityDidChange(jobID: jobID, revision: revision)
            }
        }
        client.onTransferProgressChange { [weak self] update in
            Task { @MainActor [weak self] in
                self?.transferProgressDidChange(update)
            }
        }
        client.onStateChange { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleStateRefresh()
            }
        }
        client.onConnectionLost { [weak self] in
            Task { @MainActor [weak self] in
                self?.markAgentUnavailable()
            }
        }
        registrationTask = Task { [weak self] in
            await self?.maintainBackgroundServices()
        }
        initialRefreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    deinit {
        registrationTask?.cancel()
        initialRefreshTask?.cancel()
        selectionActivityTask?.cancel()
        stateRefreshTask?.cancel()
        client.onTransferActivityChange(nil)
        client.onTransferProgressChange(nil)
        client.onStateChange(nil)
        client.onConnectionLost(nil)
    }

    var overallStatus: OverallStatus {
        if !isAgentAvailable { return .agentUnavailable }
        if jobs.isEmpty { return .noSyncs }
        let states = jobs.map { SyncStatus(job: $0, snapshot: snapshot(for: $0.id)) }
        if states.contains(where: { $0.tone == .attention }) { return .attention }
        if states.contains(where: { $0.tone == .working }) { return .working }
        if states.contains(where: { $0.tone == .waiting }) { return .waiting }
        return .caughtUp
    }

    var menuBarSymbol: String { overallStatus.menuBarSymbol }

    var selectedJob: SyncJob? {
        guard case .sync(let id) = selection else { return nil }
        return jobs.first { $0.id == id }
    }

    var selectedCredential: StoredCredential? {
        guard case .credential(let id) = selection else { return nil }
        return credentials.first { $0.id == id }
    }

    /// The syncs that would stop working if these keys stopped working. Joined
    /// on the Keychain reference rather than on a stored credential ID, because
    /// the reference is what the engine actually resolves — a second field
    /// could disagree with it and make this list a comfortable lie.
    func syncsUsing(_ credential: StoredCredential) -> [SyncJob] {
        jobs.filter { connections[$0.connectionID]?.credentialReference == credential.keychainReference }
    }

    func credential(for job: SyncJob) -> StoredCredential? {
        guard let reference = connections[job.connectionID]?.credentialReference else { return nil }
        return credentials.first { $0.keychainReference == reference }
    }

    func snapshot(for jobID: SyncJobID) -> SyncSnapshot {
        var snapshot = snapshots[jobID]
            ?? SyncSnapshot(jobID: jobID, phase: .idle, message: "Starting…")
        if manualCheckJobIDs.contains(jobID) {
            snapshot.isRescanPending = true
            // During a transfer the click queues a bounded rescan; it must not
            // replace the truthful "Syncing…" headline. A dormant job can show
            // the scan immediately because no copy is already in progress.
            if snapshot.phase != .transferring && snapshot.phase != .verifying {
                snapshot.phase = .scanning
                snapshot.blockers = []
                snapshot.currentRelativePath = nil
                snapshot.message = "Checking for changes…"
            }
        }
        return snapshot
    }

    func isCheckingForChanges(_ jobID: SyncJobID) -> Bool {
        manualCheckJobIDs.contains(jobID)
            || snapshots[jobID]?.isRescanPending == true
            || snapshots[jobID]?.phase == .scanning
    }

    /// Transfers may accept a bounded rescan request. Only a paused sync, an
    /// active scan, or a request already acknowledged by the agent disables
    /// the action, so a long backlog never leaves Sync Now permanently grey.
    func canSyncNow(_ job: SyncJob) -> Bool {
        guard !job.isPaused,
              !manualCheckJobIDs.contains(job.id),
              snapshots[job.id]?.isRescanPending != true else { return false }
        return snapshots[job.id]?.phase != .scanning
    }

    func status(for job: SyncJob) -> SyncStatus {
        SyncStatus(job: job, snapshot: snapshot(for: job.id))
    }

    /// The balance to draw for a sync: the live one when the latest agent event
    /// carried the numbers, otherwise the last one that did.
    func balanceReading(for job: SyncJob) -> BalanceReading? {
        if let balance = StorageBalance(snapshot: snapshot(for: job.id), direction: job.direction) {
            return BalanceReading(balance: balance, isCurrent: true, asOf: balancesSeenAt[job.id])
        }
        guard let remembered = lastKnownBalances[job.id] else { return nil }
        return BalanceReading(balance: remembered, isCurrent: false, asOf: balancesSeenAt[job.id])
    }

    func connection(for job: SyncJob) -> S3Connection? {
        connections[job.connectionID]
    }

    /// Selection and disclosure never start a sync scan. This reads only the
    /// compact activity ledger, and subsequent reloads are caused solely by a
    /// newer committed revision announced by the agent.
    func loadTransferActivity(jobID: SyncJobID, reset: Bool) async {
        guard case .sync(let selectedID) = selection, selectedID == jobID else { return }
        if isLoadingTransferActivity && !reset { return }
        isLoadingTransferActivity = true
        if reset {
            transferActivityError = nil
        }
        defer { isLoadingTransferActivity = false }

        let cursor = reset ? nil : transferActivityNextCursor
        do {
            let page = try await client.perform(
                .transferActivityPage,
                payload: JSONEncoder().encode(
                    TransferActivityPageRequest(
                        jobID: jobID,
                        filter: transferActivityFilter,
                        cursor: cursor,
                        limit: 150
                    )
                ),
                response: TransferActivityPage.self
            )
            guard !Task.isCancelled,
                  case .sync(let selectedID) = selection,
                  selectedID == jobID else { return }

            // A page from an older batch/revision can arrive after a push. It
            // is never rendered, even briefly; ask for the committed revision
            // the callback named instead.
            if page.revision < requiredActivityRevision {
                selectionActivityTask = Task { [weak self] in
                    await self?.loadTransferActivity(jobID: jobID, reset: true)
                }
                return
            }

            if !reset, page.revision != transferActivityRevision {
                selectionActivityTask = Task { [weak self] in
                    await self?.loadTransferActivity(jobID: jobID, reset: true)
                }
                return
            }

            transferActivityRevision = page.revision
            transferActivityCounts = page.counts
            transferActivityNextCursor = page.nextCursor
            let loadedItems = reset
                ? page.items
                : Self.mergingActivityRows(transferActivityItems, page.items)
            transferActivityItems = applyingPendingProgress(to: loadedItems)
            transferActivityError = nil
        } catch is CancellationError {
            return
        } catch {
            guard case .sync(let selectedID) = selection, selectedID == jobID else { return }
            transferActivityError = error.localizedDescription
        }
    }

    func loadMoreTransferActivity() {
        guard case .sync(let jobID) = selection,
              transferActivityNextCursor != nil,
              !isLoadingTransferActivity else { return }
        selectionActivityTask = Task { [weak self] in
            await self?.loadTransferActivity(jobID: jobID, reset: false)
        }
    }

    private func transferActivityDidChange(jobID: SyncJobID, revision: Int64) async {
        guard case .sync(let selectedID) = selection, selectedID == jobID else { return }
        requiredActivityRevision = max(requiredActivityRevision, revision)
        guard revision > transferActivityRevision else { return }
        selectionActivityTask?.cancel()
        selectionActivityTask = Task { [weak self] in
            await self?.loadTransferActivity(jobID: jobID, reset: true)
        }
    }

    private func transferProgressDidChange(_ update: TransferProgressUpdate) {
        guard case .sync(let selectedID) = selection,
              selectedID == update.jobID else { return }
        let sent = max(0, update.bytesSent)
        guard let index = transferActivityItems.firstIndex(where: { $0.id == update.transferID }) else {
            let previous = pendingTransferProgress[update.transferID]
            pendingTransferProgress[update.transferID] = PendingTransferProgress(
                bytesSent: max(sent, previous?.bytesSent ?? 0),
                retryCount: previous?.retryCount
            )
            return
        }
        guard transferActivityItems[index].status == .running,
              transferActivityItems[index].kind == .upload else {
            pendingTransferProgress.removeValue(forKey: update.transferID)
            return
        }

        let retryCount = transferActivityItems[index].retryCount
        let previous = pendingTransferProgress[update.transferID]
        let belongsToCurrentAttempt = previous?.retryCount == nil
            || previous?.retryCount == retryCount
        let visibleSent = belongsToCurrentAttempt
            ? max(sent, previous?.bytesSent ?? 0)
            : sent
        pendingTransferProgress[update.transferID] = PendingTransferProgress(
            bytesSent: visibleSent,
            retryCount: retryCount
        )
        var item = transferActivityItems[index]
        item.bytesSent = min(item.totalBytes, max(item.completedBytes, visibleSent))
        transferActivityItems[index] = item
    }

    private func applyingPendingProgress(
        to items: [TransferActivityItem]
    ) -> [TransferActivityItem] {
        items.map { item in
            guard item.status == .running,
                  item.kind == .upload,
                  var pending = pendingTransferProgress[item.id] else {
                if item.status != .running {
                    pendingTransferProgress.removeValue(forKey: item.id)
                }
                return item
            }
            guard pending.retryCount == nil || pending.retryCount == item.retryCount else {
                // A new retry is a new network attempt. Its byte counter must
                // never inherit bytes merely sent by the previous request.
                pendingTransferProgress.removeValue(forKey: item.id)
                return item
            }
            pending.retryCount = item.retryCount
            pending.bytesSent = max(item.completedBytes, pending.bytesSent)
            pendingTransferProgress[item.id] = pending
            var updated = item
            updated.bytesSent = min(item.totalBytes, pending.bytesSent)
            return updated
        }
    }

    private static func mergingActivityRows(
        _ existing: [TransferActivityItem],
        _ next: [TransferActivityItem]
    ) -> [TransferActivityItem] {
        let known = Set(existing.map(\.id))
        return existing + next.filter { !known.contains($0.id) }
    }

    /// - Parameter credential: Which saved credentials the sheet should start
    ///   on. Passed when the sheet was opened from a credential, so "use these
    ///   for another sync" is one click rather than a re-selection.
    func beginCreatingSync(using credential: StoredCredential? = nil) {
        newSyncCredential = credential?.id
        isCreatingSync = true
    }

    /// The saved path can be stale for a drive that is not mounted, so this
    /// opens the folder only when it is actually there.
    func revealInFinder(_ job: SyncJob) {
        let path = job.localRoot.fallbackPath
        guard FileManager.default.fileExists(atPath: path) else {
            errorMessage = "“\(job.localRoot.displayName)” isn’t available right now. Connect the drive and try again."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func canRevealInFinder(_ item: TransferActivityItem, for job: SyncJob) -> Bool {
        guard let url = try? SafePath.resolve(
            item.relativePath,
            beneath: URL(fileURLWithPath: job.localRoot.fallbackPath)
        ) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func revealInFinder(_ item: TransferActivityItem, for job: SyncJob) {
        guard let url = try? SafePath.resolve(
            item.relativePath,
            beneath: URL(fileURLWithPath: job.localRoot.fallbackPath)
        ), FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "“\(item.relativePath)” isn’t available on this Mac right now."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyRelativePath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func refresh() async {
        do {
            async let jobsRequest: [SyncJob] = client.perform(.jobs, response: [SyncJob].self)
            async let snapshotsRequest: [SyncSnapshot] = client.perform(.snapshots, response: [SyncSnapshot].self)
            async let connectionsRequest: [S3Connection] = client.perform(.connections, response: [S3Connection].self)
            let (loadedJobs, loadedSnapshots, loadedConnections) = try await (
                jobsRequest,
                snapshotsRequest,
                connectionsRequest
            )
            jobs = loadedJobs.sorted { $0.createdAt < $1.createdAt }
            snapshots = Dictionary(uniqueKeysWithValues: loadedSnapshots.map { ($0.jobID, $0) })
            connections = Dictionary(uniqueKeysWithValues: loadedConnections.map { ($0.id, $0) })
            // Deliberately not part of the request above. Replacing an app
            // bundle leaves the previous agent running until launchd restarts
            // it, and that older agent does not know this command. Losing the
            // credentials list for those few seconds is a dimmed menu; losing
            // the whole refresh would be an app that says all your syncs are
            // gone.
            if let loadedCredentials = try? await client.perform(.credentials, response: [StoredCredential].self) {
                credentials = loadedCredentials.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
            rememberBalances()
            isAgentAvailable = true
            unreachableSince = nil
            reconcileSelection()
        } catch {
            isAgentAvailable = false
            if unreachableSince == nil { unreachableSince = Date() }
        }
    }

    /// Coalesces bursts of committed snapshot updates (for example several
    /// parallel files finishing together) without using a timer to discover
    /// state. Every refresh is downstream of an actual agent event, and an
    /// event that arrives during the read schedules one more authoritative
    /// read before the task exits.
    private func scheduleStateRefresh() {
        stateEventGeneration &+= 1
        guard stateRefreshTask == nil else { return }
        stateRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let generation = self.stateEventGeneration
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { break }
                await self.refresh()
                if generation == self.stateEventGeneration { break }
            }
            self.stateRefreshTask = nil
        }
    }

    private func markAgentUnavailable() {
        isAgentAvailable = false
        if unreachableSince == nil { unreachableSince = Date() }
    }

    /// Keeps the sidebar pointing at something that still exists, without ever
    /// taking a live selection away from the user: a chosen credential is not
    /// replaced by the first sync just because syncs sort above it.
    private func reconcileSelection() {
        switch selection {
        case .sync(let id) where jobs.contains(where: { $0.id == id }):
            return
        case .credential(let id) where credentials.contains(where: { $0.id == id }):
            return
        default:
            selection = jobs.first.map { .sync($0.id) } ?? credentials.first.map { .credential($0.id) }
        }
    }

    /// Keeps the newest complete picture of every sync, and drops the ones
    /// whose job has been removed so a long-running app cannot accumulate them.
    private func rememberBalances() {
        let now = Date()
        for job in jobs {
            guard let balance = StorageBalance(
                snapshot: snapshot(for: job.id),
                direction: job.direction
            ) else { continue }
            balancesSeenAt[job.id] = now
            if lastKnownBalances[job.id] != balance {
                lastKnownBalances[job.id] = balance
            }
        }
        let liveIDs = Set(jobs.map(\.id))
        balancesSeenAt = balancesSeenAt.filter { liveIDs.contains($0.key) }
        if lastKnownBalances.contains(where: { !liveIDs.contains($0.key) }) {
            lastKnownBalances = lastKnownBalances.filter { liveIDs.contains($0.key) }
        }
    }

    func createSync(_ draft: SyncDraft) async throws {
        guard let folderURL = draft.folderURL else { throw SyncDraftError.missingFolder }
        let endpointText = draft.provider == .amazon ? Self.amazonEndpoint(region: draft.region) : draft.endpoint
        guard let endpoint = URL(string: endpointText),
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.scheme == "https" || (endpoint.scheme == "http" && endpoint.isLoopbackHost) else {
            throw SyncDraftError.invalidEndpoint
        }

        // Keys the user is typing in now, or nothing at all when they picked
        // credentials that are already saved. In that case the secret stays in
        // the Keychain throughout: the agent resolves it from the reference.
        let newKeys: S3Credentials?
        var credentialReference: String
        switch draft.credentialChoice {
        case .new:
            newKeys = S3Credentials(
                accessKeyID: draft.accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
                secretAccessKey: draft.secretKey,
                sessionToken: draft.sessionToken.nilIfBlank
            )
            credentialReference = ""
        case .saved(let id):
            guard let credential = credentials.first(where: { $0.id == id }) else {
                throw SyncDraftError.missingCredential
            }
            newKeys = nil
            credentialReference = credential.keychainReference
        }

        let connectionID = ConnectionID()
        var connection = S3Connection(
            id: connectionID,
            name: draft.provider == .amazon ? "Amazon S3" : endpoint.host ?? "S3 Storage",
            endpoint: endpoint,
            region: draft.region,
            bucket: draft.bucket,
            addressingStyle: draft.provider == .amazon && !draft.bucket.contains(".") ? .virtualHost : .path,
            credentialReference: credentialReference
        )
        // Nothing durable exists yet, so a wrong key or bucket costs only this
        // request. New keys are checked as typed; saved ones are checked
        // against this bucket, which is not the same question as whether they
        // work for the sync they came from.
        try await client.perform(
            .testConnection,
            payload: JSONEncoder().encode(
                ConnectionCredentialPayload(
                    connection: connection,
                    credentials: newKeys,
                    remotePrefix: SyncJob.normalizedPrefix(draft.prefix)
                )
            )
        )

        let locations = try RuntimeLocations.standard()
        try locations.prepare()
        let bookmarkStore = try BookmarkStore(directory: locations.bookmarks)
        let bookmarkReference = try await bookmarkStore.create(for: folderURL)
        let volume = try VolumeInspector().identity(for: folderURL, createMarkerIfNeeded: true)

        if let newKeys {
            let saved = try await performSaveCredential(
                id: nil,
                name: draft.effectiveCredentialName,
                keys: newKeys
            )
            connection.credentialReference = saved.keychainReference
        }

        try await client.perform(.saveConnection, payload: JSONEncoder().encode(connection))
        let job = SyncJob(
            name: draft.name.nilIfBlank ?? folderURL.lastPathComponent,
            direction: draft.direction,
            localRoot: LocalRoot(
                displayName: folderURL.lastPathComponent,
                fallbackPath: folderURL.path,
                bookmarkReference: bookmarkReference,
                expectedVolume: volume
            ),
            connectionID: connectionID,
            remotePrefix: draft.prefix
        )
        try await client.perform(.saveJob, payload: JSONEncoder().encode(job))
        selection = .sync(job.id)
        isCreatingSync = false
        await refresh()
    }

    private static func amazonEndpoint(region: String) -> String {
        let normalized = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let domain = normalized.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        return "https://s3.\(normalized).\(domain)"
    }

    func pause(_ job: SyncJob) async {
        await sendJobCommand(.pauseJob, jobID: job.id)
    }

    func resume(_ job: SyncJob) async {
        await sendJobCommand(.resumeJob, jobID: job.id)
    }

    func syncNow(_ job: SyncJob) async {
        guard canSyncNow(job) else { return }

        manualCheckJobIDs.insert(job.id)
        let clock = ContinuousClock()
        let feedbackStartedAt = clock.now
        defer { manualCheckJobIDs.remove(job.id) }

        do {
            try await client.perform(
                .syncNow,
                payload: JSONEncoder().encode(JobCommandPayload(jobID: job.id))
            )

            // Keep a successful acknowledgement visible long enough to be
            // perceived even when there is nothing to copy. Longer scans stay
            // visible through the real snapshot returned by the agent.
            let minimumFeedback = Duration.milliseconds(800)
            let elapsed = feedbackStartedAt.duration(to: clock.now)
            if elapsed < minimumFeedback {
                try? await Task.sleep(for: minimumFeedback - elapsed)
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestRemoval(of job: SyncJob) {
        jobPendingRemoval = job
    }

    func cancelRemoval() {
        jobPendingRemoval = nil
    }

    func confirmRemoval(of job: SyncJob) async {
        jobPendingRemoval = nil
        await sendJobCommand(.removeJob, jobID: job.id)
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Stops the background agent so quitting StorageSync closes everything
    /// rather than leaving the engine running.
    ///
    /// Event refreshes and registration are cancelled *first*. Both would otherwise
    /// undo the shutdown: any request over XPC makes launchd start the agent
    /// again on demand, and the maintenance loop would re-register it.
    func shutdownAgentForQuit() async {
        initialRefreshTask?.cancel()
        stateRefreshTask?.cancel()
        registrationTask?.cancel()
        initialRefreshTask = nil
        stateRefreshTask = nil
        registrationTask = nil

        let client = self.client
        // The command is sent even when the agent looks unreachable, because
        // "unreachable" can just mean a slow request while it is busy transferring,
        // and leaving it running is the one outcome quitting must not produce.
        // The wait is shortened in that case so a genuinely absent agent does
        // not stall the quit.
        let limit: Duration = isAgentAvailable ? .seconds(3) : .seconds(1)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await client.perform(.shutdown) }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
        client.invalidate()
        isAgentAvailable = false
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Credentials

    func beginCreatingCredential() {
        credentialEditor = .create
    }

    func beginEditingCredential(_ credential: StoredCredential) {
        credentialEditor = .edit(credential)
    }

    /// Saves a credential from the Credentials list: a new set of keys, a
    /// rename, or a replacement of the keys inside an existing one.
    ///
    /// Replacement keys are tried against a bucket one of the dependent syncs
    /// already uses, so the same wrong-key mistake cannot be committed to
    /// several syncs at once. A brand-new credential has no bucket to try yet
    /// and is saved as given; the sync it is later attached to checks it then.
    func saveCredential(id: CredentialID?, name: String, keys: S3Credentials?) async throws {
        if let keys, let id,
           let credential = credentials.first(where: { $0.id == id }),
           let (connection, prefix) = verificationTarget(for: credential) {
            try await client.perform(
                .testConnection,
                payload: JSONEncoder().encode(
                    ConnectionCredentialPayload(
                        connection: connection,
                        credentials: keys,
                        remotePrefix: prefix
                    )
                )
            )
        }
        let saved = try await performSaveCredential(id: id, name: name, keys: keys)
        credentialEditor = nil
        selection = .credential(saved.id)
        await refresh()
    }

    func requestRemoval(of credential: StoredCredential) {
        credentialPendingRemoval = credential
    }

    func cancelCredentialRemoval() {
        credentialPendingRemoval = nil
    }

    func confirmRemoval(of credential: StoredCredential) async {
        credentialPendingRemoval = nil
        do {
            try await client.perform(
                .removeCredential,
                payload: JSONEncoder().encode(CredentialCommandPayload(credentialID: credential.id))
            )
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Points one sync at a set of credentials: an existing saved set, or a new
    /// one created here. Either way the keys are proved against this sync's own
    /// bucket before the sync is switched over, so a recovery attempt cannot
    /// quietly replace one broken credential with another.
    func updateCredentials(
        for job: SyncJob,
        choice: CredentialChoice,
        name: String,
        keys: S3Credentials?
    ) async throws {
        guard var connection = connections[job.connectionID] else {
            throw CredentialUpdateError.missingConnection
        }

        let reference: String
        switch choice {
        case .new:
            guard let keys else { throw CredentialUpdateError.missingKeys }
            try await test(connection: connection, credentials: keys, prefix: job.remotePrefix)
            reference = try await performSaveCredential(id: nil, name: name, keys: keys).keychainReference
        case .saved(let id):
            guard let credential = credentials.first(where: { $0.id == id }) else {
                throw CredentialUpdateError.missingCredential
            }
            var candidate = connection
            candidate.credentialReference = credential.keychainReference
            // With keys in hand the test uses those; without, it makes the
            // agent resolve the saved ones from the Keychain — which is also
            // the only way to find out whether they still work here.
            try await test(connection: candidate, credentials: keys, prefix: job.remotePrefix)
            if let keys {
                _ = try await performSaveCredential(id: id, name: credential.name, keys: keys)
            }
            reference = credential.keychainReference
        }

        connection.credentialReference = reference
        try await client.perform(.saveConnection, payload: JSONEncoder().encode(connection))
        credentialsJob = nil
        await refresh()
    }

    private func test(connection: S3Connection, credentials: S3Credentials?, prefix: String) async throws {
        try await client.perform(
            .testConnection,
            payload: JSONEncoder().encode(
                ConnectionCredentialPayload(
                    connection: connection,
                    credentials: credentials,
                    remotePrefix: prefix
                )
            )
        )
    }

    private func performSaveCredential(
        id: CredentialID?,
        name: String,
        keys: S3Credentials?
    ) async throws -> StoredCredential {
        try await client.perform(
            .saveCredential,
            payload: JSONEncoder().encode(SaveCredentialPayload(id: id, name: name, credentials: keys)),
            response: StoredCredential.self
        )
    }

    /// A bucket these credentials are already trusted with, for checking a
    /// replacement against something real.
    private func verificationTarget(for credential: StoredCredential) -> (S3Connection, String)? {
        for job in syncsUsing(credential) {
            guard let connection = connections[job.connectionID] else { continue }
            return (connection, job.remotePrefix)
        }
        return nil
    }

    private func sendJobCommand(_ kind: AgentCommandKind, jobID: SyncJobID) async {
        do {
            try await client.perform(kind, payload: JSONEncoder().encode(JobCommandPayload(jobID: jobID)))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Background agent lifecycle

    private static let agentPlistName = "app.photosync.agent.plist"
    private static let agentStampKey = "RegisteredAgentFingerprint"

    /// launchd stores the agent's program path and a code requirement taken from
    /// the bundle that registered it. Moving the app, replacing it with a new
    /// build, or restoring it from a backup leaves that record pointing at
    /// something launchd will refuse to spawn, and the agent then silently never
    /// runs again. So registration is not a one-shot launch step: the app keeps
    /// checking that the agent actually answers and re-registers it when it does
    /// not.
    private func maintainBackgroundServices() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        await synchronizeBackgroundServices(force: false)

        // Re-registering restarts the agent, which interrupts whatever it is
        // transferring, so healing waits until the agent has been unreachable
        // long enough to rule out a restart or a slow first connection, and
        // then backs off.
        var delay = Duration.seconds(10)
        while !Task.isCancelled {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }

            let unreachableFor = unreachableSince.map { Date().timeIntervalSince($0) } ?? 0
            if !isAgentAvailable {
                // There is no normal-state polling. This retry runs only after
                // XPC is actually unavailable and is what reconnects to an
                // agent that launchd has restarted.
                await refresh()
            }
            guard !isAgentAvailable, unreachableFor >= 30 else {
                delay = .seconds(10)
                continue
            }
            // An agent held for approval will not start however often it is
            // re-registered, and retrying would churn the user's Login Items.
            guard !needsLoginItemsApproval else {
                delay = .seconds(60)
                continue
            }
            await synchronizeBackgroundServices(force: true)
            delay = min(max(delay * 2, .seconds(30)), .seconds(600))
        }
    }

    private func synchronizeBackgroundServices(force: Bool) async {
        let agent = SMAppService.agent(plistName: Self.agentPlistName)
        let stamp = backgroundAgentStamp()
        let isCurrentRegistration = stamp != nil
            && stamp == UserDefaults.standard.string(forKey: Self.agentStampKey)

        switch agent.status {
        case .enabled where isCurrentRegistration && !force:
            needsLoginItemsApproval = false
        case .requiresApproval where !force:
            needsLoginItemsApproval = true
        default:
            do {
                try await reinstall(agent)
                UserDefaults.standard.set(stamp, forKey: Self.agentStampKey)
                needsLoginItemsApproval = agent.status == .requiresApproval
                // The cached connection was made to a service that launchd has
                // now replaced, so the recovery read opens a fresh one.
                client.invalidate()
                // Give the replacement agent the full grace period before it is
                // judged unreachable again.
                unreachableSince = Date()
                await refresh()
            } catch {
                // A failure here is reported by the ordinary "background agent
                // not running" status. An alert on every launch would be noise
                // the user cannot act on, and the retry loop may fix it anyway.
                UserDefaults.standard.removeObject(forKey: Self.agentStampKey)
                needsLoginItemsApproval = agent.status == .requiresApproval
            }
        }

        registerLaunchAtLogin()
    }

    /// Unregistering first is what refreshes launchd's stored program path and
    /// code requirement. Registering over a stale record keeps the stale one.
    private func reinstall(_ agent: SMAppService) async throws {
        if agent.status != .notRegistered {
            try? await unregisterAndWait(agent)
        }
        try agent.register()
    }

    private func registerLaunchAtLogin() {
        let mainApp = SMAppService.mainApp
        guard mainApp.status == .notRegistered || mainApp.status == .notFound else { return }
        // Opening at login is a convenience, not a requirement: the agent is a
        // separate login item and keeps syncing without the menu bar app.
        try? mainApp.register()
    }

    private func unregisterAndWait(_ service: SMAppService) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Identifies one exact installation: the helper, the app itself, and where
    /// the bundle sits. Any of the three changing invalidates the record
    /// launchd holds. The app's own executable counts because launchd checks
    /// the agent against a requirement taken from the app that registered it,
    /// and because this app's Info.plist — including its version — is bound
    /// into that executable's signature.
    private func backgroundAgentStamp() -> String? {
        let bundleURL = Bundle.main.bundleURL
        let helperURL = bundleURL.appendingPathComponent("Contents/Helpers/StorageSyncAgent", isDirectory: false)
        // The plist is included because editing it alone — changing KeepAlive
        // or RunAtLoad, say — changes nothing launchd already holds until the
        // agent is registered again.
        let plistURL = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchAgents/\(Self.agentPlistName)",
            isDirectory: false
        )
        guard let helper = try? Data(contentsOf: helperURL),
              let plist = try? Data(contentsOf: plistURL),
              let executableURL = Bundle.main.executableURL,
              let executable = try? Data(contentsOf: executableURL) else { return nil }
        let digest = (helper + plist + executable).sha256Hexadecimal
        return "v5:\(digest):\(bundleURL.resolvingSymlinksInPath().standardizedFileURL.path)"
    }
}

/// Quitting is handled by the application delegate, which SwiftUI does not
/// route through the scene graph. This hands it the live model without making
/// the shutdown depend on whether a scene happened to appear first.
@MainActor
enum ActiveAppModel {
    static weak var current: AppModel?
}

/// What the manager window's sidebar is showing. Syncs and credentials are
/// different kinds of thing in one list, so the selection has to say which.
enum ManagerSelection: Hashable {
    case sync(SyncJobID)
    case credential(CredentialID)
}

/// Which credentials a sync should use: ones already saved, or ones being
/// typed in right now.
enum CredentialChoice: Hashable {
    case saved(CredentialID)
    case new
}

enum CredentialEditorRequest: Identifiable, Hashable {
    case create
    case edit(StoredCredential)

    var id: String {
        switch self {
        case .create: "new"
        case .edit(let credential): credential.id.description
        }
    }

    var credential: StoredCredential? {
        switch self {
        case .create: nil
        case .edit(let credential): credential
        }
    }
}

enum StorageProvider: String, CaseIterable, Identifiable {
    case amazon = "Amazon S3"
    case compatible = "Other S3-compatible"
    var id: String { rawValue }
}

struct SyncDraft {
    /// Left blank on purpose. An empty name takes the chosen folder's name,
    /// which is what people expect and one less field to fill in.
    var name = ""
    var provider: StorageProvider = .amazon
    var endpoint = "https://s3.amazonaws.com"
    var region = "us-east-1"
    var bucket = ""
    var prefix = "photos"
    var credentialChoice: CredentialChoice = .new
    var credentialName = ""
    var accessKey = ""
    var secretKey = ""
    var sessionToken = ""
    var direction: SyncDirection = .upload
    var folderURL: URL?

    var isCreatingCredential: Bool { credentialChoice == .new }

    func isComplete(existingCredentialNames: [String]) -> Bool {
        missingRequirement(existingCredentialNames: existingCredentialNames) == nil
    }

    /// Says what is still missing instead of leaving a dimmed button with no
    /// explanation. Ordered the same way the form is read, top to bottom.
    func missingRequirement(existingCredentialNames: [String]) -> String? {
        if folderURL == nil { return "Choose a folder on this Mac." }
        if provider == .compatible && URL(string: endpoint) == nil {
            return "Enter the storage endpoint address."
        }
        if region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the bucket’s region."
        }
        if bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the bucket name."
        }
        guard isCreatingCredential else { return nil }
        if accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secretKey.isEmpty {
            return "Enter the access key and secret key."
        }
        // The agent refuses a duplicate name rather than quietly numbering it,
        // so the sheet has to say so before the keys are sent anywhere.
        let name = effectiveCredentialName.lowercased()
        if existingCredentialNames.contains(where: { $0.lowercased() == name }) {
            return "Credentials named “\(effectiveCredentialName)” already exist. Choose another name."
        }
        return nil
    }

    /// The name this sync will end up with, including the folder fallback.
    var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return folderURL?.lastPathComponent ?? ""
    }

    /// The name new credentials will be saved under. Falls back to the provider
    /// so the common single-account case needs no answer at all.
    var effectiveCredentialName: String {
        let typed = StoredCredential.normalizedName(credentialName)
        return typed.isEmpty ? provider.rawValue : typed
    }
}

enum SyncDraftError: Error, LocalizedError {
    case missingFolder
    case invalidEndpoint
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .missingFolder: "Choose a local folder."
        case .invalidEndpoint: "Use a valid HTTPS S3 endpoint. Plain HTTP is allowed only for a local test server."
        case .missingCredential: "Those saved credentials are no longer available. Choose another set."
        }
    }
}

enum CredentialUpdateError: Error, LocalizedError {
    case missingConnection
    case missingCredential
    case missingKeys

    var errorDescription: String? {
        switch self {
        case .missingConnection: "The S3 connection for this sync is no longer available."
        case .missingCredential: "Those saved credentials are no longer available. Choose another set."
        case .missingKeys: "Enter the access key and secret key."
        }
    }
}

private extension URL {
    var isLoopbackHost: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
