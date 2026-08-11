import AppKit
import CryptoKit
import Foundation
import StorageSyncCore
import StorageSyncShared
import StorageSyncSystem
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var jobs: [SyncJob] = []
    @Published private(set) var connections: [ConnectionID: S3Connection] = [:]
    @Published private(set) var snapshots: [SyncJobID: SyncSnapshot] = [:]
    @Published var selectedJobID: SyncJobID?
    @Published var isCreatingSync = false
    @Published var credentialsJob: SyncJob?
    @Published var jobPendingRemoval: SyncJob?
    @Published var errorMessage: String?
    @Published private(set) var isAgentAvailable = false
    /// True only while macOS is holding the agent behind an explicit user
    /// approval in Login Items. Nothing else the app can do will start it.
    @Published private(set) var needsLoginItemsApproval = false

    private let client = AgentClient()
    private var pollingTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    /// When the agent first stopped answering, so a momentary gap is not
    /// mistaken for a broken registration.
    private var unreachableSince: Date?

    init() {
        ActiveAppModel.current = self
        registrationTask = Task { [weak self] in
            await self?.maintainBackgroundServices()
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    deinit {
        registrationTask?.cancel()
        pollingTask?.cancel()
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
        jobs.first { $0.id == selectedJobID }
    }

    func snapshot(for jobID: SyncJobID) -> SyncSnapshot {
        snapshots[jobID] ?? SyncSnapshot(jobID: jobID, phase: .idle, message: "Starting…")
    }

    func status(for job: SyncJob) -> SyncStatus {
        SyncStatus(job: job, snapshot: snapshot(for: job.id))
    }

    func connection(for job: SyncJob) -> S3Connection? {
        connections[job.connectionID]
    }

    func beginCreatingSync() {
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
            isAgentAvailable = true
            unreachableSince = nil
            if selectedJobID == nil || !jobs.contains(where: { $0.id == selectedJobID }) {
                selectedJobID = jobs.first?.id
            }
        } catch {
            isAgentAvailable = false
            if unreachableSince == nil { unreachableSince = Date() }
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
        let connectionID = ConnectionID()
        let credentialReference = connectionID.description
        let connection = S3Connection(
            id: connectionID,
            name: draft.provider == .amazon ? "Amazon S3" : endpoint.host ?? "S3 Storage",
            endpoint: endpoint,
            region: draft.region,
            bucket: draft.bucket,
            addressingStyle: draft.provider == .amazon && !draft.bucket.contains(".") ? .virtualHost : .path,
            credentialReference: credentialReference
        )
        let credentials = S3Credentials(
            accessKeyID: draft.accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: draft.secretKey,
            sessionToken: draft.sessionToken.nilIfBlank
        )
        let connectionPayload = ConnectionCredentialPayload(
            connection: connection,
            credentials: credentials,
            remotePrefix: SyncJob.normalizedPrefix(draft.prefix)
        )
        let encodedConnection = try JSONEncoder().encode(connectionPayload)
        try await client.perform(.testConnection, payload: encodedConnection)

        let locations = try RuntimeLocations.standard()
        try locations.prepare()
        let bookmarkStore = try BookmarkStore(directory: locations.bookmarks)
        let bookmarkReference = try await bookmarkStore.create(for: folderURL)
        let volume = try VolumeInspector().identity(for: folderURL, createMarkerIfNeeded: true)
        try await client.perform(.saveConnection, payload: encodedConnection)
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
        selectedJobID = job.id
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
        await sendJobCommand(.syncNow, jobID: job.id)
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
    /// Polling and registration are cancelled *first*. Both would otherwise
    /// undo the shutdown: any request over XPC makes launchd start the agent
    /// again on demand, and the maintenance loop would re-register it.
    func shutdownAgentForQuit() async {
        pollingTask?.cancel()
        registrationTask?.cancel()
        pollingTask = nil
        registrationTask = nil

        let client = self.client
        // The command is sent even when the agent looks unreachable, because
        // "unreachable" can just mean a slow poll while it is busy transferring,
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

    func updateCredentials(
        for job: SyncJob,
        accessKey: String,
        secretKey: String,
        sessionToken: String
    ) async throws {
        guard let connection = connections[job.connectionID] else {
            throw CredentialUpdateError.missingConnection
        }
        let credentials = S3Credentials(
            accessKeyID: accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretKey,
            sessionToken: sessionToken.nilIfBlank
        )
        let payload = try JSONEncoder().encode(
            ConnectionCredentialPayload(
                connection: connection,
                credentials: credentials,
                remotePrefix: job.remotePrefix
            )
        )
        try await client.perform(.testConnection, payload: payload)
        try await client.perform(.saveConnection, payload: payload)
        credentialsJob = nil
        await refresh()
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
                // now replaced, so let the next poll open a fresh one.
                client.invalidate()
                // Give the replacement agent the full grace period before it is
                // judged unreachable again.
                unreachableSince = Date()
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
    var accessKey = ""
    var secretKey = ""
    var sessionToken = ""
    var direction: SyncDirection = .upload
    var folderURL: URL?

    var isComplete: Bool { missingRequirement == nil }

    /// Says what is still missing instead of leaving a dimmed button with no
    /// explanation. Ordered the same way the form is read, top to bottom.
    var missingRequirement: String? {
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
        if accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secretKey.isEmpty {
            return "Enter the access key and secret key."
        }
        return nil
    }

    /// The name this sync will end up with, including the folder fallback.
    var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return folderURL?.lastPathComponent ?? ""
    }
}

enum SyncDraftError: Error, LocalizedError {
    case missingFolder
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .missingFolder: "Choose a local folder."
        case .invalidEndpoint: "Use a valid HTTPS S3 endpoint. Plain HTTP is allowed only for a local test server."
        }
    }
}

enum CredentialUpdateError: Error, LocalizedError {
    case missingConnection

    var errorDescription: String? {
        "The S3 connection for this sync is no longer available."
    }
}

private extension URL {
    var isLoopbackHost: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
