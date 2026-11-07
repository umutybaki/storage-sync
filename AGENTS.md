# StorageSync agent handoff

Small native macOS menu-bar app for durable one-way sync between a local folder (internal or external SSD) and an S3-compatible bucket. Upload and download jobs both supported. Narrative history lives in `git log` and `CHANGELOG.md` — this file is only what a session needs *before* touching anything.

## Product contract

- Minimal, recognizably native UI: a `MenuBarExtra` plus a small SwiftUI manager window.
- Copy new and changed files in exactly one configured direction.
- **Never propagate deletion. There is intentionally no S3 object-delete operation.** (`abortMultipartUpload` DELETEs an incomplete upload ID only; it never touches a completed object.)
- On a first pairing, adopt a destination file already at the same relative path instead of copying it again.
- Show source files found, destination files already present, and items remaining.
- Support multi-terabyte, multi-day work without holding a full manifest or file in memory.
- Persist multipart and ranged-download progress in SQLite; recover after process, network, or volume interruption.
- Resume only when the same external volume is confidently identified.
- Credentials live in the macOS Keychain only. Never print, copy, log, or ask for them.

Do not declare the app complete from automated tests alone. Notarization and the public release path remain unproven and must not be implied as tested.

## Workspace and toolchain

- Full Xcode is installed and selected (`xcode-select -p`), but every build still passes the Command Line Tools' macOS 26 SDK explicitly, as below. Check `xcode-select -p` rather than trusting this line.
- **Build against `MacOSX26.sdk`.** macOS picks its interface from the SDK in `LC_BUILD_VERSION`, so an older one silently produces a dated-looking app, and `StorageSyncApp` uses `ToolbarSpacer`, absent before macOS 26. Deployment target stays macOS 14.
- **`codesign --verify --strict` on `.build/StorageSync.app` always fails, and that is not a real failure.** iCloud's file provider re-adds `com.apple.FinderInfo` and `xattr -cr` cannot keep it off. Copy the bundle out with `ditto --noextattr --norsrc` first, or check what `install-app.sh` put in `/Applications` — that is the copy that matters.
- This **is** a Git repository (earlier versions of this file said it was not). Tracked files have an undo; untracked ones do not, so copy those outside the tree before replacing them.
- Moving the workspace invalidates the module cache; clear `.build/*/ModuleCache`.

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
CLANG_MODULE_CACHE_PATH=/tmp/storagesync-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/storagesync-swiftpm-module-cache \
swift run --disable-sandbox \
  --cache-path /tmp/storagesync-swiftpm-cache \
  --config-path /tmp/storagesync-swiftpm-config \
  --security-path /tmp/storagesync-swiftpm-security \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
  storagesynctest
