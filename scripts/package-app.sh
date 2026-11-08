#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
# macOS decides whether an app gets the macOS 26 appearance or the legacy
# compatibility one from the SDK recorded in LC_BUILD_VERSION, so the interface
# depends on building against the macOS 26 SDK. The deployment target in
# Package.swift still keeps the app running on macOS 14.
SDK_PATH="${STORAGESYNC_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
MODULE_CACHE="${TMPDIR:-/tmp}/storagesync-swiftpm-module-cache"
CLANG_CACHE="${TMPDIR:-/tmp}/storagesync-clang-module-cache"
PACKAGE_CACHE="${TMPDIR:-/tmp}/storagesync-swiftpm-cache"
PACKAGE_CONFIG="${TMPDIR:-/tmp}/storagesync-swiftpm-config"
PACKAGE_SECURITY="${TMPDIR:-/tmp}/storagesync-swiftpm-security"
OUTPUT_APP="${PROJECT_DIR}/.build/StorageSync.app"

# Which identity signs the bundle. STORAGESYNC_SIGNING_IDENTITY wins when set
# ("-" forces ad hoc); otherwise the login keychain is searched, preferring a
# Developer ID Application identity, then Apple Development.
#
# A real identity matters beyond Gatekeeper. An ad-hoc signature is a hash of
# the binary, so every rebuild is a different program to the Keychain, and
# macOS asks again before the new agent may read the saved S3 keys. A team
# identity keeps the same designated requirement across rebuilds, so "Always
# Allow" is answered once.
#
# Apple Distribution is never used: it signs App Store submissions only, and an
# app signed with it is not accepted for running outside the App Store.
#
# The identity is passed to codesign by its SHA-1 hash, not its name: a renewed
# certificate that overlaps the old one has the same name, and codesign refuses
# an ambiguous name.
CODESIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGNING_IDENTITY="-"
SIGNING_NAME="ad hoc"
if [[ -n "${STORAGESYNC_SIGNING_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY="${STORAGESYNC_SIGNING_IDENTITY}"
    SIGNING_NAME="${STORAGESYNC_SIGNING_IDENTITY}"
    if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
        # A hash names nothing a person can check; look up what it is.
        MATCHED_LINE="$(print -r -- "${CODESIGNING_IDENTITIES}" | grep -F -- "${SIGNING_IDENTITY}" | head -n 1 || true)"
        if [[ -z "${MATCHED_LINE}" ]]; then
            print -u2 "No valid code-signing identity in the keychain matches STORAGESYNC_SIGNING_IDENTITY=${SIGNING_IDENTITY}."
            exit 1
        fi
        SIGNING_NAME="$(print -r -- "${MATCHED_LINE}" | sed -E 's/^[^"]*"(.*)"[^"]*$/\1/')"
    else
        SIGNING_NAME="ad hoc"
    fi
else
    for IDENTITY_KIND in "Developer ID Application" "Apple Development"; do
        MATCHED_LINE="$(print -r -- "${CODESIGNING_IDENTITIES}" | grep -F -- "\"${IDENTITY_KIND}:" | head -n 1 || true)"
        if [[ -n "${MATCHED_LINE}" ]]; then
            SIGNING_IDENTITY="$(print -r -- "${MATCHED_LINE}" | awk '{ print $2 }')"
            SIGNING_NAME="$(print -r -- "${MATCHED_LINE}" | sed -E 's/^[^"]*"(.*)"[^"]*$/\1/')"
            break
        fi
    done
    if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
        print -u2 "No Developer ID Application or Apple Development identity found; signing ad hoc."
        print -u2 "macOS will ask again for Keychain access after each rebuild. Create a certificate in"
        print -u2 "Xcode › Settings › Accounts › Manage Certificates, or set STORAGESYNC_SIGNING_IDENTITY."
    fi
fi

if [[ "${SIGNING_NAME}" == "Apple Distribution:"* || "${SIGNING_NAME}" == "3rd Party Mac Developer"* ]]; then
    print -u2 "\"${SIGNING_NAME}\" signs App Store submissions only; macOS does not accept it for an app run directly."
    print -u2 "Use a Developer ID Application or Apple Development identity."
    exit 1
fi
print -u2 "Signing with: ${SIGNING_NAME}"

if [[ ! -d "${SDK_PATH}" ]]; then
    print -u2 "StorageSync SDK not found at ${SDK_PATH}"
    print -u2 "The interface needs the macOS 26 SDK. Install it with the current Command Line Tools,"
    print -u2 "or set STORAGESYNC_SDK_PATH to another macOS 26 SDK."
    exit 1
fi

cd "${PROJECT_DIR}"

SDKROOT="${SDK_PATH}" \
CLANG_MODULE_CACHE_PATH="${CLANG_CACHE}" \
SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" \
swift build \
    --build-system native \
    --disable-sandbox \
    --configuration release \
    --cache-path "${PACKAGE_CACHE}" \
    --config-path "${PACKAGE_CONFIG}" \
    --security-path "${PACKAGE_SECURITY}" \
    --sdk "${SDK_PATH}"

BIN_DIR=$(SDKROOT="${SDK_PATH}" SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" swift build \
    --build-system native \
    --disable-sandbox \
    --configuration release \
    --cache-path "${PACKAGE_CACHE}" \
    --config-path "${PACKAGE_CONFIG}" \
    --security-path "${PACKAGE_SECURITY}" \
    --sdk "${SDK_PATH}" \
    --show-bin-path)

# Swift Build can ignore --sdk and stamp the deployment target as the SDK
# version. Use SwiftPM's native build system above, and verify the result so
# packaging cannot silently install an app with the wrong interface behavior.
EXPECTED_SDK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :Version' "${SDK_PATH}/SDKSettings.plist")"
BUILT_SDK_VERSION="$(xcrun vtool -show-build "${BIN_DIR}/StorageSync" | awk '$1 == "sdk" { print $2; exit }')"
if [[ "${BUILT_SDK_VERSION}" != "${EXPECTED_SDK_VERSION}" ]]; then
    print -u2 "StorageSync was built with SDK ${BUILT_SDK_VERSION}; expected ${EXPECTED_SDK_VERSION}."
    exit 1
fi

STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/storagesync-package.XXXXXX")
trap 'rm -rf "${STAGE_DIR}"' EXIT
STAGE_APP="${STAGE_DIR}/StorageSync.app"

mkdir -p "${STAGE_APP}/Contents/MacOS"
mkdir -p "${STAGE_APP}/Contents/Helpers"
mkdir -p "${STAGE_APP}/Contents/Library/LaunchAgents"
mkdir -p "${STAGE_APP}/Contents/Resources"

cp "${BIN_DIR}/StorageSync" "${STAGE_APP}/Contents/MacOS/StorageSync"
cp "${BIN_DIR}/StorageSyncAgent" "${STAGE_APP}/Contents/Helpers/StorageSyncAgent"
cp "${PROJECT_DIR}/Packaging/StorageSync-Info.plist" "${STAGE_APP}/Contents/Info.plist"
cp "${PROJECT_DIR}/Packaging/app.photosync.agent.plist" "${STAGE_APP}/Contents/Library/LaunchAgents/app.photosync.agent.plist"
cp "${PROJECT_DIR}/Packaging/StorageSync.icns" "${STAGE_APP}/Contents/Resources/StorageSync.icns"

plutil -lint "${STAGE_APP}/Contents/Info.plist"
plutil -lint "${STAGE_APP}/Contents/Library/LaunchAgents/app.photosync.agent.plist"

# Copying through iCloud Drive or Finder leaves extended attributes on the
# bundle. codesign rejects them as "resource fork, Finder information, or
# similar detritus", and an app whose signature no longer validates is one
# launchd refuses to start the agent for.
xattr -cr "${STAGE_APP}"

SIGN_ARGUMENTS=(--force --options runtime --sign "${SIGNING_IDENTITY}")
# A secure timestamp is what notarization requires, and only Developer ID
# signatures are notarized. It needs Apple's timestamp server, so other
# signatures skip it rather than fail to package offline.
if [[ "${SIGNING_NAME}" == "Developer ID Application:"* ]]; then
    SIGN_ARGUMENTS+=(--timestamp)
else
    SIGN_ARGUMENTS+=(--timestamp=none)
fi

codesign "${SIGN_ARGUMENTS[@]}" \
    --identifier app.photosync.agent \
    --entitlements "${PROJECT_DIR}/Packaging/DeveloperID.entitlements" \
    "${STAGE_APP}/Contents/Helpers/StorageSyncAgent"
codesign "${SIGN_ARGUMENTS[@]}" \
    --entitlements "${PROJECT_DIR}/Packaging/DeveloperID.entitlements" \
    "${STAGE_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGE_APP}"

rm -rf "${OUTPUT_APP}"
mv "${STAGE_APP}" "${OUTPUT_APP}"

print "${OUTPUT_APP}"
