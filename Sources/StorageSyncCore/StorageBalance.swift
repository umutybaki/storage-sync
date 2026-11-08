import Foundation

/// Where a sync's bytes are: on this Mac, in the bucket, or in between. This is
/// what the two storage bars in the interface are drawn from, and it is the
/// one place the arithmetic lives so the window and the menu bar cannot
/// disagree about it.
///
/// Everything is measured in bytes rather than file counts, because a thousand
/// thumbnails and one video are not the same amount of "left to copy".
///
/// The whole width is the union of both sides:
///
///     total  = cloudBytes + pendingBytes        (upload; mirrored downward)
///
/// which makes `cloudBytes + pendingBytes == totalBytes` exact rather than
/// approximate. The pending segment is precisely the span the destination
/// has not reached yet, so they can be drawn as one continuous bar: the
/// destination fills from the left, the pending gap sits at the right edge, and
/// as files copy the first grows into the second.
public struct StorageBalance: Equatable, Sendable {
    /// Which way this sync copies. The destination is the side that grows.
    public var direction: SyncDirection
    /// Bytes under the paired folder on this Mac.
    public var localBytes: Int64
    /// Bytes under the paired prefix in the bucket, including what has been
    /// copied so far in the run that is happening now.
    public var cloudBytes: Int64
    /// Bytes the source holds that the destination does not have yet.
    public var pendingBytes: Int64
    /// Bytes that are in both places — the overlap the other two share.
    public var sharedBytes: Int64
    /// Everything, once, however many places it exists in.
    public var totalBytes: Int64
    /// What the run happening now set out to copy, and how much of it has gone.
    /// The bars are drawn against the whole library, where a small queue inside
    /// a large one is a sliver that barely moves; this is the same work seen
    /// from the inside, which is what a person watching a long copy wants.
    public var runBytes: Int64
    public var movedBytes: Int64
    public var localFiles: Int
    public var cloudFiles: Int
    /// Files the destination already has — the count the product contract
    /// promises alongside "found" and "remaining".
    public var sharedFiles: Int
    public var pendingFiles: Int

    /// Returns nil for a snapshot that has no byte totals: one written by an
    /// earlier build, or one the engine replaced with a bare blocked state.
    /// Callers show the last complete picture instead of a half-empty one.
    public init?(snapshot: SyncSnapshot, direction: SyncDirection) {
        guard let sourceBytes = snapshot.sourceBytesFound,
              let destinationInPlace = snapshot.destinationBytesInPlace else { return nil }

        // `bytesCompleted` moves continuously while `destinationBytesInPlace`
        // only settles at the end of a run, so adding them is what makes the
        // bottom line glide instead of jumping one file at a time. The two are
        // written to never overlap: see `SyncSnapshot.destinationBytesInPlace`.
        let moved = max(0, snapshot.bytesCompleted)
        let inPlace = max(0, destinationInPlace)
        let destinationBytes = inPlace + min(moved, Int64.max - inPlace)
        let pending = max(0, max(0, snapshot.bytesTotal) - moved)
        let source = max(0, sourceBytes)

        self.direction = direction
        totalBytes = destinationBytes + min(pending, Int64.max - destinationBytes)
        runBytes = max(0, snapshot.bytesTotal)
        movedBytes = moved
        pendingBytes = pending
        sharedBytes = min(max(0, source - pending), destinationBytes)
        switch direction {
        case .upload:
            localBytes = source
            cloudBytes = destinationBytes
            localFiles = snapshot.sourceFilesFound ?? 0
            cloudFiles = snapshot.destinationFilesFound ?? 0
        case .download:
            localBytes = destinationBytes
            cloudBytes = source
            localFiles = snapshot.destinationFilesFound ?? 0
            cloudFiles = snapshot.sourceFilesFound ?? 0
        }
        sharedFiles = snapshot.filesAlreadyPresent ?? 0
        pendingFiles = max(0, snapshot.filesTotal - snapshot.filesCompleted)
    }

    /// Bytes that exist at exactly one end of the sync.
    public var localOnlyBytes: Int64 { max(0, localBytes - sharedBytes) }
    public var cloudOnlyBytes: Int64 { max(0, cloudBytes - sharedBytes) }

    public var hasPendingWork: Bool { pendingBytes > 0 || pendingFiles > 0 }

    /// How far the run happening now has got through its own queue.
    public var runFraction: Double {
        guard runBytes > 0 else { return 0 }
        return min(1, max(0, Double(movedBytes) / Double(runBytes)))
    }

    public var localFraction: Double { fraction(of: localBytes) }
    public var cloudFraction: Double { fraction(of: cloudBytes) }
    public var pendingFraction: Double { fraction(of: pendingBytes) }

    /// Clamped, because a source file that grew between the scan and the queue
    /// being counted can briefly overrun the total, and a bar wider than its
    /// track reads as a bug rather than as the rounding it is.
    private func fraction(of bytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(totalBytes)))
    }
}
