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
SIGNING_IDENTITY="${STORAGESYNC_SIGNING_IDENTITY:--}"

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
    --disable-sandbox \
    --configuration release \
    --cache-path "${PACKAGE_CACHE}" \
    --config-path "${PACKAGE_CONFIG}" \
    --security-path "${PACKAGE_SECURITY}" \
    --sdk "${SDK_PATH}"

BIN_DIR=$(SDKROOT="${SDK_PATH}" SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" swift build \
    --disable-sandbox \
    --configuration release \
    --cache-path "${PACKAGE_CACHE}" \
    --config-path "${PACKAGE_CONFIG}" \
    --security-path "${PACKAGE_SECURITY}" \
    --sdk "${SDK_PATH}" \
    --show-bin-path)

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
if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
    SIGN_ARGUMENTS+=(--timestamp)
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
