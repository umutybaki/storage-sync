import Foundation
import os
import StorageSyncCore
import StorageSyncEngine
import StorageSyncPersistence
import StorageSyncShared
import StorageSyncSystem

/// The agent has no window to report into, so anything worth diagnosing goes to
/// the unified log, readable with
/// `log show --predicate 'subsystem == "app.photosync.agent"'`.
enum AgentLog {
    static let shared = Logger(subsystem: "app.photosync.agent", category: "agent")
}

final class AgentService: NSObject, StorageSyncAgentXPCProtocol, @unchecked Sendable {
    private let coordinator: SyncCoordinator

    init(coordinator: SyncCoordinator) {
        self.coordinator = coordinator
    }

    func perform(commandData: Data, reply: @escaping (Data?, NSError?) -> Void) {
        let replyBox = ReplyBox(reply)
        Task {
            do {
                let command = try JSONDecoder().decode(AgentCommand.self, from: commandData)
                let response = try await perform(command)
                replyBox.call(response, nil)
            } catch {
                replyBox.call(nil, error as NSError)
            }
        }
    }

    private func perform(_ command: AgentCommand) async throws -> Data? {
        switch command.kind {
        case .snapshots:
            return try JSONEncoder().encode(try await coordinator.snapshots())
        case .jobs:
            return try JSONEncoder().encode(try await coordinator.jobs())
        case .connections:
            return try JSONEncoder().encode(try await coordinator.connections())
        case .transferActivityPage:
            let request = try JSONDecoder().decode(
                TransferActivityPageRequest.self,
                from: requiredPayload(command)
            )
            return try JSONEncoder().encode(try await coordinator.transferActivityPage(request))
        case .saveConnection:
            let connection = try JSONDecoder().decode(S3Connection.self, from: requiredPayload(command))
            try await coordinator.save(connection: connection)
            return nil
        case .testConnection:
            let payload = try JSONDecoder().decode(ConnectionCredentialPayload.self, from: requiredPayload(command))
            try await coordinator.test(
                connection: payload.connection,
                credentials: payload.credentials,
                remotePrefix: payload.remotePrefix
            )
            return nil
        case .credentials:
            return try JSONEncoder().encode(try await coordinator.credentials())
        case .saveCredential:
            let payload = try JSONDecoder().decode(SaveCredentialPayload.self, from: requiredPayload(command))
            let saved = try await coordinator.saveCredential(
                id: payload.id,
                name: payload.name,
                credentials: payload.credentials
            )
            // The reply is the saved record, never the keys: the manager needs
            // the reference to point a connection at, and nothing more.
            return try JSONEncoder().encode(saved)
        case .removeCredential:
            let payload = try JSONDecoder().decode(CredentialCommandPayload.self, from: requiredPayload(command))
            try await coordinator.removeCredential(id: payload.credentialID)
            return nil
        case .saveJob:
            let job = try JSONDecoder().decode(SyncJob.self, from: requiredPayload(command))
            try await coordinator.save(job: job)
            return nil
        case .removeJob:
            let payload = try JSONDecoder().decode(JobCommandPayload.self, from: requiredPayload(command))
            try await coordinator.remove(jobID: payload.jobID)
            return nil
        case .pauseJob:
            let payload = try JSONDecoder().decode(JobCommandPayload.self, from: requiredPayload(command))
            try await coordinator.pause(jobID: payload.jobID)
            return nil
        case .resumeJob:
            let payload = try JSONDecoder().decode(JobCommandPayload.self, from: requiredPayload(command))
            try await coordinator.resume(jobID: payload.jobID)
            return nil
        case .syncNow:
            let payload = try JSONDecoder().decode(JobCommandPayload.self, from: requiredPayload(command))
            try await coordinator.syncNow(jobID: payload.jobID)
            return nil
        case .shutdown:
            AgentLog.shared.log("Shutting down at the manager's request.")
            // Cancels in-flight transfers. Their multipart and range progress is
            // already checkpointed in SQLite, so the next run resumes rather
            // than restarting them.
            await coordinator.stop()
            // Exit after the reply has been delivered; leaving immediately would
            // make the quit look like a failure to the manager.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                exit(0)
            }
            return nil
        }
    }

    private func requiredPayload(_ command: AgentCommand) throws -> Data {
        guard let payload = command.payload else {
            throw NSError(
                domain: "StorageSyncAgent",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The command payload is missing."]
            )
        }
        return payload
    }
}

private final class ActivityBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]

    func add(_ connection: NSXPCConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
    }

    func remove(_ identifier: ObjectIdentifier) {
        lock.lock()
        connections.removeValue(forKey: identifier)
        lock.unlock()
    }

    func broadcast(_ update: TransferActivityUpdate) {
        lock.lock()
        let current = connections
        lock.unlock()
        for (identifier, connection) in current {
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                self?.remove(identifier)
            }) as? StorageSyncAgentClientXPCProtocol else {
                remove(identifier)
                continue
            }
            proxy.transferActivityDidChange(
                jobID: update.jobID.description,
                revision: update.revision
            )
        }
    }

    func broadcastProgress(_ update: TransferProgressUpdate) {
        lock.lock()
        let current = connections
        lock.unlock()
        for (identifier, connection) in current {
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                self?.remove(identifier)
            }) as? StorageSyncAgentClientXPCProtocol else {
                remove(identifier)
                continue
            }
            proxy.transferProgressDidChange(
                jobID: update.jobID.description,
                transferID: update.transferID.description,
                bytesSent: update.bytesSent
            )
        }
    }

    func broadcastStateChange() {
        lock.lock()
        let current = connections
        lock.unlock()
        for (identifier, connection) in current {
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                self?.remove(identifier)
            }) as? StorageSyncAgentClientXPCProtocol else {
                remove(identifier)
                continue
            }
            proxy.stateDidChange()
        }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let reply: (Data?, NSError?) -> Void
    init(_ reply: @escaping (Data?, NSError?) -> Void) { self.reply = reply }
    func call(_ data: Data?, _ error: NSError?) { reply(data, error) }
}

