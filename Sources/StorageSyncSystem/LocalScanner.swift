import CryptoKit
import Foundation
import StorageSyncCore

/// Counts the entries a scan stepped over because they could not be read.
///
/// A skipped entry is absent from that scan's manifest exactly as a deleted
/// file is, and the cycle uses absence to retire a file's baseline. A baseline
/// retired by a read error is not just a lost record: the next scan that does
/// see the file pairs it as a first meeting, and any change made in between is
/// then taken as the copy instead of being sent. So the caller needs to know a
/// scan was incomplete, not merely that it finished.
public final class LocalScanSkipCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

public struct LocalScanner: Sendable {
    public init() {}

    public func files(
        at root: URL,
        skipped: LocalScanSkipCounter? = nil
    ) -> AsyncThrowingStream<FileFingerprint, Error> {
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
                        errorHandler: { url, error in
                            // One unreadable path — a permission-denied folder, a
                            // briefly locked file — must not end the whole scan.
                            // Aborting surfaces as a CocoaError, which the cycle
                            // reads as a disconnected volume and retries forever;
                            // only a failure on the root itself really is that.
                            guard url.standardizedFileURL.pathComponents == rootComponents else {
                                skipped?.increment()
                                return true
                            }
                            continuation.finish(throwing: error)
                            return false
                        }
                    ) else {
                        throw CocoaError(.fileReadUnknown)
                    }

                    while let url = enumerator.nextObject() as? URL {
                        try Task.checkCancellation()
                        // A file can be removed, replaced, or briefly locked
                        // between the enumerator yielding it and this fetch,
                        // which is routine on a library the user is still
                        // using. Failing the scan here is the same trap the
                        // error handler above avoids: the cycle reads the
                        // CocoaError as a disconnected volume and retries the
                        // same doomed pass forever. Skipping costs at most one
                        // scan's knowledge of the entry — deletion never
                        // propagates to the destination, so an entry missing
                        // from one manifest cannot remove anything.
                        guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                            skipped?.increment()
                            continue
                        }
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
                            modificationTimeNanoseconds: Self.modificationTimeNanoseconds(modified),
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
            modificationTimeNanoseconds: Self.modificationTimeNanoseconds(modified),
            fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
            generationIdentifier: values.generationIdentifier.map { String(describing: $0) }
        )
    }

    // Converting the scaled interval straight to Int64 traps, so one file dated
    // beyond ±292 years from the epoch — a bogus `touch`, a restored archive, a
    // corrupt exFAT directory entry — crashed the scanning process, and the
    // relaunched scan reached the same file again. Clamping is deterministic, so
    // such a file still fingerprints and reconciles; the only cost is that two
    // equally out-of-range timestamps compare as unchanged.
    private static func modificationTimeNanoseconds(_ interval: TimeInterval) -> Int64 {
        let nanoseconds = (interval * 1_000_000_000).rounded(.towardZero)
        guard let exact = Int64(exactly: nanoseconds) else {
            return nanoseconds < 0 ? .min : .max
        }
        return exact
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
