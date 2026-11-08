# StorageSync

StorageSync is a native macOS menu bar app that copies new and changed files on each scan in one direction between a local folder and an S3-compatible bucket. Local folders may live on internal storage or on removable USB/Thunderbolt SSDs and flash drives.

It is built for the case where the transfer is too large to babysit: multi-terabyte, multi-day jobs that have to survive a closed laptop, a dropped network, a full disk, and an external drive being yanked out mid-write. The manager window is SwiftUI and standard macOS controls; the durable engine runs separately as a launchd agent, so closing the window does not stop a transfer in progress.

Quitting StorageSync stops everything. The menu bar icon disappearing means nothing is left running: the agent is told to stop, and launchd is configured to start it on demand rather than keep it alive, so it stays stopped until StorageSync is opened again. Transfers interrupted this way are checkpointed and resume where they stopped rather than starting over. To keep syncing unattended, leave StorageSync running and just close its window.

## Safety contract

These are the guarantees the engine is written and tested against.

- Source deletions never delete destination content. The engine has no object-delete operation.
- Existing destination files are replaced only by a planned source copy; destination-only paths remain untouched.
- On first pairing, files with equal sizes at the same relative path are adopted. Different sizes produce a conflict. Adoption compares sizes and can preserve different same-size contents.
- A partial download never appears under its final name.
- A changed source, remote object, or destination supersedes the stale plan instead of committing mixed data.
- Work resumes only after StorageSync proves that the same removable volume returned.
- Multipart uploads and ranged downloads are checkpointed in a synchronous SQLite WAL.
- Network loss, provider throttling, insufficient space, and drive loss are durable waiting states, not errors.
- Credentials live in the macOS Keychain; bookmarks, manifests, and transfer state are user-private on disk.
- Only one operation in the app writes a secret, and only the background agent ever reads one back.

The manager shows where a sync's storage actually is, as three lines on one shared scale: what is on this Mac, what is still moving, and what is in the bucket. They are drawn against bytes rather than file counts, and they are one picture rather than three percentages — the cloud line fills from the left, the local line is pinned to the right, and the line between them covers exactly the span the cloud has not reached yet, so copying a file moves a single boundary through all three rows. Underneath sit the three concrete numbers: source files found, files already present at the destination, and files remaining to copy. This makes a partially completed first sync auditable before terabytes of transfer begin.

See [Sync behavior](docs/SYNC-BEHAVIOR.md) for the upload and download rules, including deletions, renames, conflicting edits, and interrupted transfers.

## Credentials

Keys are saved once, given a name, and reused. The sidebar's **Credentials**
section lists every saved set with its shortened access key, when the keys were
last replaced, and which syncs depend on it; the Create Sync sheet offers them in
a menu, so a second bucket in the same account asks for nothing that was already
typed.

Sharing one set between syncs is the point, and it decides the rest of the
behaviour. Replacing an expired key once fixes every sync using it — and because
that is a change several syncs feel at once, the new keys are tried against a
bucket one of them already uses before anything is saved. Deleting is refused
while a sync still depends on the keys, and names the syncs rather than breaking
them. Removing a sync leaves saved credentials alone: they are yours, not the
sync's, and are deleted from the Credentials list only.

The keys themselves are in the Keychain and nowhere else. StorageSync's database
holds a name, a date, and the access key ID with its middle removed — the way the
AWS console shows it — so two sets for the same provider can be told apart in a
menu without the database holding anything that grants access. Saving credentials
is the only operation that writes a secret; pointing a sync at credentials that
are already saved sends no secret anywhere at all, and only the background agent
ever reads one back.

Credentials saved by earlier versions are adopted into the list on first launch,
keeping their existing Keychain item exactly as it is.

## Scope

Deliberately narrow. Create a sync, see its state, pause or resume it, manage the credentials it uses. Upload and download directions are both supported; bidirectional sync is not, and neither is deletion propagation in any form.

Any S3-compatible endpoint should work — AWS S3, Cloudflare R2, Backblaze B2, MinIO, Wasabi, Ceph — using SigV4 with either virtual-host or path-style addressing. Development and real-world verification were done against AWS S3.

**Requirements:** macOS 14 or later. See [Architecture](docs/ARCHITECTURE.md) and the [real-world verification runbook](docs/REAL-WORLD-TEST.md).

## Local build

The package targets macOS 14 and later, but it must be built against the macOS 26 SDK. macOS decides whether an app draws with the macOS 26 interface or the legacy compatibility one from the SDK recorded in the binary's `LC_BUILD_VERSION`, so an older SDK produces a correct but visibly dated app. The deployment target is unchanged, so the result still runs on macOS 14.