```

Package with `./scripts/package-app.sh`, install with `./scripts/install-app.sh`. Packaging signs and verifies in `$TMPDIR` before moving the bundle into `.build`, so a clean run means the signature was good.

Packaging picks its signing identity from the login keychain — Developer ID Application, then Apple Development — and signs ad hoc, with a warning, when neither exists. `STORAGESYNC_SIGNING_IDENTITY` overrides it (`-` forces ad hoc). Apple Distribution is refused: it signs App Store submissions only. Switching from ad hoc to a team identity changes the helper's Keychain identity once, so expect one more **Always Allow** prompt; after that rebuilds keep the same identity and stop prompting. Codesign itself may ask once for access to the signing key.

## Live state — read it, never quote it

Numbers written into this file go stale silently; that has misled several sessions. Query read-only, never with a writable handle:

```sh
DB="$HOME/Library/Application Support/PhotoSync/PhotoSync.sqlite"
sqlite3 "file:$DB?mode=ro" "SELECT payload FROM snapshots;"
sqlite3 "file:$DB?mode=ro" "SELECT status, COUNT(*) FROM transfers GROUP BY status;"
```

One job exists: `Photos`, upload, `/Volumes/EXTERNAL-SSD/Camera/Photos` → bucket `example-bucket` (`eu-north-1`, virtual-host addressing), observed on ExFAT. **The source is the user's real photo library; treat every path in it as irreplaceable.** The disposable jobs and fixtures from earlier sessions are gone — do not expect them, do not treat their absence as damage, and do not recreate them. No credential material is in that database.

## Things that will bite you

- **`manifest_conflicts` is dropped and recreated** at init when it lacks a `side` column (detected with `PRAGMA table_info`). A primary key cannot be widened in place and the table holds only state the next scan recomputes. Every installation predating 2026-08-13 takes this path on first launch.
- **Do not set `kSecUseDataProtectionKeychain`.** It needs a team identifier this ad-hoc build does not have, and it would orphan every already-saved credential. Items are written `AfterFirstUnlockThisDeviceOnly` and non-synchronizable; the login keychain does not enforce that class, so it is a declaration, not a guarantee.
- **`SyncCoordinator.saveCredential` is the only thing in the tree that writes a secret.** `save(connection:)` writes configuration only, so reusing saved keys sends no secret over XPC. `removeCredentialMaterialIfOrphaned` treats every uncertain answer as "still in use" — a shared credential must outlive any one sync that used it.
- **Canonical path folding is case-only**, never diacritics or width: APFS keeps `Gökçe.jpg` and `Gokce.jpg` as separate files. Case collisions are detected on *both* sides, and colliding rows on **both** sides are deliberately left in the manifest so reconciliation can discard transfers already queued against them and their baselines are not pruned as if the files had been deleted. The remote side used to delete its group instead, which silently dropped the baselines of a colliding pair on every download cycle.
- **`XPCPeerValidator` must not use `argv[0]`.** launchd passes a relative one with a working directory of `/`, which silently made the agent refuse every connection. It asks the kernel via `_NSGetExecutablePath`.
- **`Reconciler.reconcile` is test-only and deliberately kept.** Production reconciles through the paged `reconciliationRows`/`transferPlan` path; moving `reconcile` into the test target would mean publishing three private helpers.
- **A destination is only overwritten when its source changed.** `Reconciler.destinationDrift` decides the other cases: a same-size destination change refreshes the baseline, any other is a reported conflict. First pairings adopt only equal sizes (`isConflictingExistingDestination`). Uploads also carry S3 write conditions (`WritePrecondition`), so a stale plan cannot replace a newer object.
- Baselines are pruned only after a source scan that skipped nothing (`LocalScanSkipCounter`); an incomplete scan would otherwise turn later edits into silent adoptions.
- Do not restore `KeepAlive` in `Packaging/app.photosync.agent.plist`, and do not shorten the 30-second unreachable-agent grace in `maintainBackgroundServices` — re-registration restarts the agent and interrupts a transfer.

## Background agent

Registered with `SMAppService`; this works with an ad-hoc signature and needs no Apple identity. Deliberately not KeepAlive: launchd starts it on demand through its Mach service, and Quit sends `shutdown`, which awaits `SyncCoordinator.stop()` so in-flight checkpoints commit before the process exits. Unattended syncing therefore requires StorageSync to be running — closing the manager window is fine, only Quit stops it.

Both XPC ends pin the sibling binary's designated requirement per connection with `setCodeSigningRequirement`, which is matched against the connection's audit token. Derive it fresh each time: an ad-hoc requirement is cdhash-based and changes on every rebuild, so a startup-pinned one would reject the very app the agent belongs to.

launchd caches the agent's program path and code requirement, so moving or replacing the bundle leaves a record it refuses to spawn (`job state = spawn failed`, `last exit code = 78`). Diagnose with:

```sh
launchctl print gui/501/app.photosync.agent | grep -E 'job state|last exit|runs ='
log show --last 10m --info --predicate 'subsystem == "app.photosync.agent"'
```

Changing the signing identity (ad hoc → Developer ID, observed 2026-11-08) is worse: the app's unregister + register updates the Login Items record (`sfltool dumpbtm` shows the new team entry) but launchd keeps the already-loaded job, still pinned by an `LWCR` cdhash to the old binary and naming a BTM uuid that no longer exists — `last exit code = 78`, `OS_REASON_CODESIGNING`, forever. `launchctl bootout gui/501/app.photosync.agent` clears it; the app's heal loop then re-registers within about 30 seconds and the job comes back under the new BTM uuid.

An ad-hoc rebuild changes the helper's Keychain identity, so macOS may prompt when the new helper first reads a credential — answer **Always Allow**. A blocked helper looks like a long `Checking for changes…` scan.

## Known gaps

- Notarization, stapling, Gatekeeper assessment, login-restart survival, and helper replacement across an update are all unproven and each needs an Apple identity. `scripts/release-app.sh` implements a fail-closed workflow for it but has never run end to end.
- An accepted XPC peer joins the activity broadcaster before sending anything, so a silent peer could receive job UUIDs, revisions and byte counts until libxpc invalidates it. No credentials, paths or file contents. Closing it needs a "peer verified" signal `NSXPCConnection` does not expose.
- `ObjectStoreError.incompatible` is classified per-file, so a genuinely incompatible provider fails file by file instead of parking the job. Making it job-wide needs a new `SyncBlocker` case.
- No UI change has ever been verified visually: no session has had Screen Recording or Accessibility permission. Evidence has always been a warning-free build plus the reliability suite.

## Safety while resuming

- Ask before creating, overwriting, ejecting, or deleting anything on an external drive unless that exact disposable target was already authorized.
- Never force-eject a drive, and never use recursive deletion against a broad path.
- Preserve existing SQLite state and Keychain entries; query read-only before restarting work.
- Do not repeat the completed half-sync, internet-loss, or ordinary remount tests unless a code change invalidates their evidence.
