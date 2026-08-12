import Foundation
import Security
import StorageSyncCore
import StorageSyncShared

enum AgentClientError: Error, LocalizedError {
    case unavailable
    case missingResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: "The StorageSync background agent is not available."
        case .missingResponse: "The StorageSync background agent returned an empty response."
        }
    }
}

final class AgentClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let eventReceiver = AgentEventReceiver()

    func onTransferActivityChange(
        _ handler: (@Sendable (SyncJobID, Int64) -> Void)?
    ) {
        eventReceiver.setHandler(handler)
    }

    func onTransferProgressChange(
        _ handler: (@Sendable (TransferProgressUpdate) -> Void)?
    ) {
        eventReceiver.setProgressHandler(handler)
    }

    func onStateChange(_ handler: (@Sendable () -> Void)?) {
        eventReceiver.setStateHandler(handler)
    }

    func onConnectionLost(_ handler: (@Sendable () -> Void)?) {
        eventReceiver.setConnectionLostHandler(handler)
    }

    func perform<Response: Decodable & Sendable>(
        _ kind: AgentCommandKind,
        payload: Data? = nil,
        response: Response.Type
    ) async throws -> Response {
        let data = try await performRaw(kind, payload: payload)
        guard let data else { throw AgentClientError.missingResponse }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func perform(_ kind: AgentCommandKind, payload: Data? = nil) async throws {
        _ = try await performRaw(kind, payload: payload)
    }

    func invalidate() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }

    private func performRaw(_ kind: AgentCommandKind, payload: Data?) async throws -> Data? {
        let command = AgentCommand(kind: kind, payload: payload)
        let commandData = try JSONEncoder().encode(command)
        guard let connection = currentConnection() else {
            // There is no connection to lose, so nothing will report this the
            // usual way. Say it in both registers the caller already handles:
            // the throw answers this command, the callback moves the UI to the
            // same "agent not running" state a dropped connection produces, and
            // the app's recovery loop takes it from there.
            connectionWasLost()
            throw AgentClientError.unavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.resume(throwing: error)
            }) as? StorageSyncAgentXPCProtocol else {
                box.resume(throwing: AgentClientError.unavailable)
                return
            }
            proxy.perform(commandData: commandData) { data, error in
                if let error { box.resume(throwing: error) }
                else { box.resume(returning: data) }
            }
        }
    }

    /// Nil when the agent's requirement cannot be produced, which is refused
    /// rather than connected unpinned: a Mach service name is claimed, not
    /// owned, and the commands sent over this connection carry the user's S3
    /// keys to whatever answered it.
    private func currentConnection() -> NSXPCConnection? {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        guard let requirement = Self.agentRequirementText() else { return nil }
        let newConnection = NSXPCConnection(machServiceName: AgentConstants.machServiceName, options: [])
        newConnection.remoteObjectInterface = NSXPCInterface(with: StorageSyncAgentXPCProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: StorageSyncAgentClientXPCProtocol.self)
        newConnection.exportedObject = eventReceiver
        newConnection.interruptionHandler = { [weak self] in self?.connectionWasLost() }
        newConnection.invalidationHandler = { [weak self] in self?.connectionWasLost() }
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    /// The mirror of what the agent pins on its side, read from the helper this
    /// app ships rather than captured once, for the same reason: the app is
    /// ad-hoc signed, so its designated requirement is a cdhash and every
    /// rebuild produces a different one. A requirement held from an earlier
    /// launch would name the helper this bundle replaced.
    private static func agentRequirementText() -> String? {
        let agentURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/StorageSyncAgent", isDirectory: false)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(agentURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else { return nil }
        return text as String
    }

    private func discardConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    private func connectionWasLost() {
        discardConnection()
        eventReceiver.connectionWasLost()
    }
}

private final class AgentEventReceiver: NSObject, StorageSyncAgentClientXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (SyncJobID, Int64) -> Void)?
    private var progressHandler: (@Sendable (TransferProgressUpdate) -> Void)?
    private var stateHandler: (@Sendable () -> Void)?
    private var connectionLostHandler: (@Sendable () -> Void)?

    func setHandler(_ handler: (@Sendable (SyncJobID, Int64) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setProgressHandler(_ handler: (@Sendable (TransferProgressUpdate) -> Void)?) {
        lock.lock()
        progressHandler = handler
        lock.unlock()
    }

    func setStateHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        stateHandler = handler
        lock.unlock()
    }

    func setConnectionLostHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        connectionLostHandler = handler
        lock.unlock()
    }

    func transferActivityDidChange(jobID: String, revision: Int64) {
        guard let rawValue = UUID(uuidString: jobID) else { return }
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(SyncJobID(rawValue: rawValue), revision)
    }

    func transferProgressDidChange(jobID: String, transferID: String, bytesSent: Int64) {
        guard let jobUUID = UUID(uuidString: jobID),
              let transferUUID = UUID(uuidString: transferID) else { return }
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        handler?(
            TransferProgressUpdate(
                jobID: SyncJobID(rawValue: jobUUID),
                transferID: TransferID(rawValue: transferUUID),
                bytesSent: bytesSent
            )
        )
    }

    func stateDidChange() {
        lock.lock()
        let handler = stateHandler
        lock.unlock()
        handler?()
    }

    func connectionWasLost() {
        lock.lock()
        let handler = connectionLostHandler
        lock.unlock()
        handler?()
    }
}

private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?

    init(_ continuation: CheckedContinuation<Data?, Error>) {
        self.continuation = continuation
    }

    func resume(returning data: Data?) {
        take()?.resume(returning: data)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Data?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