```sh
swift build --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
```

Run the dependency-free reliability suite with the `storagesynctest` executable. It is the whole test suite, not a supplement to one: with only the Command Line Tools installed there is no XCTest in the SDK and `import Testing` does not resolve, so an ordinary `swift test` target cannot build. `storagesynctest` is a plain executable that asserts and exits non-zero, which works anywhere the package builds.

```sh
swift run --build-system native --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk storagesynctest
```

Build the development app bundle with:

```sh
./scripts/package-app.sh
```

The resulting ad-hoc signed bundle is `.build/StorageSync.app`.

## Install

```sh
./scripts/install-app.sh
```

This builds the app and installs it to `/Applications`. Open it once. It registers its background agent with `SMAppService`, and syncing then continues whether or not the menu bar app is running.

Install before expecting background syncing to work. launchd records the exact path of the agent it was asked to run and refuses to start one whose signature no longer validates, so an app left in `.build` will not stay registered — it is a build-artifact path, and under a file provider such as iCloud Drive it also picks up extended attributes that invalidate the signature. StorageSync detects a stale registration and re-registers itself, but installing avoids the situation rather than recovering from it.

An ad-hoc signed build registers and runs its agent normally. Because it carries no Apple signature, macOS may ask for the app to be allowed explicitly the first time, under System Settings › General › Login Items & Extensions. StorageSync shows that state in the menu bar popover and in the manager window with a shortcut to the settings pane; it does not interrupt with a dialog.

Signing with an Apple-issued identity is optional for local use and required only for public distribution:

```sh
STORAGESYNC_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/package-app.sh
```

## Installing a downloaded beta

Beta archives on the [Releases page](https://github.com/umutybaki/storage-sync/releases) are ad-hoc signed, not notarized, because the project has no Apple Developer ID yet. macOS quarantines them on download and will refuse the first open with a message about being unable to verify the developer.

Unzip, move `StorageSync.app` to `/Applications`, then either open **System Settings → Privacy & Security**, scroll to the blocked-app notice and choose **Open Anyway** — or clear the quarantine flag directly:

```sh
xattr -dr com.apple.quarantine /Applications/StorageSync.app
```

The right-click → Open shortcut that used to work no longer does on macOS 15 and later. Verify the download against the SHA-256 published in the release notes before doing either.

Build a beta archive yourself with:

```sh
./scripts/package-beta.sh
```

It stages the bundle out of iCloud Drive before archiving — a bundle zipped directly from `.build` carries file-provider extended attributes that invalidate its signature — verifies the signature on the clean copy, and prints the archive path and SHA-256.

## Direct release

For public distribution, first store notarization credentials in the Keychain:

```sh
xcrun notarytool store-credentials "StorageSyncNotary"
```

Then build and submit the release with a Developer ID Application identity:

```sh
STORAGESYNC_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
STORAGESYNC_NOTARY_PROFILE="StorageSyncNotary" \
./scripts/release-app.sh
```

The script never accepts an Apple password or API private key directly. It packages and timestamp-signs the app and helper, verifies both signatures, submits a temporary ZIP to Apple's notary service, staples and validates the ticket, performs a Gatekeeper assessment, and writes `.build/StorageSync-<version>-macOS.zip` with a printed SHA-256.

After producing a signed build, complete the production-background checks in [the real-world verification runbook](docs/REAL-WORLD-TEST.md#signed-release-validation) before distributing it.

## Project status

Working and used against real buckets and real external drives, but not yet distributed as a notarized release. The notarization and public-release path in `scripts/release-app.sh` is written but unproven — it has not been run end to end, because that requires an Apple-issued Developer ID. Treat that script as untested until someone does.

The app was originally built as a photo-specific tool named PhotoSync, and was generalized without changing its behaviour. Reverse-DNS identifiers in the source still read `app.photosync.*` — the Keychain service, the launchd label, the Mach service name, and the bundle identifier. That is deliberate: those strings are bound to existing installs' credentials and resume state, and renaming them would orphan both. The on-disk state directory is `~/Library/Application Support/PhotoSync/` for the same reason.

## A note on how this was built

StorageSync was written with substantial help from AI coding assistants. The design, the safety contract above, and the reliability suite were directed and reviewed by a human, and the behaviour was verified against real S3 buckets and real removable drives rather than from tests alone — but a large share of the code itself was AI-generated.

Read the code before trusting it with data you cannot afford to lose. The no-delete guarantee is the one property most worth verifying yourself: it is enforced by the engine simply having no delete operation to call, which is easy to confirm by grepping the S3 layer.
