#!/bin/zsh

set -euo pipefail

# Builds StorageSync and installs it into /Applications.
#
# The app has to be installed somewhere stable before background syncing can
# work. launchd remembers the exact path of the agent it was asked to run, and
# it refuses to start one whose signature no longer validates. A bundle left in
# .build inside iCloud Drive fails both tests: the path is a build artifact, and
# the file provider keeps writing extended attributes onto the bundle that
# invalidate its signature. StorageSync re-registers itself when it detects that,
# but installing properly avoids the problem instead of recovering from it.

INSTALL_SCRIPT_DIR="${0:A:h}"
INSTALL_PROJECT_DIR="${INSTALL_SCRIPT_DIR:h}"
INSTALL_DESTINATION="${STORAGESYNC_INSTALL_DIR:-/Applications}/StorageSync.app"

BUILT_APP="$("${INSTALL_PROJECT_DIR}/scripts/package-app.sh" | tail -n 1)"

if [[ ! -d "${BUILT_APP}" ]]; then
    print -u2 "package-app.sh did not produce an app bundle."
    exit 1
fi

# Quit a running copy so the replaced bundle is not left half-swapped. Syncing
# is unaffected: the agent is a separate process and keeps running.
if pgrep -f "StorageSync.app/Contents/MacOS/StorageSync" >/dev/null 2>&1; then
    osascript -e 'quit app "StorageSync"' >/dev/null 2>&1 || true
    sleep 1
fi

rm -rf "${INSTALL_DESTINATION}"
ditto --noextattr --norsrc "${BUILT_APP}" "${INSTALL_DESTINATION}"
xattr -cr "${INSTALL_DESTINATION}"

codesign --verify --deep --strict --verbose=2 "${INSTALL_DESTINATION}"

print "${INSTALL_DESTINATION}"
print "Open it once; it registers its background agent and then keeps syncing on its own."
