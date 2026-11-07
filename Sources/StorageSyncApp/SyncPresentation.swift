import StorageSyncCore
import SwiftUI

/// One sync, described the way every surface should describe it. The menu bar
/// popover and the manager window both read from here so they can never
/// disagree about what a job is doing.
struct SyncStatus: Equatable {
    enum Tone {
        case caughtUp
        case working
        case waiting
        case attention
    }

    var tone: Tone
    /// A short sentence fit for a row or a headline.
    var title: String
    /// A calmer supporting sentence that says what happens next.
    var detail: String

    var tint: Color {
        switch tone {
        case .caughtUp: .green
        case .working: .accentColor
        case .waiting: .orange
        case .attention: .red
        }
    }

    /// Deliberately four different shapes, not four colours of the same shape,
    /// so the state survives colour blindness and a monochrome menu bar.
    var symbol: String {
        switch tone {
        case .caughtUp: "checkmark.circle.fill"
        case .working: "arrow.triangle.2.circlepath.circle.fill"
        case .waiting: "clock.fill"
        case .attention: "exclamationmark.triangle.fill"
        }
    }
}

extension SyncStatus {
    init(job: SyncJob, snapshot: SyncSnapshot) {
        let place = job.localRoot.displayName
        let engineMessage = snapshot.message.trimmingCharacters(in: .whitespacesAndNewlines)

        // A blocked snapshot carries `error.localizedDescription`, which is
        // written for a log, not for a person: an unplugged drive reads as
        // "The file doesn't exist." These states recover by themselves, so the
        // interface says what is happening instead of quoting the error.
        if snapshot.blockers.contains(.credentialsUnavailable) {
            self = SyncStatus(
                tone: .attention,
                title: "Sign in to S3 again",
                detail: "The saved keys were rejected. Resumable progress is kept until new keys are entered."
            )
        } else if snapshot.blockers.contains(.localVolumeUnavailable) {
            self = SyncStatus(
                tone: .waiting,
                title: "Waiting for \(place)",
                detail: "StorageSync saved its place. Syncing continues on its own once the same drive is connected again. If the folder moved or the drive was replaced, use Choose Folder…."
            )
        } else if snapshot.blockers.contains(.insufficientSpace) {
            self = SyncStatus(
                tone: .waiting,
                title: "Not enough space on \(place)",
                detail: "StorageSync keeps the progress it already made and retries automatically."
            )
        } else if snapshot.blockers.contains(.networkUnavailable) {
            self = SyncStatus(
                tone: .waiting,
                title: "Waiting for internet",
                detail: "Nothing to do. StorageSync retries automatically."
            )
        } else if job.isPaused || snapshot.phase == .paused {
            self = SyncStatus(
                tone: .waiting,
                title: "Paused",
                detail: "Resume whenever you like. Nothing is lost while a sync is paused."
            )
        } else {
            switch snapshot.phase {
            case .attention:
                self = SyncStatus(
                    tone: .attention,
                    title: engineMessage.isEmpty ? "Needs attention" : engineMessage,
                    // Attention now covers a run that copied most of its files
                    // and left one behind, not only a run that stopped before
                    // it started, so this cannot claim the destination was
                    // untouched. What is true either way is that nothing was
                    // removed there: the app has no delete operation at all.
                    detail: "Nothing was deleted at the destination."
                )
            case .scanning:
                self = SyncStatus(
                    tone: .working,
                    title: engineMessage.isEmpty ? "Checking for changes…" : engineMessage,
                    detail: "Comparing this folder with the bucket."
                )
            case .transferring:
                self = SyncStatus(
                    tone: .working,
                    title: engineMessage.isEmpty ? "Syncing…" : engineMessage,
                    detail: job.direction == .upload
                        ? "Copying to S3. You can close this window."
                        : "Copying from S3. You can close this window."
                )
            case .verifying:
                self = SyncStatus(
                    tone: .working,
                    title: "Verifying…",
                    detail: "Confirming the copy matches the original."
                )
            case .idle, .watching, .paused:
                if snapshot.filesTotal > 0 {
                    // The engine parks retryable items in the watching phase.
                    // Green here would claim a finished sync that is not one.
                    // This message is StorageSync's own and carries the count.
                    self = SyncStatus(
                        tone: .waiting,
                        title: engineMessage.isEmpty ? "Waiting to retry" : engineMessage,
                        detail: "StorageSync tries the remaining items again shortly."
                    )
                } else {
                    self = SyncStatus(
                        tone: .caughtUp,
                        title: engineMessage.isEmpty ? "All caught up" : engineMessage,
                        detail: "Click Sync Now whenever you want to check for new and changed files."
                    )
                }
            }
        }
    }
}

/// The whole app in one word, for the menu bar glyph and the popover header.
enum OverallStatus {
    case agentUnavailable
    case noSyncs
    case attention
    case waiting
    case working
    case caughtUp

    /// Menu bar glyphs are template images, so these have to read at 16 pt in
    /// one colour. Shape carries the meaning; nothing here relies on tint.
    var menuBarSymbol: String {
        switch self {
        case .attention: "exclamationmark.triangle"
        // The agent is normally unreachable only for the moment between launch
        // and the first connection, so this must not flash a warning glyph. It
        // still has to be distinct from syncing, or a stuck connection would be
        // indistinguishable from working.
        case .agentUnavailable: "ellipsis.circle"
        case .noSyncs: "arrow.triangle.2.circlepath"
        case .waiting: "clock"
        case .working: "arrow.triangle.2.circlepath"
        case .caughtUp: "checkmark.circle"
        }
    }

    var summary: String {
        switch self {
        case .agentUnavailable: "Starting up…"
        case .noSyncs: "No syncs yet"
        case .attention: "Needs attention"
        case .waiting: "Waiting"
        case .working: "Syncing…"
        case .caughtUp: "All caught up"
        }
    }
}

/// Where a job copies from and to, in the order it actually happens.
enum SyncRoute {
    static func remoteLabel(_ job: SyncJob, connection: S3Connection?) -> String {
        let bucket = connection?.bucket ?? "S3"
        return job.remotePrefix.isEmpty ? bucket : "\(bucket)/\(job.remotePrefix)"
    }

    static func text(_ job: SyncJob, connection: S3Connection?) -> String {
        let local = job.localRoot.displayName
        let remote = remoteLabel(job, connection: connection)
        return job.direction == .upload ? "\(local) → \(remote)" : "\(remote) → \(local)"
    }

    static func symbol(_ job: SyncJob) -> String {
        job.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
    }
}

/// A storage balance to draw, and whether it still describes right now.
///
/// The engine replaces a snapshot with a bare blocked one when a drive is
/// unplugged or the bucket cannot be reached, which erases every number in it.
/// The question "what is where" does not stop being worth answering at that
/// moment — it is arguably the moment it matters most — so the app keeps the
/// last complete picture and says how old it is instead of showing nothing.
struct BalanceReading: Equatable {
    var balance: StorageBalance
    var isCurrent: Bool
    /// When the balance was last read from a live snapshot. Only shown while
    /// the reading is stale.
    var asOf: Date?
}

extension Int64 {
    var formattedByteCount: String {
        formatted(.byteCount(style: .file))
    }
}
