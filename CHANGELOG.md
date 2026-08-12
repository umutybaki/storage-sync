# Changelog

## 0.4.0

**Deterministic transfer activity.** Every sync now has a durable, Finder-like
transfer browser that makes newly discovered, waiting, active, completed, and
problem files visible for the current check.

- **Sync Now** remains available while transfers are running. A click is
  acknowledged immediately, then starts one bounded rescan at the next safe
  transfer-batch boundary. Starting or resuming a sync also scans once; there
  are no interval-based scans.
- Automatic interval and filesystem-event scans are disabled. Discovery happens
  only when the app/agent starts, a sync resumes, or the user clicks **Sync
  Now**, so every check has an observable cause.
- The selected sync is event-driven rather than polled. Its activity page is
  reloaded only after the agent commits a newer revision, so merely selecting a
  sync or opening its details cannot trigger a check.
- The transfer browser records the current batch in SQLite and pages 150 rows
  at a time. Queued, active, retrying, completed, failed, and superseded rows
  survive app and agent restarts without loading a large manifest into memory.
- Uploading rows now show the exact request bytes sent for each file. Multipart
  parts are combined into one monotonic file total; durable resume checkpoints
  remain separate, so a sent byte is never misrepresented as acknowledged by
  S3.
- The sync summary keeps aggregate progress and blockers while file-level
  status lives in the table. Filters expose all, active, waiting, completed,
  and issue rows, with Finder reveal and relative-path copy actions.
- Sidebar rows again use native selection highlighting, show only the sync name
  and source → destination route, and move configuration details into an info
  popover. The manager minimum size now keeps every transfer control legible.
- Source-change warnings are shown only when reliable metadata proves that the
  content changed during transfer; routine syncing retains the **Syncing…**
  headline.

## 0.3.0

**Saved credentials.** One set of provider keys can now be saved once, given a
name, and reused by any number of syncs.

- A **Credentials** section in the manager window sidebar lists every saved set,
  with the shortened access key, when the keys were last replaced, and which
  syncs depend on them.
- **Create Sync** offers saved credentials in a menu. A second bucket in the
  same account no longer means typing the keys again.
- Replacing an expired key once fixes every sync using it. The replacement is
  tried against a bucket one of those syncs already uses before it is saved, so
  a wrong key cannot be committed to several syncs at once.
- **Update S3 Credentials…** became **Change Credentials…**: it picks which
  saved set a sync uses, and can still replace the keys inline when that is the
  actual problem. Either way the keys are proved against that sync's own bucket
  before the sync is switched over.
- Deleting credentials is refused while a sync still depends on them, and names
  the syncs instead.

Credentials saved by 0.1.0 and 0.2.0 are adopted into the list on first launch.
The Keychain reference is adopted exactly as it was written — nothing is moved,
copied, or rewritten — so running syncs keep resolving the same item and
resumable progress is untouched.

### Security

- Secrets remain in the macOS Keychain and nowhere else. What the database
  gained is a name, a date, and the access key ID with its middle removed, the
  way AWS's own console shows it.
- `saveCredential` is now the only operation in StorageSync that writes a
  secret. Saving a connection no longer carries one: it names a credential, and
  the engine resolves it at the moment a transfer needs it.
- Reusing saved credentials for a new sync sends no secret over XPC at all.
- Keychain items are written as `AfterFirstUnlockThisDeviceOnly` and explicitly
  non-synchronizable, and carry the credential's name as their label so they are
  legible and removable in Keychain Access.
- Removing a sync no longer deletes the Keychain item its connection pointed at
  when a saved credential owns it. Previously that item belonged to the one
  sync; now it can be shared, and deleting it would have taken another sync's
  keys with it. Covered by a reliability check that was confirmed to fail
  without the guard.

### Also

- The reliability suite gained credential-store coverage: adoption from earlier
  builds and its idempotence, sharing one credential between syncs, refusing to
  point a sync at keys that are not in the Keychain, refusing deletion while in
  use, credentials outliving every sync that used them, duplicate names, and
  renaming leaving both the keys and their reference alone.

## 0.2.0

Replaced the progress bar and the three-count inventory with one storage
balance: what is on this Mac, what is in the bucket, and what is moving between
them, drawn in bytes on one shared scale.

## 0.1.0

First beta. One-way sync between a local folder and an S3-compatible bucket,
with durable multipart upload and ranged download checkpoints, external-volume
identity, and a background agent that keeps working with the window closed.
