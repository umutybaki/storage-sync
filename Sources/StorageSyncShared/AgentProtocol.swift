import Foundation
import StorageSyncCore

public enum AgentCommandKind: String, Codable, Sendable {
    case snapshots
    case jobs
    case connections
    case saveConnection
    case testConnection
    case saveJob
    case removeJob
    case pauseJob
    case resumeJob
    case syncNow
    /// Stop all work and exit. Sent when the user quits StorageSync, which is
    /// meant to close everything rather than leave the engine running.
    case shutdown
}

public struct AgentCommand: Codable, Sendable {
    public var kind: AgentCommandKind
    public var payload: Data?

    public init(kind: AgentCommandKind, payload: Data? = nil) {
        self.kind = kind
        self.payload = payload
    }
}

public struct ConnectionCredentialPayload: Codable, Sendable {
    public var connection: S3Connection
    public var credentials: S3Credentials
    public var remotePrefix: String?

    public init(
        connection: S3Connection,
        credentials: S3Credentials,
        remotePrefix: String? = nil
    ) {
        self.connection = connection
        self.credentials = credentials
        self.remotePrefix = remotePrefix
    }
}

public struct JobCommandPayload: Codable, Sendable {
    public var jobID: SyncJobID

    public init(jobID: SyncJobID) {
        self.jobID = jobID
    }
}

@objc public protocol StorageSyncAgentXPCProtocol {
    func perform(commandData: Data, reply: @escaping (Data?, NSError?) -> Void)
}

public enum AgentConstants {
    public static let machServiceName = "app.photosync.agent"
}
