# StorageSync agent handoff

This repository contains a deliberately small native macOS menu-bar app for durable, one-way synchronization between a local folder and an S3-compatible bucket. The local folder may be on internal storage or an external SSD/USB drive. Upload and download jobs are both supported. Source deletions must never delete destination content.

## Product contract

- Keep the UI minimal and recognizably native to macOS. The current product shape is a `MenuBarExtra` plus a small SwiftUI manager window.
- Copy new and changed files in exactly one configured direction.
- Never propagate deletion. There is intentionally no S3 object-delete operation.
- On a first pairing, adopt a destination object/file already present at the same relative path instead of copying it again.
- Show source files found, destination files already present, and items remaining.
- Support multi-terabyte, multi-day work without holding a full manifest or file in memory.
- Persist multipart upload and ranged-download progress in SQLite and recover after process, network, or external-volume interruption.
- Resume only when the same external volume can be identified confidently.
- Credentials belong in macOS Keychain only. Never print, copy, log, or request them in chat or shell commands.

Do not declare the app complete from automated tests alone. All real AWS/external-drive checks listed below were completed. On 2026-08-04 the user narrowed the deliverable by waiving Apple-signed background registration, notarization, and public-release validation because no signing identity is available.

Superseded in part on 2026-08-11: background agent registration turned out not to need an Apple identity at all, and it now works ad-hoc. See **Background agent**. Notarization and the public-release path remain unproven and must not be implied as tested.

## Workspace and toolchain

- Workspace: `<workspace>` (moved into iCloud Drive after 2026-08-04; earlier notes below say `<former workspace>`)
- Build products under `.build` inherit iCloud file-provider extended attributes, which invalidate a code signature. `scripts/package-app.sh` stages, strips, signs and verifies in `$TMPDIR`, then moves the finished bundle into `.build`.
- **`codesign --verify --strict` on `.build/StorageSync.app` always fails, and that is not a real failure.** The moment the bundle lands in iCloud Drive the file provider puts `com.apple.FinderInfo` back on it, and `xattr -cr` cannot keep it off — the attribute is provider-managed. The reported error is `resource fork, Finder information, or similar detritus not allowed`. Verified on 2026-08-12: the same bundle copied out with `ditto --noextattr --norsrc` to a non-iCloud path reports `valid on disk` and `satisfies its Designated Requirement`. To check a signature, copy it out first — or check what `install-app.sh` puts in `/Applications`, which is the copy that actually matters.
- Moving the workspace invalidates the SwiftPM module cache. Clear `.build/*/ModuleCache` if the compiler reports a precompiled module built with a different module cache path.
- This directory is not currently a Git repository, so there is no undo. Copy anything before you replace or delete it.
- Full Xcode is not installed; Apple Command Line Tools are installed.
- Swift 6.3.3 on this Mac needs an SDK passed explicitly.
- **Build against `MacOSX26.sdk`.** macOS picks the macOS 26 interface or the legacy compatibility one from the SDK recorded in `LC_BUILD_VERSION`, so an older SDK silently produces a dated-looking app. The deployment target stays macOS 14, so the binary still reports `minos 14.0`. `StorageSyncApp` no longer compiles against `MacOSX15.4.sdk` because it uses `ToolbarSpacer` behind an `if #available(macOS 26.0, *)` check, and that symbol is absent from the older SDK. Verify with `vtool -show-build-version` after packaging.
- Make source edits in place with whatever patch/edit tool the harness provides, and leave unrelated user files alone. (This line used to name `apply_patch` specifically; that tool does not exist in every harness that reads this file.)

Run the reliability suite with:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
CLANG_MODULE_CACHE_PATH=/tmp/storagesync-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/storagesync-swiftpm-module-cache \
swift run \
  --disable-sandbox \
  --cache-path /tmp/storagesync-swiftpm-cache \
  --config-path /tmp/storagesync-swiftpm-config \
  --security-path /tmp/storagesync-swiftpm-security \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
  storagesynctest
