import Foundation
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
        newConnection.interruptionHandler = { [weak self] in self?.discardConnection() }
        newConnection.invalidationHandler = { [weak self] in self?.discardConnection() }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func discardConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
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
