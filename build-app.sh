#!/usr/bin/env bash
set -euo pipefail

# Builds Lumen.app from the SwiftPM executable target.
# Output: ./Lumen.app

APP_NAME="Minpaw"
BUNDLE_ID="com.local.minpaw"
BIN_NAME="MP3Player"
APP_DIR="${APP_NAME}.app"
CONFIG="${1:-release}"

cd "$(dirname "$0")"

echo "==> swift build (-c ${CONFIG})"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${BIN_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "Binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Build the app icon: squircle-mask the source PNG into the .iconset, then
# compile to .icns. Falls back to a precompiled .icns if Swift isn't around.
if [[ -f "icons/icon-source.png" && -f "scripts/make-icon.swift" ]]; then
  swift scripts/make-icon.swift icons/icon-source.png icons/AppIcon.iconset >/dev/null
fi
if [[ -d "icons/AppIcon.iconset" ]]; then
  iconutil -c icns icons/AppIcon.iconset -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
elif [[ -f "icons/AppIcon.icns" ]]; then
  cp "icons/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.2.0}</string>
  <key>CFBundleVersion</key><string>${VERSION:-0.2.0}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Used for media key support.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Audio File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.audio</string>
        <string>public.mp3</string>
        <string>public.mpeg-4-audio</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF

# Ad-hoc codesign so AppKit privileges work cleanly on first launch.
codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "==> Built ${APP_DIR}"
echo "Run:  open ${APP_DIR}"
