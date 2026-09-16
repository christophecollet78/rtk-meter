#!/bin/bash
# Builds "RTK Meter.app" (universal, ad-hoc signed) into ./build
#
#   ./build.sh              build the bundle
#   APP_NAME=… BUNDLE_ID=… ./build.sh    override the app name / identifier
set -euo pipefail

APP_NAME="${APP_NAME:-RTK Meter}"
BUNDLE_ID="${BUNDLE_ID:-local.rtkmeter}"
VERSION="${VERSION:-1.0}"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found. Install the Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"

swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT"
BIN="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT" --show-bin-path)/RTKMeter"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RTKMeter"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>RTKMeter</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally, not enough for Gatekeeper on another Mac.
# See README for distribution notes.
codesign --force --sign - "$APP"
echo "Built: $APP"
