# Real-world verification runbook

Use a dedicated test bucket/prefix and an expendable folder on an SSD or USB drive. Never paste AWS secrets into chat, source files, shell history, or screenshots; enter them only in StorageSync's credential fields.

## Least-privilege AWS policy

Replace `BUCKET_NAME` and `PREFIX` below. StorageSync lists with `PREFIX/`, so the policy condition is `PREFIX/*`. This upload policy intentionally omits `s3:DeleteObject` and `s3:DeleteObjectVersion`.

The action set follows AWS's [multipart upload permissions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html) and [prefix-restricted `ListBucket` guidance](https://docs.aws.amazon.com/AmazonS3/latest/userguide/amazon-s3-policy-keys.html).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListOnlyTheStorageSyncPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::BUCKET_NAME",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["PREFIX/*"]
        }
      }
    },
    {
      "Sid": "CopyAndResumeWithinTheStorageSyncPrefix",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::BUCKET_NAME/PREFIX/*"
    }
  ]
}
```

A download-only identity needs only `s3:ListBucket` and `s3:GetObject`. An empty bucket prefix requires a bucket-wide list statement and object resource `arn:aws:s3:::BUCKET_NAME/*`. Customer-managed SSE-KMS keys require additional KMS permissions; use ordinary S3-managed encryption for the first verification.

## Test sequence

1. Start with a partially copied folder/bucket pair. Confirm StorageSync reports source files found, files already in S3, and only missing paths to upload. Confirm no queued path overlaps an existing object key.
2. Add a small text file, photo, and video. Confirm exact bytes and nested names in S3.
3. Edit one source and delete another. Confirm the edit replaces its object and the deleted source's object remains.
4. Add a file larger than 64 MiB. While it is transferring, disconnect the internet. Confirm the UI says it is waiting, reconnect, and verify it resumes to the correct SHA-256.
5. Start a multi-part upload from the external drive. Disconnect the drive after several parts. Confirm StorageSync waits for that drive, rejects a different volume at the same path, and resumes without resending confirmed parts when the original returns.
6. Create a separate download sync into an expendable external-drive folder. Interrupt the internet mid-download, relaunch the app/agent, and verify the partial resumes and the final SHA-256 matches.
7. With expendable media only, disconnect the destination drive during a download. Reconnect the same drive, allow filesystem checks to finish, and verify recovery. This test can expose the drive to filesystem damage; do not use irreplaceable media.
8. Let a transfer run while the manager window and menu bar app are closed. Confirm the launch agent continues and status is accurate after reopening.
9. Rotate or expire the credentials during a waiting job, use **Update S3 Credentials**, and confirm the same durable transfer resumes.

The automated suite covers each logical interruption before this runbook is attempted; the real run validates AWS, launchd, Keychain, macOS bookmarks, actual USB behavior, and the user's network together.

## Signed release validation

Do this only with full Xcode selected and an Apple-issued signing identity installed. An Apple Development identity is sufficient for a local `SMAppService` test; public distribution requires Developer ID Application signing and notarization through `scripts/release-app.sh`.

1. Remove the manually bootstrapped development LaunchAgent before opening the signed app. Do not remove StorageSync's SQLite database, bookmarks, or Keychain records.
2. Place the signed app in `/Applications`, open it, and confirm macOS reports the bundled agent as enabled. If approval is required, enable StorageSync under **System Settings › General › Login Items**.
3. Close and quit the menu-bar interface. Add or modify only a disposable source file and prove the bundled agent completes the transfer while the interface remains closed.
4. Log out and back in, or restart the Mac. Confirm the agent returns, both saved jobs remain correct, and no already-present content is uploaded again.
5. Build a newer signed bundle, replace the app in `/Applications`, and open it. Confirm fingerprint-based re-registration replaces the helper and that a waiting disposable transfer resumes without losing its transfer ID or part checkpoints.
6. For a Developer ID release, run `scripts/release-app.sh`. Confirm notarization succeeds, stapling validates, Gatekeeper accepts the app, and the final ZIP hash is recorded with the release artifact.
7. Extract the final ZIP on a clean or disposable macOS account so it receives normal quarantine handling. Confirm first launch, Login Items approval, background syncing with the UI closed, and relaunch after login.
