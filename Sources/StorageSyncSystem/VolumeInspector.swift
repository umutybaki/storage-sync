import Foundation
import StorageSyncCore

public enum VolumeInspectorError: Error, LocalizedError {
    case notMounted
    case ambiguousIdentity

    public var errorDescription: String? {
        switch self {
        case .notMounted: "The selected volume is not mounted."
        case .ambiguousIdentity: "StorageSync cannot prove that this is the originally selected volume."
        }
    }
}

public struct VolumeInspector: Sendable {
    /// The scanner and the reconciler must exclude exactly this name, so it is
    /// defined once in `StorageSyncCore` and surfaced here for convenience.
    public static let markerFilename = ReservedName.volumeMarker

    public init() {}

    public func identity(for selectedURL: URL, createMarkerIfNeeded: Bool) throws -> VolumeIdentity {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey,
            .volumeCreationDateKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeSupportsCaseSensitiveNamesKey,
            .volumeURLKey
        ]
        var uncachedURL = selectedURL
        uncachedURL.removeAllCachedResourceValues()
        let values = try uncachedURL.resourceValues(forKeys: keys)
        guard values.volume != nil else { throw VolumeInspectorError.notMounted }
        // `volumeIsRemovable` describes removable *media* and is often false
        // for USB/Thunderbolt SSDs. Anything macOS identifies as non-internal
        // must still receive external-volume identity handling.
        let removable = (values.volumeIsRemovable ?? false) || values.volumeIsInternal == false
        let marker = try marker(at: selectedURL, createIfMissing: removable && createMarkerIfNeeded)
        if createMarkerIfNeeded, removable, marker == nil, values.volumeUUIDString == nil {
            throw VolumeInspectorError.ambiguousIdentity
        }
        return VolumeIdentity(
            persistentUUID: values.volumeUUIDString,
            creationDate: values.volumeCreationDate,
            filesystemType: values.volumeLocalizedFormatDescription,
            totalCapacity: values.volumeTotalCapacity.map(Int64.init),
            isRemovable: removable,
            isCaseSensitive: values.volumeSupportsCaseSensitiveNames,
            rootMarker: marker
        )
    }

    public func capacity(for selectedURL: URL) throws -> VolumeCapacity {
        var uncachedURL = selectedURL
        uncachedURL.removeAllCachedResourceValues()
        let values = try uncachedURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeMaximumFileSizeKey
        ])
        return VolumeCapacity(
            availableBytes: values.volumeAvailableCapacityForImportantUsage,
            maximumFileSize: values.volumeMaximumFileSize.map(Int64.init)
        )
    }

    public func validate(expected: VolumeIdentity, selectedURL: URL) throws -> VolumeIdentity {
        let actual = try identity(for: selectedURL, createMarkerIfNeeded: false)
        guard expected.confidentlyMatches(actual) else {
            throw VolumeInspectorError.ambiguousIdentity
        }
        return actual
    }

    private func marker(at selectedURL: URL, createIfMissing: Bool) throws -> UUID? {
        let markerURL = selectedURL.appendingPathComponent(Self.markerFilename, isDirectory: false)
        func readMarker() -> UUID? {
            let fd = open(markerURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 128,
                  let bytes = try? file.read(upToCount: 129),
                  let text = String(data: bytes, encoding: .utf8) else { return nil }
            return UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let existing = readMarker() { return existing }
        guard createIfMissing else { return nil }
        let value = UUID()
        // A marker-shaped user file or a concurrent pairing must never be replaced.
        do {
            try Data(value.uuidString.utf8).write(to: markerURL, options: .withoutOverwriting)
            return value
        } catch {
            return readMarker()
        }
    }
}

public struct VolumeCapacity: Sendable, Equatable {
    public var availableBytes: Int64?
    public var maximumFileSize: Int64?

    public init(availableBytes: Int64?, maximumFileSize: Int64?) {
        self.availableBytes = availableBytes
        self.maximumFileSize = maximumFileSize
    }
}
