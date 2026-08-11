# StorageSync architecture

## Product shape

StorageSync has two native executables in one signed app bundle:

1. `StorageSync` is an `LSUIElement` menu bar app and manager window. It owns setup, status, and explicit user actions.
2. `StorageSyncAgent` is registered with `SMAppService`. It owns scans, retries, manifests, and transfers even when the interface is closed. It is an on-demand job — no `KeepAlive`, no `RunAtLoad` — so launchd starts it when the manager first connects and lets it exit when the manager quits. Quitting StorageSync sends a `shutdown` command that cancels in-flight work and exits the process; nothing restarts it until StorageSync is opened again.

The two communicate over a launchd Mach service. The agent derives the main app's designated code-signing requirement and rejects any XPC peer that does not satisfy it.

## Data flow

```text
SwiftUI app
    │ signed XPC commands and status
    ▼
LaunchAgent / SyncCoordinator
    ├── Keychain credentials
    ├── durable folder bookmark + volume identity
    ├── SQLite WAL
    │   ├── local and remote manifests
    │   ├── reconciliation baselines
    │   ├── transfer queue
    │   └── per-part checkpoints
    ├── local scanner + FSEvents + mount notifications
    └── SigV4 S3 client + network path notifications
```

Each job is one-way: local to S3 or S3 to local. Reconciliation never creates a deletion plan.

On the first pairing of a relative path, if both source and destination already contain that path, the coordinator records their observed fingerprints as the initial baseline and removes any obsolete queued copy. This lets StorageSync take over a half-completed archive without uploading or downloading the existing portion again. Once that baseline exists, later source changes are planned normally.

## Large-scale reconciliation

Local files and paginated S3 listings stream into SQLite in batches of 512. SQLite joins the current local generation, remote generation, and completed-transfer baselines. The coordinator reads joined rows in bounded pages and enqueues each page in one durable transaction. It never constructs a complete in-memory manifest or transfer queue.

Case-folded paths are stored alongside exact paths. The fold models what APFS and HFS+ actually do — Unicode normalization and case, nothing else — so `Gökçe.jpg` and `Gokce.jpg` stay distinct the way they do on disk. On a case-insensitive destination, a single pre-existing key with different casing is reused. If S3 contains multiple keys that genuinely collapse to the same macOS path, every variant is blocked rather than selecting an arbitrary winner.

The same reconciliation pass persists inventory counts for the interface: source files found, destination files found, already-present pairs, and the remaining durable queue. Counts come from the disk-backed manifests rather than an in-memory estimate.

## Transfer durability

Files below 64 MiB use a single request. Larger files use dynamically sized multipart ranges with no more than 10,000 parts and a 5 TiB object ceiling. Default concurrency is two files and two normal-sized parts per file; part concurrency and file permits contract for unusually large parts to keep memory bounded.

For uploads, the engine records the provider upload ID and every accepted part ETag. After a lost response it lists server parts and sends only missing parts. Provider-expired uploads restart as the same logical transfer. Source fingerprints are checked before and after transfer; mutation aborts the multipart upload.

Downloads write verified ranges beneath `.storagesync-partials`. Each checkpoint includes a local SHA-256. On resume every saved range is validated independently — offset, length, presence in the partial file, and digest — and only the ranges that fail are discarded and refetched. Recovery deliberately does not assume the completed ranges form a contiguous prefix: parts arrive in parallel, so a missing or corrupt early range must not throw away a valid later one. The full object is checked again, the remote version is revalidated, and the temporary file is atomically moved or replaced only if the destination still matches the scan plan.

Successful transfer completion atomically stores its reconciliation baseline and removes queue/checkpoint rows. Interrupted `running` or `verifying` rows recover as `waiting` when SQLite reopens.

## Retry model

Per-transfer retries use indefinite capped exponential backoff with full jitter, so a queue of failures spreads out instead of retrying in lockstep. The scan loop that wraps them backs off on the same curve but without jitter, since only one scan per job is ever in flight. The coordinator schedules the exact earliest durable retry, while network and volume events clear stale backoff and wake affected jobs immediately. Authentication, access denial, incompatible responses, and unsafe local paths require attention rather than looping.

Upload jobs use FSEvents for immediate local changes plus a 30-minute safety scan. Download jobs poll S3 every five minutes. A source or destination that changes during a transfer triggers an immediate new reconciliation.

## Distribution boundary

The current packaging script produces an ad-hoc hardened-runtime development bundle. It is suitable for local verification, not public distribution. A release still requires a Developer ID Application identity, notarization, stapling, and final archive/UI validation with full Xcode. The direct-distribution design is intentionally unsandboxed so the background agent can retain user-selected external-volume access; the included App Store entitlement draft is not a claim of App Store readiness.
