# What StorageSync does on the next scan

An **upload** reads the selected Mac or external-drive folder and writes to S3. A **download** reads S3 and writes to the selected folder. Each job has one direction. All comparisons are relative to the paired folder and bucket prefix.

The rules apply when StorageSync observes a change. Opening the app, **Sync Now**, resuming, and relevant drive or network recovery events can start a scan. An idle job has no periodic inventory scan. Interrupted transfers have their own retry timers.

## Files in either direction

| What StorageSync observes | Upload · Mac → S3 | Download · S3 → Mac |
|---|---|---|
| Only the Mac file exists | Upload it. | Keep the Mac file. |
| Only the S3 object exists | Keep the S3 object. | Download it. |
| Neither exists | Nothing to copy. | Nothing to copy. |
| First pairing, both exist, equal size | Keep both and record a baseline. | Keep both and record a baseline. |
| First pairing, both exist, different sizes | Keep both and report a conflict. | Keep both and report a conflict. |
| Both match the recorded baseline | Skip the file. | Skip the file. |
| Only the Mac file changed | Copy the Mac version to S3. An object already verified to contain those bytes can be reused. | Preserve the Mac edit. Refresh the baseline if its size stayed the same. Report a conflict if its size changed. |
| Only the S3 object changed | Preserve the S3 edit. Refresh the baseline if its size stayed the same. Report a conflict if its size changed. | Copy the S3 version to the Mac. |
| Both changed since the baseline | The Mac version wins. | The S3 version wins. |
| The Mac file was deleted | Keep the S3 object. | Recreate the Mac file if the S3 source still exists. |
| The S3 object was deleted | Recreate it if the Mac source still exists. | Keep the Mac file. |
| Both were deleted | Nothing recreates them. | Nothing recreates them. |

- **Equal size is an adoption rule.** Two different photos with the same name and byte count can be adopted on first pairing. A same-size destination edit can also remain different indefinitely. “Already present” counts these files.
- **Source deletion and recreation.** A complete scan that observes the source missing retires its baseline and withdraws queued work. If the source later returns, first-pair rules apply. If deletion and recreation both happen between scans, the next scan compares against the previous baseline.
- **Source rename or move.** The new path is evaluated separately, and the old destination copy stays. The new path can copy, adopt, or conflict depending on what already exists there. On a case-insensitive volume, a single matching name with different capitalization can reuse the existing S3 key.
- **Destination rename or move.** The renamed copy stays. If the source still exists, StorageSync restores the original path. Renaming the destination out of the way is one way to resolve a conflict and keep both versions.
- **Conflict resolution.** Withdrawing or renaming the destination allows a fresh copy. Withdrawing the source leaves the destination alone. A later edit to an established source can replace a destination that previously conflicted.
- **File identity.** Ordinary local scans use size, modification time, and available filesystem identity or generation information. Remote comparisons use available checksums, strong ETags, or size and last-modified time. A same-size rewrite with indistinguishable metadata can escape detection. StorageSync does not hash every file on every scan.

## Paths and file types

- Regular files, including zero-byte files, hidden user files and files inside macOS packages, are eligible. Empty directories and S3 folder markers are skipped. Downloads create directories as needed.
- Unsafe relative paths, traversal components and overlong names are skipped or reported. Symbolic links are excluded from local scans. Transfers reject links that would redirect reads or writes. StorageSync’s marker, partial directory and known operating-system housekeeping files are excluded at every depth.
- Names that collapse to one local path are reported and skipped. A download also skips both a key such as `album` and a key such as `album/photo.jpg` when they would require `album` to be both a file and a directory. Accented and unaccented names can remain separate.
- An existing directory or special file at the destination filename blocks that file. A local scan that skips unreadable entries reports the omission and preserves upload baselines that the incomplete scan cannot account for.

## Changes during a transfer

- **An upload source changes or disappears.** StorageSync abandons the stale attempt when it detects the change and requests a new scan. A completed first upload identifiable by its transfer ID can supply the baseline after an interruption.
- **The S3 destination changes after planning.** Upload creation and replacement use server-side write conditions. A failed condition triggers replanning. If the provider rejects conditional writes, the job reports the incompatibility. A provider that silently ignores conditions cannot provide this protection.
- **The S3 source changes during a download.** Ranged GETs use a strong ETag when available. The engine checks the returned window, the remote identity and available whole-file digests. A multi-range download needs a strong ETag or a whole-file checksum. A stale version triggers replanning.
- **The local destination changes during a download.** A changed destination invalidates the plan. An absent-path download uses an exclusive rename, so a file appearing at publication survives. Existing-file replacement coordinates with macOS file presenters and rechecks the fingerprint before renaming. A writer that bypasses file coordination can still race that last check.
- **Interrupted download publication.** The engine records the verified checksum before publishing. If the process exits between the rename and the first baseline commit, the next scan can recognize the published bytes and evaluate subsequent source changes against that copy.

## Interruptions and controls

- Network failures and throttling back off and retry. A dropped drive pauses work until its identity matches. A full disk waits for space. A changed volume identity needs attention or explicit folder reselection. Selecting a folder again invalidates multipart upload parts from the previous pairing, even if filenames, sizes and timestamps match.
- Multipart uploads reconcile acknowledged parts with the provider. Expired upload IDs start again. Downloads check each saved range independently and refetch missing or damaged ranges. The partial lives under a private name until publication.
- An unreadable file, an unrepresentable destination, or an archived object can fail individually while other files proceed. Repeated checksum failures stop that file. Job-wide authorization or provider capability errors require attention.
- **Pause** stops the job and retains checkpoints. **Resume** rechecks it. **Sync Now** during a run lets admitted transfers settle before rescanning. Closing the manager window lets work continue. **Quit** stops the agent, and reopening resumes eligible jobs.
- **Remove Sync** removes the job and its tracking state. Completed local files and S3 objects stay. Cleanup of that job’s partial downloads and unfinished multipart uploads is best effort.
