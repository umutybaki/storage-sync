import Foundation
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
        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            let connection = currentConnection()
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

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: AgentConstants.machServiceName, options: [])
        newConnection.remoteObjectInterface = NSXPCInterface(with: StorageSyncAgentXPCProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: StorageSyncAgentClientXPCProtocol.self)
        newConnection.exportedObject = eventReceiver
        newConnection.interruptionHandler = { [weak self] in self?.connectionWasLost() }
        newConnection.invalidationHandler = { [weak self] in self?.connectionWasLost() }
        newConnection.resume()
        connection = newConnection
        return newConnection
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
