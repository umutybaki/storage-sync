import Foundation
import StorageSyncCore

public enum AgentCommandKind: String, Codable, Sendable {
    case snapshots
    case jobs
    case connections
    case locations
    case saveLocation
    case removeLocation
    /// One bounded page from the selected sync's durable activity batch.
    case transferActivityPage
    case saveConnection
    case testConnection
    /// Saved provider keys, described without their secrets.
    case credentials
    case saveCredential
    case removeCredential
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
    /// Keys sent inline, which happens only while a credential is being
    /// created and therefore does not exist to point at yet. `nil` means "use
    /// the saved credential this connection already references", so the common
    /// case — a second sync reusing keys that are already stored — never
    /// carries a secret over XPC at all.
    public var credentials: S3Credentials?
    public var remotePrefix: String?

    public init(
        connection: S3Connection,
        credentials: S3Credentials? = nil,
        remotePrefix: String? = nil
    ) {
        self.connection = connection
        self.credentials = credentials
        self.remotePrefix = remotePrefix
    }
}

/// Creates a credential, renames one, or replaces the keys inside one.
///
/// `id` absent means create. `credentials` absent means leave the saved keys
/// alone, which is how a rename avoids needing the secret in hand.
public struct SaveCredentialPayload: Codable, Sendable {
    public var id: CredentialID?
    public var name: String
    public var credentials: S3Credentials?

    public init(id: CredentialID? = nil, name: String, credentials: S3Credentials? = nil) {
        self.id = id
        self.name = name
        self.credentials = credentials
    }
}

public struct CredentialCommandPayload: Codable, Sendable {
    public var credentialID: CredentialID

    public init(credentialID: CredentialID) {
        self.credentialID = credentialID
    }
}

public struct JobCommandPayload: Codable, Sendable {
    public var jobID: SyncJobID

    public init(jobID: SyncJobID) {
        self.jobID = jobID
    }
}

public struct LocationCommandPayload: Codable, Sendable {
    public var locationID: LocationID
    public init(locationID: LocationID) { self.locationID = locationID }
}

@objc public protocol StorageSyncAgentXPCProtocol {
    func perform(commandData: Data, reply: @escaping (Data?, NSError?) -> Void)
}

/// Agent-to-manager wake-up. The revision was committed before this callback;
/// it contains no activity payload and therefore cannot race SQLite as a
/// competing source of truth.
@objc public protocol StorageSyncAgentClientXPCProtocol {
    func transferActivityDidChange(jobID: String, revision: Int64)
    func transferProgressDidChange(jobID: String, transferID: String, bytesSent: Int64)
    func stateDidChange()
}

public enum AgentConstants {
    public static let machServiceName = "app.photosync.agent"
}
