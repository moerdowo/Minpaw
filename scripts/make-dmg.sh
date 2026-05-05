#!/usr/bin/env bash
#
# Build, Developer-ID sign, and package Minpaw into a distributable .dmg.
#
# Usage: scripts/make-dmg.sh [version]
#   version defaults to 0.1.0 (also written into the bundle's CFBundleShortVersionString
#   via build-app.sh — adjust that script if you bump the version).
#
# Output: dist/Minpaw-<version>.dmg
#
# The bundle is signed with --options runtime + --timestamp so it is ready
# for notarization (notarization itself is left as a follow-up step that
# requires an Apple ID + app-specific password).

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Minpaw"
APP_DIR="${APP_NAME}.app"
VERSION="${1:-0.1.0}"
DIST_DIR="dist"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

# Pick the first Developer ID Application identity available on this machine.
IDENTITY="$(security find-identity -p codesigning -v \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')"

if [[ -z "${IDENTITY}" ]]; then
  echo "No 'Developer ID Application' identity found in the keychain." >&2
  echo "Either install one or invoke ./build-app.sh for an ad-hoc local build." >&2
  exit 1
fi
TEAM_ID="$(echo "${IDENTITY}" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')"

echo "==> Identity: ${IDENTITY}"
echo "==> Team:     ${TEAM_ID}"

echo "==> Building release .app"
VERSION="${VERSION}" ./build-app.sh release >/dev/null

echo "==> Signing ${APP_DIR}"
# Sign nested resources first (none today, but future-proof against frameworks).
codesign --force \
  --options runtime \
  --timestamp \
  --sign "${IDENTITY}" \
  "${APP_DIR}/Contents/MacOS/${APP_NAME}"

codesign --force \
  --options runtime \
  --timestamp \
  --sign "${IDENTITY}" \
  "${APP_DIR}"

echo "==> Verifying app signature"
codesign --verify --strict --deep --verbose=2 "${APP_DIR}"
codesign --display --verbose=2 "${APP_DIR}" 2>&1 | sed 's/^/    /'

echo "==> Staging DMG contents"
mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"

STAGING="$(mktemp -d -t minpaw-dmg-XXXX)"
trap "rm -rf '${STAGING}'" EXIT
cp -R "${APP_DIR}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

echo "==> Building ${DMG_PATH}"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "${STAGING}" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "${DMG_PATH}" >/dev/null

echo "==> Signing DMG"
codesign --force \
  --sign "${IDENTITY}" \
  --timestamp \
  "${DMG_PATH}"

codesign --verify --verbose=2 "${DMG_PATH}"

echo ""
echo "==> Output:"
ls -lh "${DMG_PATH}" | sed 's/^/    /'
echo ""
echo "    SHA-256:"
shasum -a 256 "${DMG_PATH}" | sed 's/^/    /'

cat <<EOF

The .dmg is signed with Developer ID but NOT notarized. macOS Gatekeeper
will still show a "cannot be opened because Apple cannot check it" dialog
on first launch on a different Mac. To finish, notarize it:

  xcrun notarytool submit "${DMG_PATH}" \\
    --apple-id <your-apple-id> \\
    --team-id ${TEAM_ID} \\
    --password <app-specific-password> \\
    --wait
  xcrun stapler staple "${DMG_PATH}"

EOF
