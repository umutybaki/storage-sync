#!/bin/zsh

set -euo pipefail

# Packages an ad-hoc signed beta archive for direct distribution.
#
# This is not release-app.sh. That script produces a notarized, Developer ID
# signed build and refuses to run without an Apple identity. This one produces
# an archive anyone can install manually, accepting that Gatekeeper will warn
# on first open because the build carries no Apple signature.
#
# The staging step is not optional. Inside iCloud Drive the file provider keeps
# writing com.apple.FinderInfo onto the bundle, and codesign rejects that as
# "resource fork, Finder information, or similar detritus". Archiving straight
# out of .build would ship a bundle whose signature fails on arrival, so the
# app is copied to a non-iCloud path with ditto --noextattr --norsrc, verified
# there, and archived from that clean copy.

BETA_SCRIPT_DIR="${0:A:h}"
BETA_PROJECT_DIR="${BETA_SCRIPT_DIR:h}"

"${BETA_PROJECT_DIR}/scripts/package-app.sh" >/dev/null

BETA_BUILT_APP="${BETA_PROJECT_DIR}/.build/StorageSync.app"
if [[ ! -d "${BETA_BUILT_APP}" ]]; then
    print -u2 "package-app.sh did not produce an app bundle."
    exit 1
fi

BETA_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${BETA_BUILT_APP}/Contents/Info.plist")"
BETA_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/storagesync-beta.XXXXXX")"
trap 'rm -rf -- "${BETA_STAGE_DIR}"' EXIT
BETA_STAGE_APP="${BETA_STAGE_DIR}/StorageSync.app"

ditto --noextattr --norsrc "${BETA_BUILT_APP}" "${BETA_STAGE_APP}"
xattr -cr "${BETA_STAGE_APP}"

# Verified on the clean copy. The same check against .build always fails inside
# iCloud Drive, and that failure is an artifact of the file provider, not of the
# signature this archive actually carries.
codesign --verify --deep --strict --verbose=2 "${BETA_STAGE_APP}"

BETA_ARCHIVE="${BETA_PROJECT_DIR}/.build/StorageSync-${BETA_VERSION}-macOS.zip"
rm -f -- "${BETA_ARCHIVE}"
ditto -c -k --sequesterRsrc --keepParent "${BETA_STAGE_APP}" "${BETA_ARCHIVE}"

print "${BETA_ARCHIVE}"
shasum -a 256 "${BETA_ARCHIVE}"