```

Package the app with:

```sh
./scripts/package-app.sh
```

The result is `.build/StorageSync.app` inside the workspace directory above. (Earlier notes gave an absolute path under `<former workspace>`; that directory no longer exists.)

## Live state

**Never copy numbers out of this section into an assertion. Read the database.** The state below was true at one instant and the app keeps running; the previous version of this section went stale without anyone noticing and told several sessions to expect a caught-up sync that had in fact moved on.

Query it read-only, never with a writable handle, while the agent is running:

```sh
DB="$HOME/Library/Application Support/PhotoSync/PhotoSync.sqlite"
sqlite3 "file:$DB?mode=ro" "SELECT payload FROM snapshots;"
sqlite3 "file:$DB?mode=ro" "SELECT status, COUNT(*) FROM transfers GROUP BY status;"
```

Observed on 2026-08-12, with the installed app and its `SMAppService` agent both running:

- One job only: `Photos` / `36D89D66-0A44-43BE-A5E2-629008531392`, upload, empty remote prefix, from `/Volumes/EXTERNAL-SSD/Camera/Photos` to bucket `example-bucket` (`eu-north-1`, virtual-host addressing). One connection.
- Actively transferring the user's real photo library: 5,562 local / 5,412 remote / 5,412 already present, 212 in the queue at scan time, 150 still to go, 0 saved part rows.
- The inventory identity holds in production: source found = already present + remaining.
- Filesystem observed during testing: ExFAT.

### Corrections to what this file used to say

The following were recorded as current and are not. They are corrected here rather than deleted, because a later session should be able to tell a stale claim from a retracted one:

- The sync is **not** parked at 5,197 / 5,197 / 5,197 with an empty queue. That was a real observation on 2026-08-04; the library has grown since.
- `Drive Loss Restore` / `5DE9B461-D119-4B8C-965D-1F7C62703E71` **no longer exists**, and neither does its connection. Only the `Photos` job remains. Do not expect it, and do not treat its absence as damage.
- The disposable 96 MiB fixture is **gone everywhere**: `/Volumes/EXTERNAL-SSD/StorageSync Restore Test/` does not exist, neither does `Camera/Photos/StorageSync Reliability Test/`, and `/private/tmp/storagesync-96MiB-multipart-20260804.bin` is gone. The old instruction "do not delete either copy without asking" now protects nothing.
- Whether the S3 object `StorageSync Reliability Test/storagesync-96MiB-multipart-20260804.bin` still exists in the bucket was not re-checked. Confirm before assuming either way.

The historical evidence recorded below still stands as evidence — those runs happened and were verified at the time. What no longer stands is the claim that their fixtures are still on disk.

Before any new real-world validation, re-read the live state and work from what you find. The user's real photo library is the source; treat every path in it as irreplaceable.

## Real-world evidence already obtained

Each item below was observed and verified when it was recorded. The disposable files several of them mention have since been cleaned up — see **Corrections** above — so treat these as a log of what was proven, not as a description of what is currently on disk.

- Real AWS SigV4 requests work with the user's credentials. An opaque continuation-token encoding bug that caused signature mismatch was fixed.
- A half-synced initial pairing correctly adopted existing remote paths. It queued only the 115 genuinely missing objects instead of re-uploading 5,196 files.
- Real internet loss stopped work and resumed it automatically after connectivity returned.
- External-drive eject/replug was tested. ExFAT regenerated file identifiers, exposing false re-uploads; durable content identity versus same-mount identity was fixed.
- After that fix, replugging the original SSD resumed only genuinely missing work. The user confirmed successful recovery.
- Subsequent remounts returned to 5,197/5,197 with zero re-upload.
- A 96 MiB object was uploaded by the background helper while the UI was closed. The remote ETag proves three-part multipart upload.
- Missing external volume produces the `localVolumeUnavailable` blocker and automatically clears when the same volume returns.
- The helper was manually bootstrapped and continued work with the UI closed. (The bootstrap was believed necessary because the app is ad-hoc signed; on 2026-08-11 the real cause was found to be a bug in the agent's peer validation. See **Background agent**.)
- A real AWS ranged download was interrupted after durable 32 MiB checkpoints existed. SQLite showed two completed range parts (64 MiB total), the transfer recorded two retries, no final destination name appeared early, and the helper completed automatically after connectivity returned. The final 96 MiB SHA-256 exactly matched the source.
- The native **Remove Sync…** flow was exercised against both disposable sync definitions. It removed only configuration/durable state and orphaned connection material. The source, restored local final file, original job, and S3 object all remained intact.
- A first live destination-drive eject attempt caught a real 32 MiB completed range checkpoint, but macOS correctly refused the non-forced eject because the then-running helper still had the partial file open. `diskutil` reported the helper PID as the dissenter. No forced action was attempted, and the download completed with the correct SHA-256.
- After adding native Disk Arbitration coordination, the retry caught a new transfer at one complete 32 MiB part and macOS successfully ejected `EXTERNAL-SSD` normally during the active download. SQLite showed the same transfer durably waiting at 33,554,432 / 100,663,296 bytes with part 1 complete and a 64-character SHA-256; no final destination existed. After the user physically reconnected the same SSD, StorageSync cleared `localVolumeUnavailable`, resumed automatically, completed with the exact source SHA-256, and removed terminal checkpoints. The original upload job returned to 5,197 / 5,197 / 5,197 with zero queue, proving the remount caused no re-upload.
- Live credential recovery was tested on another real ranged download. Only the disposable job's Keychain credential was removed after out-of-order part 2 completed. The same transfer ID and saved checkpoint survived helper restart and the native authentication error appeared. After the user used **Update S3 Credentials…**, StorageSync resumed automatically, produced the exact SHA-256, returned both jobs to `All caught up`, and atomically removed the terminal transfer and saved part. Automated request-range assertions separately prove that the preserved out-of-order part is not downloaded again.
- Real physical interruption during multipart upload is proven. The exact disposable source was temporarily expanded to 512 MiB (16 × 32 MiB parts). Transfer `DE62869B-9737-465B-A8D9-9C1CA39DDE9C` saved out-of-order part 2 at 33,554,432 / 536,870,912 bytes under one multipart upload ID. A normal, non-forced eject succeeded while the upload was active. With the volume absent, the same transfer, upload ID, part-2 ETag, checksum, and completed-byte count remained durably waiting. After physical reconnect, the first resumed batch filled parts 1 and 3 around preserved part 2, then all 16 parts completed under the unchanged upload ID. This is direct evidence that S3 `ListParts` adoption excluded the already-uploaded part rather than sending it again.
- The resulting 512 MiB S3 object was independently downloaded by `Drive Loss Restore`; its SHA-256 `9acca8e8c22201155389f65abbf6bc9723edc7384ead80503839f49dcc56d767` exactly matched the upload source. The disposable source was then restored to its original 96 MiB content, uploaded again, independently downloaded again, and all local copies returned to SHA-256 `fe16ba90394f5abf7d9bb2e42f8b93d1cfcd3a214ad2d8fbc0b866afe23ff601`.
- The automated suite passes and covers crash recovery, lost multipart responses, lost completion response, expired multipart IDs, bounded parallel parts, cancellation, source mutation/deletion, upload/download drive loss, ranged download resume, corrupt partial recovery, path/symlink safety, package-contents scanning, bounded scanner backpressure, S3 signing/pagination/timestamp decoding/error classification, initial adoption, case collisions, remount identity, stable remote identity, job-removal isolation, graceful-unmount preparation, and disk-backed manifest pagination.

## Engine and safety changes (through 2026-08-11)

- `TransferPolicy` already chooses part size dynamically, enforces the S3 10,000-part limit, permits up to the S3 5 TiB object maximum, and bounds in-memory part concurrency.
- `StorageSyncTestRunner` now explicitly plans a 5 TiB object, verifies full byte coverage, checks the 10,000-part and 5 GiB-part ceilings, and rejects 5 TiB + 1 byte.
- `LocalScanner.files(at:)` now uses a bounded 512-item `AsyncThrowingStream` buffer with lossless retry/backpressure. This prevents millions of filesystem entries from accumulating in memory while SQLite persists batches.
- Local scanning and reconciliation now exclude `.storagesync-volume-id` and `.storagesync-partials` at every path depth (both names are defined once, in `StorageSyncCore.ReservedName`). This prevents a sync targeting a nested folder from leaking StorageSync state into a parent sync. Reserved state already leaked by an older build is silently ignored without deleting it or showing a permanent unsafe-path warning.
- The native manager window now has **Remove Sync…** behind an ellipsis menu and a destructive confirmation that explicitly says local, external-drive, and S3 content remains. Removal cancels the selected job, transactionally removes only its SQLite state, deletes only its bookmark and orphaned Keychain entry, cleans exact job-owned download partials, and best-effort aborts incomplete multipart sessions. It never calls an S3 object-delete operation.
- The reliability suite adds job-removal isolation coverage, including shared connections, transfer parts, baselines, snapshots, and disk-backed manifests.
- StorageSync now participates in macOS Disk Arbitration unmount approval. A normal eject request suspends every sync rooted on that volume, cancels and awaits active work so `FileHandle` cleanup and SQLite checkpoints finish, prevents event races from reopening the volume, and only then approves unmount. If checkpointing cannot finish within 20 seconds, StorageSync safely declines with a retry message rather than permitting or forcing an unsafe unmount. Jobs automatically resume after mount/unmount events or a declined eject grace period.
- The volume event loop no longer calls `wakeAll()` during `willUnmount`; it prepares the affected volume instead. A reliability test verifies that preparing one external volume blocks only matching jobs and leaves other-volume jobs untouched.
- Ranged-download recovery no longer assumes completed checkpoints form a contiguous prefix. It validates every saved range independently, removes only invalid individual checkpoints, and requests only missing ranges. This was required by the live credential-loss transfer, where parallel part 2 completed before part 1. A regression test writes only part 2 into a sparse/offset partial, proves parts 1 and 3 are each fetched once, proves part 2 is fetched zero times, and verifies the final bytes.
- The full reliability suite passed after all of these changes.

## Correctness pass (2026-08-12)

An audit of the whole tree against this file. Three real defects, each now covered by a check that was confirmed to fail before the fix and pass after it.

- **Path canonicalization folded diacritics and character width.** `Reconciler.canonicalLocalPath` folded case, diacritics *and* width, but macOS case-insensitive volumes fold only case. `Gökçe.jpg` and `Gokce.jpg` collapsed to one canonical path though APFS keeps them as separate files. Two ways that hurt: both remote variants were dropped as a "case collision" so neither transferred, and — worse — a local file could join an unrelated remote row through that shared canonical path, get a `remoteKeyOverride` for the other spelling, and upload over it. The user's current library is all-ASCII so nothing was actually damaged; the bug was latent, not triggered. Folding is now case-only.
- **Real S3 `LastModified` never parsed.** `S3XML` used a default `ISO8601DateFormatter`, which rejects fractional seconds — and `ListObjectsV2` always sends them (`2009-10-12T17:50:30.000Z`). Confirmed against live data: all 5,350 remote manifest rows had no `lastModified`. Impact was limited because `remoteMatches` prefers checksum then ETag, both present. The suite masked it by feeding a fixture without milliseconds. Now uses `Date.ISO8601FormatStyle`, which parses both shapes and is `Sendable`, so one shared instance covers a thousand-object page.
- **`list` returned a continuation token on an untruncated page.** `stageRemoteManifest` pages with `while token != nil`, so a provider that echoes a token on its last page would list forever. The token is now reported only when the page says it is truncated.

Also in this pass:

- Reconciliation no longer issues two SQLite deletes per already-present path per cycle. It deletes only paths that actually have a queue row, and the repository batches those into one statement per chunk. Steady-state cost is now proportional to outstanding work instead of to library size — it was ~10,700 no-op statements per cycle on the live job and would have been millions at the multi-terabyte scale the product contract promises.
- The agent logs a failed `SyncCoordinator.start()` and a failed Disk Arbitration session. Both previously left an agent that looked healthy to launchd while doing nothing, or silently ejecting without waiting for a checkpoint.
- `Tests/StorageSyncCoreTests/` was removed. It was in no target, had never been compiled, and could not be: `import Testing` does not resolve against Command Line Tools here. Every assertion it held that the suite lacked was ported into `StorageSyncTestRunner` first — full-jitter and attempt-limit retry behaviour, first-part offset, recovered transfers being immediately runnable, the multipart upload ID surviving a checkpoint, unsafe keys being reported and not merely skipped, and an unchanged file with a matching baseline not being requeued.
- Reserved names (`.storagesync-partials`, `.storagesync-volume-id`) and the SHA-256 hex helper now have one definition each in `StorageSyncCore` instead of five and four copies. `discardCheckpoints` resolves the partials directory through the same symlink validation the write path uses. Removed the dead `S3XMLParserDelegate.Mode`, the misleading `_ = scopedRoot` lifetime hack, and a duplicated 30-line `addTask` block in `runCycle`.

## Interface pass (2026-08-04)

A UI/UX-only pass followed. No engine, persistence, S3, or safety behaviour was touched; the reliability suite passed unchanged against the macOS 26 SDK.

- The build now uses `MacOSX26.sdk`, which is what actually grants the macOS 26 appearance. `scripts/package-app.sh` defaults to it and fails with an explanatory message when it is missing. `scripts/release-app.sh` already resolved the current default SDK, so it needed no change.
- `Sources/StorageSyncApp/SyncPresentation.swift` is new. It owns the single `SyncStatus` derivation (tone, title, detail, symbol, tint), route labels, the three inventory numbers, and byte/percent formatting. The menu bar and the manager window both read it, so they can no longer disagree. It also fixes a real misreport: a job parked in the `watching` phase with retryable items left used to render as a green "all caught up".
- The manager window now switches the app to `.regular` activation while it is open and back to `.accessory` when it closes. As a pure accessory the window had no menu bar, which silently broke ⌘C/⌘V in the credential fields, ⌘W, and ⌘Q. Demotion is reconciled against the live `NSApp.windows` list rather than trusting `onDisappear`.
- Job actions moved out of the content area into the window toolbar, with `navigationTitle`/`navigationSubtitle` and a `ToolbarSpacer` group split on macOS 26. The detail pane is a grouped `Form`, matching System Settings.
- The sidebar carries per-job status and a footer stating whether the background agent is reachable. Agent availability was previously tracked but never shown anywhere except the menu bar glyph.
- The menu bar popover was rebuilt on the Wi-Fi/Control Center idiom: fixed 320 pt width, hover-highlighted rows, per-job pause/resume, inline progress.
- Create Sync was reordered to direction → folder → bucket → keys, accepts a dragged folder, defaults the sync name to the folder name, and names what is still missing instead of only dimming the button.
- Status is carried by four distinct symbols rather than four colours of one dot, and all live numbers use monospaced digits so rows stop reflowing as they tick.

Not verified visually: this session had neither Screen Recording nor Accessibility permission, so the running app could not be screenshotted or inspected through the accessibility API. Verification was a clean warning-free build, the passing reliability suite, and a stable launch with no runtime log errors.

Repackage the app after any source change with `./scripts/package-app.sh`. It signs and verifies in `$TMPDIR` before moving the bundle into `.build`, so a clean run means the signature is good — see the note about verifying it again afterwards under **Workspace and toolchain**.

## Background agent

On 2026-08-11 the user asked that quitting StorageSync stop everything, so the agent is deliberately **not** a KeepAlive job any more. `Packaging/app.photosync.agent.plist` has `KeepAlive` removed and `RunAtLoad` false; launchd starts the agent on demand through its Mach service when the manager connects. Quit sends the `shutdown` command (`AgentCommandKind.shutdown`), which calls `SyncCoordinator.stop()` and exits. `AppModel.shutdownAgentForQuit` cancels polling and the maintenance loop *first*, because either would restart the agent it is trying to stop. Do not restore `KeepAlive` without asking: it would silently undo this.

The trade-off is intentional and was the user's explicit call: unattended syncing now requires StorageSync to be running. Closing the manager window still keeps it going; only Quit stops it.

Superseded on 2026-08-11. Manual `launchctl bootstrap` of a development plist is no longer needed and should not be used: it hides the bug it used to work around.

The app registers `Packaging/app.photosync.agent.plist` with `SMAppService` and this works with an ad-hoc signature. No Apple identity is required for background syncing. Install with `./scripts/install-app.sh` and open the app once.

Two defects made the agent look impossible to launch without an Apple identity, and both are fixed:

1. `XPCPeerValidator` located the app from `CommandLine.arguments[0]`. launchd starts a bundled `BundleProgram` with a *relative* argv[0] (`Contents/Helpers/StorageSyncAgent`) and a working directory of `/`, so the validator resolved the app to `/Contents/MacOS/StorageSync`, failed to build a requirement, and refused every connection. The agent ran while appearing unreachable. It only ever worked when bootstrapped by hand, because that gave it an absolute argv[0] — which is exactly why the manual workaround masked the bug. It now asks the kernel for its own path with `_NSGetExecutablePath`.
2. `AppModel` refused to register at all unless the bundle had a signing team identifier, and raised an alert about ad-hoc signing instead. Registration is now unconditional and self-healing.

launchd stores the agent's program path and a code requirement taken from the registering bundle. Moving the app, replacing it with a new build, or letting iCloud add extended attributes to the bundle leaves a record launchd refuses to spawn (`launchctl print gui/501/app.photosync.agent` then shows `job state = spawn failed` and `last exit code = 78: EX_CONFIG`). `AppModel.maintainBackgroundServices` detects an agent that has been unreachable for 30 seconds and re-registers it, backing off to ten minutes. Re-registration restarts the agent and interrupts a transfer, so do not shorten that grace period.

Diagnose with:

```sh
launchctl print gui/501/app.photosync.agent | grep -E 'job state|last exit|runs ='
log show --last 10m --info --predicate 'subsystem == "app.photosync.agent"'
```

An ad-hoc rebuild changes the helper's Keychain code identity. macOS may show a Keychain access prompt when the new helper first reads the saved credential. Ask the user to choose **Always Allow** if offered. A blocked helper can look like a long `Checking for changes…` scan; a one-second `sample` previously proved the wait was inside `SecItemCopyMatching`.

Do not expose credentials while diagnosing. The application database is:

`~/Library/Application Support/PhotoSync/PhotoSync.sqlite`

Credential material is not stored in that database.

## Remaining real validation

1. **Unexpected physical interruption during multipart upload**
   - Complete. A 512 MiB version of the disposable object was normally ejected at a durable out-of-order part-2 checkpoint, survived physical disconnect with the same multipart ID, resumed around the preserved server part, completed all 16 parts, and was independently restored with an exact SHA-256 match.
   - The disposable object was returned to its original verified 96 MiB content after the test. No forced unmount was used.

2. **Real restore/download destination-drive loss**
   - Complete. Basic real restore, network interruption, ranged checkpoint reuse, automatic completion, final SHA-256 integrity, normal safe eject during an active range download, missing-volume persistence, same-drive reconnect, automatic completion, and no cross-job re-upload are all proven.
   - The `Drive Loss Restore` definition and its disposable destination copy have since been removed. Repeating this test means creating a new disposable download job and fixture, which needs the user's explicit go-ahead first.
   - Never force-eject in future tests.

3. **Credential rotation recovery**
   - Complete using controlled Keychain credential loss without changing the user's AWS account.
   - A real range transfer was stopped after part 2 completed, only the disposable connection's Keychain item was deleted, and the helper restarted. The same transfer ID and checkpoint survived and the native `credentialsUnavailable` recovery UI appeared.
   - After the user submitted valid credentials through **Update S3 Credentials…**, the helper automatically resumed, both jobs reached `All caught up`, the final SHA-256 matched exactly, and terminal transfers/parts were removed.
   - The out-of-order checkpoint fix is packaged, strict-signature verified, running, and its regression test proves the preserved part is not requested again. Automated S3 transport coverage separately proves expired-token responses classify as authentication failures.

4. **Production background registration and release path**
   - Background registration is no longer waived and no longer blocked. On 2026-08-11 the ad-hoc signed app installed to `/Applications` registered its agent through `SMAppService`, launchd spawned it (`job state = running`, `runs = 1`, never exited), and the app held a live Mach connection to it with no rejected connections. See the **Background agent** section for the two defects that were fixed.
   - Still unproven for a *notarized* release: Developer ID signing, notarization, stapling, and Gatekeeper assessment. Those need an Apple identity.
   - Still unproven: login-restart survival and helper replacement across an app update.
   - Install/use an Apple Development or Developer ID Application identity.
   - Package with `STORAGESYNC_SIGNING_IDENTITY="..." ./scripts/package-app.sh`.
   - `scripts/release-app.sh` now provides a fail-closed Developer ID release workflow using a `notarytool` Keychain profile. It verifies app/helper Developer ID signatures, notarizes a temporary ZIP, staples and validates the app ticket, runs Gatekeeper assessment, and emits a versioned final ZIP plus SHA-256 without accepting notarization secrets on the command line.
   - The release script passes `zsh -n`; its missing-identity and Apple-Development-for-public-release guards were exercised and fail before packaging or network access.
   - Validate actual `SMAppService` registration, login restart, UI-closed syncing, helper replacement across app updates, hardened-runtime signing, archive validation, and notarization.
   - `notarytool` and `stapler` are already available from Command Line Tools. Full Xcode remains required for the planned archive/UI-automation checks, and an Apple signing identity is required for every remaining live check.

5. **Final completion audit**
   - The full automated suite passes, including the checks added on 2026-08-12.
   - The packaged development bundle passed `codesign --verify --deep --strict`; it is intentionally ad-hoc signed with hardened runtime because no Apple identity is installed.
   - The audit taken after the final physical-upload interruption on 2026-08-04 found both jobs `All caught up`, zero transfer rows, zero saved parts, the original job at 5,197 / 5,197 / 5,197, and matching SHA-256 for all three local disposable-file copies. That was true then; see **Live state** for now.
   - As of 2026-08-11 the helper is started by launchd from `SMAppService`, not bootstrapped by hand, and its Mach service is active. Re-confirmed running on 2026-08-12.
   - A source audit on 2026-08-12 again found no S3 object-delete operation anywhere in the tree. `abortMultipartUpload` issues `DELETE` against an incomplete upload ID, which discards unfinished parts and never touches a completed object.
   - Every product-contract item in the narrowed development scope has direct automated and/or real-world evidence. The goal may be closed; production signing remains documented as waived rather than proven.

Before further real validation, read the live snapshot and queue rather than expecting particular numbers, and confirm what you find with the user if it looks unexpected. Only the `Photos` job exists; the disposable jobs from earlier sessions are gone. Do not recreate the removed accidental upload job.

## Safety while resuming

- Ask before creating, overwriting, ejecting, or deleting anything on an external drive unless the exact disposable target was already authorized.
- Never force-eject a drive and never use recursive deletion against a broad path.
- Do not delete remote objects; StorageSync has no object-delete feature by design.
- Preserve the user's existing SQLite state and Keychain entries.
- Query state read-only before restarting work.
- Do not repeat the completed half-sync, internet-loss, and ordinary remount tests unless a relevant code change invalidates their evidence.