final class AgentDelegate: NSObject, NSXPCListenerDelegate {
    private let service: AgentService
    private let peerValidator: XPCPeerValidator?
    private let activityBroadcaster = ActivityBroadcaster()

    init(coordinator: SyncCoordinator) {
        service = AgentService(coordinator: coordinator)
        peerValidator = XPCPeerValidator()
        if peerValidator == nil {
            // Without a requirement to check against, every connection is
            // refused and the agent is unreachable while still looking healthy
            // to launchd. Say so rather than fail silently.
            AgentLog.shared.error("Could not build the peer code requirement; the manager cannot connect.")
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard peerValidator?.accepts(processIdentifier: newConnection.processIdentifier) == true else {
            AgentLog.shared.error("Refused a connection from process \(newConnection.processIdentifier).")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: StorageSyncAgentXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = NSXPCInterface(with: StorageSyncAgentClientXPCProtocol.self)
        let identifier = ObjectIdentifier(newConnection)
        newConnection.invalidationHandler = { [weak broadcaster = activityBroadcaster] in
            broadcaster?.remove(identifier)
        }
        newConnection.interruptionHandler = { [weak broadcaster = activityBroadcaster] in
            broadcaster?.remove(identifier)
        }
        activityBroadcaster.add(newConnection)
        newConnection.resume()
        return true
    }

    func broadcast(_ update: TransferActivityUpdate) {
        activityBroadcaster.broadcast(update)
    }

    func broadcastProgress(_ update: TransferProgressUpdate) {
        activityBroadcaster.broadcastProgress(update)
    }

    func broadcastStateChange() {
        activityBroadcaster.broadcastStateChange()
    }
}

let locations = try RuntimeLocations.standard()
try locations.prepare()
let repository = try SyncRepository(databaseURL: locations.database)
let bookmarks = try BookmarkStore(directory: locations.bookmarks)
let keychain = KeychainStore()
let coordinator = SyncCoordinator(repository: repository, bookmarks: bookmarks, keychain: keychain)
let delegate = AgentDelegate(coordinator: coordinator)
let listener = NSXPCListener(machServiceName: AgentConstants.machServiceName)
listener.delegate = delegate
listener.resume()

Task {
    let updates = await repository.transferActivityUpdates()
    for await update in updates {
        delegate.broadcast(update)
    }
}

Task {
    let updates = await repository.transferProgressUpdates()
    for await update in updates {
        delegate.broadcastProgress(update)
    }
}

Task {
    let updates = await repository.stateUpdates()
    for await _ in updates {
        delegate.broadcastStateChange()
    }
}

Task {
    do {
        try await coordinator.start()
    } catch {
        // Without this the agent looks perfectly healthy to launchd — running,
        // never exited — while having scheduled no jobs at all. The unified log
        // is the only place that difference can show up.
        AgentLog.shared.error("Could not start the sync coordinator: \(error.localizedDescription, privacy: .public)")
    }
}

let volumeMonitor = VolumeEventMonitor()
Task {
    for await event in volumeMonitor.updates() {
        switch event {
        case .willUnmount(let volumeURL):
            _ = await coordinator.prepareForVolumeUnmount(at: volumeURL)
        case .mounted(let volumeURL), .unmounted(let volumeURL), .renamed(let volumeURL):
            try? await coordinator.finishVolumeChange(at: volumeURL)
        }
    }
}

// Held for the life of the process: releasing it would detach StorageSync from
// Disk Arbitration's approval flow.
let volumeUnmountApprover = VolumeUnmountApprover { volumeURL in
    let prepared = await coordinator.prepareForVolumeUnmount(at: volumeURL)
    Task {
        // If another application declines the eject there may be no subsequent
        // workspace event. Resume normal work after a conservative grace period.
        try? await Task.sleep(for: .seconds(30))
        try? await coordinator.finishVolumeChange(at: volumeURL)
    }
    return prepared
}
if volumeUnmountApprover == nil {
    // Ejects still work; StorageSync just no longer gets asked first, so a drive
    // can be pulled mid-transfer instead of after a checkpoint. Worth saying,
    // because nothing else about the agent looks any different.
    AgentLog.shared.error("Could not open a Disk Arbitration session; ejects will not wait for checkpointing.")
}

let networkMonitor = NetworkAvailabilityMonitor()
Task {
    var previous: NetworkAvailability?
    for await availability in networkMonitor.updates() {
        if case .unavailable = previous,
           case .available = availability {
            try? await coordinator.wakeAll()
        }
        previous = availability
    }
}

RunLoop.main.run()
