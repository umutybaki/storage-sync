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
    ├── local scanner + mount notifications
    └── SigV4 S3 client + network path notifications
```

Each job is one-way: local to S3 or S3 to local. Reconciliation never creates a deletion plan.

On the first pairing of a relative path, if source and destination both contain a file of the same size there, the coordinator records their observed fingerprints as the initial baseline and removes any obsolete queued copy. This lets StorageSync take over a half-completed archive without uploading or downloading the existing portion again. Once that baseline exists, later source changes are planned normally.

## Locations and routes

`StorageLocation` is an independently persisted configuration record with a
`LocationID`, a name, and one immutable target:

- `local(LocalRoot)` owns the folder bookmark and expected volume identity.
- `s3(connectionID, prefix)` selects a bucket connection and its normalized prefix.

`S3Connection` still owns transport configuration and a Keychain reference.
Credentials are independent records; there is no new copy of credential material.
`StorageProvider` supplies tested configuration presets for AWS, Cloudflare R2,
and custom S3 endpoints. Provider labels for existing connections are inferred
from their endpoints, so adoption does not rewrite working configurations.

Jobs now carry `sourceLocationID` and `destinationLocationID`. The repository
resolves these references when saving a job, deriving its execution direction,
`localRoot`, `connectionID`, and `remotePrefix`. Those existing fields remain
resolved compatibility inputs for the durable transfer engine. Saved targets
and connection endpoints cannot be silently retargeted, so the projections do
not diverge from their authoritative locations. Renaming a location changes no
execution state. Reversing a job or choosing another bucket requires a new job;
explicit folder reselection retains the existing multipart invalidation rule.

The version-4 database migration creates a `locations` document table and adopts
legacy job routes in one transaction. It reuses exact targets, preserves all job
identities and state, and is idempotent. Similar folder paths with different
bookmarks or volume identities are not merged. No files, bookmarks, credentials,
manifest entries, baselines, or checkpoints are moved by this adoption.

Removing a job retains saved locations, their bookmarks, and their connections.
Removing a referenced location is refused. An unused location releases its
bookmark only after both location and job references are checked; uncertain
answers preserve it. Bucket connections can be removed only when neither jobs
nor locations refer to them. Saved credentials are always retained.

The XPC commands `locations`, `saveLocation`, and `removeLocation` expose
configuration only. The UI reads locations separately so an older running agent
does not make existing syncs disappear during an app update. New setup waits
until the agent supports locations. The UI uses the existing native sidebar,
grouped forms, sheets, and alerts: location setup is separate from the From/To
sync form, and the same location editor is available inline.

Only Mac-folder-to-bucket routes are executable in this version. Two cloud
locations can be represented, but the repository rejects that route until the
transfer engine supports it. Deletion propagation remains absent.

## Credentials

A saved credential is a first-class record: an identifier, a user-chosen name, a
Keychain reference, dates, and the access key ID with its middle removed for
display. The secret is in the Keychain under that reference and nowhere else, so
the record is safe to keep in SQLite, send over XPC, and draw on screen.

Connections hold no secret of their own. They name a credential's Keychain
reference and the engine resolves it at the moment it needs a request signed,
which is what lets several syncs share one set of keys and what makes replacing
an expired key a single edit.

Exactly one operation writes a secret. Saving a connection does not: it verifies
that the referenced item exists — without reading it — and then writes only
configuration. Pointing a sync at credentials that are already saved therefore
sends nothing sensitive anywhere; keys travel only in the moment they are first
typed in or replaced, and the interface process never reads one back.

Sharing decides the deletion rules. A saved credential outlives the syncs that
use it and is deleted from the Credentials list only, which refuses while a sync
or saved location still depends on it. Removing a sync cleans up a Keychain item only when no saved
credential owns it and no connection still refers to it; every uncertain answer
counts as still in use, because an orphaned item is a mess and a deleted one is
data loss.

Credentials written before this store existed are adopted on agent start. The
reference is adopted exactly as it was, so nothing moves and no running sync
notices; the item is read once, only to fill in the masked access key, and a
failed read is not a reason to skip the adoption.

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

Discovery is deliberately explicit for both directions: a job scans when the app or agent starts, when a sync resumes, and when the user clicks **Sync Now**. There are no interval scans and no filesystem-event scans, so every check has a cause the user can point at. A source or destination that changes during a transfer triggers an immediate new reconciliation.

## Distribution boundary

The packaging script produces a hardened-runtime bundle signed with a Developer ID Application identity when the login keychain has one, and ad hoc otherwise. It is for local verification. Public releases go through `release-app.sh`, which adds notarization, stapling, and a Gatekeeper assessment; that path first ran end to end on 2026-11-08 for v0.6.0-beta.1. The direct-distribution design is intentionally unsandboxed so the background agent can retain user-selected external-volume access; the included App Store entitlement draft is not a claim of App Store readiness.
