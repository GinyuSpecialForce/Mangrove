#!/bin/bash
#
# Builds Mangrove and assembles it into a real .app bundle.
#
#   ./scripts/build-app.sh              # release build
#   ./scripts/build-app.sh debug        # debug build
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="Mangrove"
BUNDLE_ID="com.mangrovedesktop.app"
VERSION="1.0"
BINARY=".build/${CONFIG}/Mangrove"
OUT="build/${APP_NAME}.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"

if [ ! -f "$BINARY" ]; then
  echo "error: expected binary at $BINARY" >&2
  exit 1
fi

echo "==> Assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"
cp "$BINARY" "${OUT}/Contents/MacOS/${APP_NAME}"

# The icon is rendered from scripts/make-icon.swift and cached in Resources/.
ICON_CACHE="Resources/AppIcon.icns"
if [ ! -f "$ICON_CACHE" ] || [ "scripts/make-icon.swift" -nt "$ICON_CACHE" ]; then
  echo "==> Rendering app icon"
  ICON_TMP=$(mktemp -d)
  swift scripts/make-icon.swift "$ICON_TMP/base.png" 1024 >/dev/null
  mkdir -p "$ICON_TMP/AppIcon.iconset"
  for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
              "128 128x128" "256 128x128@2x" "256 256x256" \
              "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    set -- $pair
    sips -z "$1" "$1" "$ICON_TMP/base.png" \
      --out "$ICON_TMP/AppIcon.iconset/icon_$2.png" >/dev/null 2>&1
  done
  mkdir -p Resources
  iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$ICON_CACHE"
  rm -rf "$ICON_TMP"
fi

if [ -f "$ICON_CACHE" ]; then
  cp "$ICON_CACHE" "${OUT}/Contents/Resources/AppIcon.icns"
fi

cat > "${OUT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Mangrove is an unofficial Overleaf client. Not affiliated with Overleaf.</string>
</dict>
</plist>
PLIST

# An ad-hoc signature is enough for a locally built app and keeps macOS from
# re-prompting for permissions (Keychain, network) on every launch.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$OUT" >/dev/null 2>&1 \
    && echo "==> Ad-hoc signed" \
    || echo "note: ad-hoc signing skipped"
fi

echo "==> Built ${OUT}"
echo "    open ${OUT}"
