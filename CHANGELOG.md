# Changelog

## 0.5.0

**Fixes from a review of the transfer path.** Three behavior changes: a file
that already exists at the destination with a different size is no longer
treated as a copy; a destination that changed while its source did not is no
longer overwritten; and system files such as `.DS_Store` and `Thumbs.db` are
no longer copied.

### Behavior changes

- A file that already exists at the destination with a different size is no
  longer taken as a copy of the source. That used to report the source as
  backed up when it never was — another camera's `IMG_0001.JPG` in the bucket,
  or an object some other tool left half-uploaded. Such a file is now left
  untouched on both sides and reported until one of them is renamed or
  removed. Files of the same size are still adopted as before.
- A file that changed at the destination while its source did not is no
  longer copied over. Editing a restored photo used to see the edit replaced
  by the next sync, and an object changed in the bucket by someone else was
  overwritten. Such changes are now reported and left alone; a change that kept
  the file's size, such as a moved timestamp, is accepted quietly. A change to
  the source is still copied as before.
- `.DS_Store`, `._` AppleDouble files, `Thumbs.db`, `desktop.ini` and volume
  index and trash folders are no longer copied in either direction. Copies
  already in the bucket are left where they are.

### Fixes

- One file that cannot be read or written — a bad sector, a permission
  problem, a download whose folder name is already taken by a file — now fails
  on its own. It used to be reported as a missing drive, which stopped every
  other transfer in the sync and repeated at every retry.
- On download syncs, an object archived to S3 Glacier, or one encrypted with a
  key these credentials cannot use, now fails on its own instead of stopping
  the whole sync with a request to sign in again.
- A folder the scan could not read no longer makes StorageSync forget what it
  had already copied from it, which let an edit made in the meantime be taken
  as already copied.
- Uploads now tell S3 what they expect to find: nothing, or the version that
  was there when the upload was planned. An object that appeared or changed in
  the meantime is preserved. If the provider rejects conditional writes,
  StorageSync stops the job and reports the incompatibility.
- A file whose bytes are already in the bucket is no longer uploaded again
  just because its timestamp moved — for example after `touch`, or a daylight
  saving change on a FAT-formatted drive. The bytes are compared with the
  object's ETag first.
- Downloads from Amazon S3 are now checked against the object's MD5 when its
  ETag is one. A download that fails verification three times in a row is
  reported instead of being fetched forever.
- An object that shrank while it was downloading is planned again instead of
  failing for good.
- A temporary error on one file no longer cancels the other transfers that
  are already in progress.
- Retrying a waiting file no longer rescans the whole folder and bucket first.
- A file that keeps changing while it is being copied no longer makes
  StorageSync re-check everything back to back; repeated re-checks wait up to
  five minutes, and **Sync Now** still checks immediately.
- Queueing a large first sync no longer slows down with the square of its
  size.
- Partial downloads that can no longer be resumed are deleted, and removing a
  sync now deletes all of its partial files. Replacing a failed upload aborts
  its unfinished multipart upload in the bucket instead of leaving it behind.
- Ejecting a drive now waits for StorageSync's checkpoint, and reconnecting it
  wakes the sync, even when the drive mounted under a different name.
- A drive that was replaced, or a folder copied to a new drive, can be chosen
  again with **Choose Folder…** instead of removing and recreating the sync.
- A pasted region, bucket name, secret key or folder name with a stray space
  or line break no longer fails as rejected keys.
- A Mac clock that is out of step with S3 is reported as a clock problem and
  retried, not as rejected keys. A request body damaged in transit is retried
  instead of failing the file.
- Object names that begin or end with a space are no longer altered when the
  bucket is listed, and object names are encoded strictly in requests, so a
  `+` or `;` cannot be read two ways. Listings ask for URL-encoded names, so
  one object with an unusual character in its name can no longer stop every
  scan.
- Storage providers that format ETags differently in a listing and in a
  direct request no longer make every download look changed.

## 0.4.2

**A second pre-release review, of the whole tree.** No feature changes. Eight
defects: two that crashed the background agent repeatedly, one that could
silently skip a change made in the bucket, and five that left the app or a
drive waiting.

- A storage provider that reports a nonsensical file size, or that lists the
  same piece of an interrupted upload twice, can no longer crash the
  background agent. Either used to take the agent down, after which it
  restarted, reached the same object and crashed again.
- Pressing **Resume** while a sync was still stopping could start a second
  check for the same sync. Two checks at once could erase each other's record
  of what is on the drive, copy one file twice, and leave an unfinished upload
  behind in the bucket.
- On download syncs, two bucket objects whose names differ only in
  capitalization no longer cause a later change to be skipped without notice.
  Such a pair is still reported and skipped until one is renamed, but it no
  longer discards what StorageSync knew about that file.
- Ejecting an external drive is no longer refused because a *different* sync
  was in the middle of a large transfer. StorageSync now steps out of the way
  as soon as the eject is requested, still finishing the checkpoint it owes.
- **Quit** no longer leaves the app running without a menu bar icon while it
  waits for the background agent. The agent still finishes writing down
  in-flight work before it exits.
- Selecting a sync that is transferring many small files no longer piles up
  requests to the background agent faster than they can be answered.
- A storage provider that cannot serve partial downloads is now named as
  incompatible, instead of failing each large file in turn with a message
  about byte counts.

## 0.4.1

**Reliability and safety fixes from a full pre-release review.** No feature
changes. Fifteen defects, several of which could stop a sync indefinitely or
overwrite a file in the bucket.

- A single file can no longer stop a whole sync. A file dated far outside the
  normal range used to crash the background agent, which then restarted,
  reached the same file and crashed again. An unreadable file, or one deleted
  while a check was running, used to end the whole check and report it as a
  disconnected drive. A file that can never be copied — too large for S3, for
  instance — used to stop every other file with it, and **Sync Now** only ran
  into the same file again. Each of these now affects that one file.
- Two files whose names differ only in capitalization can no longer be sent to
  the same place in the bucket. Previously each could overwrite the other on
  alternating checks. Such a pair is now reported and skipped until renamed.
- Quitting no longer discards a piece of a large file that had already been
  accepted by S3 but not yet recorded. StorageSync now waits for in-flight work
  to be written down before exiting.
- Only StorageSync itself can talk to its background agent. The previous check
  could be defeated by a short-lived process, and the app did not verify the
  agent's identity at all.
- Turning StorageSync off in **Login Items** now stays off. It used to switch
  itself back on at the next launch.
- Waiting files describe why they are waiting in every language, not only in
  English. On a non-English system a file blocked on an unplugged drive
  previously read as merely queued.
- Long-running syncs no longer accumulate network connections, and file icons
  in the transfer list are no longer re-resolved on every progress update.

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
