#!/bin/zsh

set -euo pipefail

RELEASE_SCRIPT_DIR="${0:A:h}"
RELEASE_PROJECT_DIR="${RELEASE_SCRIPT_DIR:h}"
RELEASE_SIGNING_IDENTITY="${STORAGESYNC_SIGNING_IDENTITY:-}"
RELEASE_NOTARY_PROFILE="${STORAGESYNC_NOTARY_PROFILE:-}"

if [[ -z "${RELEASE_SIGNING_IDENTITY}" ]]; then
    print -u2 "Set STORAGESYNC_SIGNING_IDENTITY to a Developer ID Application identity."
    exit 1
fi

if [[ "${RELEASE_SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
    print -u2 "Public releases require a Developer ID Application identity, not Apple Development or ad-hoc signing."
    exit 1
fi

if [[ -z "${RELEASE_NOTARY_PROFILE}" ]]; then
    print -u2 "Set STORAGESYNC_NOTARY_PROFILE to a notarytool credential profile stored in Keychain."
    exit 1
fi

if ! xcrun --find notarytool >/dev/null 2>&1; then
    print -u2 "notarytool is unavailable. Install full Xcode and select it with xcode-select."
    exit 1
fi

if ! xcrun --find stapler >/dev/null 2>&1; then
    print -u2 "stapler is unavailable. Install full Xcode and select it with xcode-select."
    exit 1
fi

RELEASE_SDK_PATH="${STORAGESYNC_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
STORAGESYNC_SDK_PATH="${RELEASE_SDK_PATH}" \
STORAGESYNC_SIGNING_IDENTITY="${RELEASE_SIGNING_IDENTITY}" \
    "${RELEASE_PROJECT_DIR}/scripts/package-app.sh"

RELEASE_APP="${RELEASE_PROJECT_DIR}/.build/StorageSync.app"
RELEASE_HELPER="${RELEASE_APP}/Contents/Helpers/StorageSyncAgent"
RELEASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${RELEASE_APP}/Contents/Info.plist")"
RELEASE_ARCHIVE="${RELEASE_PROJECT_DIR}/.build/StorageSync-${RELEASE_VERSION}-macOS.zip"
RELEASE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/storagesync-release.XXXXXX")"
trap 'rm -rf -- "${RELEASE_TEMP_DIR}"' EXIT
RELEASE_UPLOAD_ARCHIVE="${RELEASE_TEMP_DIR}/StorageSync-notarization.zip"

codesign --verify --deep --strict --verbose=2 "${RELEASE_APP}"
codesign --verify --strict --verbose=2 "${RELEASE_HELPER}"

RELEASE_APP_SIGNING_INFO="$(codesign -d --verbose=4 "${RELEASE_APP}" 2>&1)"
if [[ "${RELEASE_APP_SIGNING_INFO}" != *"Authority=Developer ID Application:"* ]]; then
    print -u2 "The app is not signed with a Developer ID Application certificate."
    exit 1
fi

RELEASE_HELPER_SIGNING_INFO="$(codesign -d --verbose=4 "${RELEASE_HELPER}" 2>&1)"
if [[ "${RELEASE_HELPER_SIGNING_INFO}" != *"Authority=Developer ID Application:"* ]]; then
    print -u2 "The background helper is not signed with a Developer ID Application certificate."
    exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "${RELEASE_APP}" "${RELEASE_UPLOAD_ARCHIVE}"
xcrun notarytool submit "${RELEASE_UPLOAD_ARCHIVE}" \
    --keychain-profile "${RELEASE_NOTARY_PROFILE}" \
    --wait

xcrun stapler staple "${RELEASE_APP}"
xcrun stapler validate "${RELEASE_APP}"
codesign --verify --deep --strict --verbose=2 "${RELEASE_APP}"
spctl --assess --type execute --verbose=4 "${RELEASE_APP}"

rm -f -- "${RELEASE_ARCHIVE}"
ditto -c -k --sequesterRsrc --keepParent "${RELEASE_APP}" "${RELEASE_ARCHIVE}"
shasum -a 256 "${RELEASE_ARCHIVE}"
print "${RELEASE_ARCHIVE}"
