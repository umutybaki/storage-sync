import CryptoKit
import Foundation
import StorageSyncCore

public struct LocalScanner: Sendable {
    public init() {}

    public func files(at root: URL) -> AsyncThrowingStream<FileFingerprint, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let scanRoot = root.resolvingSymlinksInPath().standardizedFileURL
                    let rootComponents = scanRoot.pathComponents
                    let keys: [URLResourceKey] = [
                        .isRegularFileKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                        .fileResourceIdentifierKey,
                        .generationIdentifierKey,
                        .isSymbolicLinkKey,
                        .isDirectoryKey
                    ]
                    guard let enumerator = FileManager.default.enumerator(
                        at: scanRoot,
                        includingPropertiesForKeys: keys,
                        options: [],
                        errorHandler: { _, error in
                            continuation.finish(throwing: error)
                            return false
                        }
                    ) else {
                        throw CocoaError(.fileReadUnknown)
                    }

                    while let url = enumerator.nextObject() as? URL {
                        try Task.checkCancellation()
                        let values = try url.resourceValues(forKeys: Set(keys))
                        let fileComponents = url.standardizedFileURL.pathComponents
                        guard fileComponents.starts(with: rootComponents) else {
                            throw CocoaError(.fileReadInvalidFileName)
                        }
                        let relativeComponents = fileComponents.dropFirst(rootComponents.count)
                        guard !relativeComponents.isEmpty else { continue }
                        // StorageSync's own bookkeeping is skipped at every depth,
                        // so a sync rooted at a parent folder never picks up the
                        // state of a sync rooted at a child.
                        if relativeComponents.contains(where: ReservedName.isReserved) {
                            if values.isDirectory == true { enumerator.skipDescendants() }
                            continue
                        }
                        if values.isSymbolicLink == true {
                            if values.isDirectory == true { enumerator.skipDescendants() }
                            continue
                        }
                        guard values.isRegularFile == true else { continue }
                        let relativePath = relativeComponents.joined(separator: "/")
                        guard !relativePath.isEmpty else { continue }
                        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                        var pending = FileFingerprint(
                            relativePath: relativePath,
                            size: Int64(values.fileSize ?? 0),
                            modificationTimeNanoseconds: Int64(modified * 1_000_000_000),
                            fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                            generationIdentifier: values.generationIdentifier.map { String(describing: $0) }
                        )
                        // AsyncThrowingStream is unbounded by default. A fast
                        // directory enumerator could otherwise retain millions
                        // of fingerprints while SQLite persists earlier batches.
                        // `bufferingOldest` returns the newest, unqueued element
                        // when full, so retrying that exact value provides
                        // bounded, lossless backpressure without reordering.
                        yieldLoop: while true {
                            switch continuation.yield(pending) {
                            case .enqueued:
                                break yieldLoop
                            case .dropped(let unqueued):
                                pending = unqueued
                                try await Task.sleep(for: .milliseconds(1))
                                continue
                            case .terminated:
                                return
                            @unknown default:
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func fingerprint(url: URL, relativePath: String) throws -> FileFingerprint {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .generationIdentifierKey,
            .isSymbolicLinkKey
        ]
        // A URL can retain resource values fetched earlier in the same transfer.
        // Clear that cache so the post-transfer fingerprint observes mutations that
        // happened while bytes were in flight.
        var uncachedURL = url
        uncachedURL.removeAllCachedResourceValues()
        let values = try uncachedURL.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return FileFingerprint(
            relativePath: relativePath,
            size: Int64(values.fileSize ?? 0),
            modificationTimeNanoseconds: Int64(modified * 1_000_000_000),
            fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
            generationIdentifier: values.generationIdentifier.map { String(describing: $0) }
        )
    }

    public func sha256(url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return hasher.finalize().hexadecimalString
        }.value
    }
}
