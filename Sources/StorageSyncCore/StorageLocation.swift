import Foundation

/// A reusable selection, independent of a sync's direction and progress.
/// Targets are immutable once saved; renaming never changes a pairing.
public struct StorageLocation: Codable, Hashable, Sendable, Identifiable {
    public let id: LocationID
    public var name: String
    public let target: StorageLocationTarget

    public init(id: LocationID = LocationID(), name: String, target: StorageLocationTarget) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .local: self.target = target
        case .s3(let connectionID, let prefix):
            self.target = .s3(connectionID: connectionID, prefix: SyncJob.normalizedPrefix(prefix))
        }
    }

    public var localRoot: LocalRoot? {
        guard case .local(let root) = target else { return nil }
        return root
    }

    public var connectionID: ConnectionID? {
        guard case .s3(let id, _) = target else { return nil }
        return id
    }

    public var remotePrefix: String? {
        guard case .s3(_, let prefix) = target else { return nil }
        return prefix
    }

    public static func uniqueName(_ proposed: String, avoiding names: [String]) -> String {
        let base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = base.isEmpty ? "Location" : base
        var suffix = 2
        while names.contains(where: { $0.localizedCaseInsensitiveCompare(result) == .orderedSame }) {
            result = "\(base.isEmpty ? "Location" : base) (\(suffix))"
            suffix += 1
        }
        return result
    }
}

public enum StorageLocationTarget: Codable, Hashable, Sendable {
    case local(LocalRoot)
    case s3(connectionID: ConnectionID, prefix: String)
}

public enum LocationError: Error, LocalizedError {
    case missingLocation
    case missingConnection
    case invalidName
    case duplicateName
    case immutableTarget
    case inUse([String])
    case unsupportedRoute

    public var errorDescription: String? {
        switch self {
        case .missingLocation: "A selected location is no longer available. Choose it again."
        case .missingConnection: "The bucket connection for this location is no longer available."
        case .invalidName: "Enter a name for this location."
        case .duplicateName: "A location with that name already exists. Choose another name."
        case .immutableTarget: "Create a new location to use a different folder or bucket."
        case .inUse(let names): "This location is used by: \(names.joined(separator: ", ")). Remove those syncs first."
        case .unsupportedRoute: "Choose one Mac folder and one cloud bucket. Cloud-to-cloud and folder-to-folder transfers are not available yet."
        }
    }
}

public extension SyncJob {
    init(name: String, source: StorageLocation, destination: StorageLocation) throws {
        let local = source.localRoot ?? destination.localRoot
        let remote = source.connectionID != nil ? source : destination
        guard let local, let connectionID = remote.connectionID else { throw LocationError.unsupportedRoute }
        self.init(
            name: name,
            direction: source.localRoot != nil ? .upload : .download,
            localRoot: local,
            connectionID: connectionID,
            remotePrefix: remote.remotePrefix ?? ""
        )
        try resolveRoute(source: source, destination: destination)
    }

    mutating func resolveRoute(source: StorageLocation, destination: StorageLocation) throws {
        guard source.id != destination.id else { throw LocationError.unsupportedRoute }
        switch (source.target, destination.target) {
        case (.local(let root), .s3(let connectionID, let prefix)):
            direction = .upload
            localRoot = root
            self.connectionID = connectionID
            remotePrefix = prefix
        case (.s3(let connectionID, let prefix), .local(let root)):
            direction = .download
            localRoot = root
            self.connectionID = connectionID
            remotePrefix = prefix
        default: throw LocationError.unsupportedRoute
        }
        sourceLocationID = source.id
        destinationLocationID = destination.id
    }
}
