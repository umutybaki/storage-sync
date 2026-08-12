import Foundation

public protocol StorageSyncIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension StorageSyncIdentifier {
    init() {
        self.init(rawValue: UUID())
    }

    var description: String { rawValue.uuidString }
}

public struct SyncJobID: StorageSyncIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct ConnectionID: StorageSyncIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct CredentialID: StorageSyncIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct TransferID: StorageSyncIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}
