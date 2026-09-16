#!/bin/bash
# Builds "RTK Meter.app" (universal, ad-hoc signed) into ./build
#
#   ./build.sh                                   build the bundle
#   VERSION=1.2.0 ./build.sh                     stamp an explicit version
#   APP_NAME=… BUNDLE_ID=… ./build.sh            rename the bundle
#   REPOSITORY=you/app FORMULA=you/tap/app …     point updates at your own fork
set -euo pipefail

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found. Install the Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"

APP_NAME="${APP_NAME:-RTK Meter}"
BUNDLE_ID="${BUNDLE_ID:-local.rtkmeter}"
APP="$BUILD/$APP_NAME.app"

# Where the app looks for newer releases, and what it upgrades itself with.
# A fork only has to override these two.
REPOSITORY="${REPOSITORY:-christophecollet78/rtk-meter}"
FORMULA="${FORMULA:-christophecollet78/tap/rtk-meter}"

# Released builds are versioned by their tag; a working copy falls back to the
# most recent tag. 0.0.0 marks a build with no tag at all, which disables the
# update check instead of reporting itself as outdated.
if [ -z "${VERSION:-}" ]; then
  VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed "s/^v//" || true)"
fi
VERSION="${VERSION:-0.0.0}"

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
  <key>UpdateRepository</key><string>$REPOSITORY</string>
  <key>HomebrewFormula</key><string>$FORMULA</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally and to install from a Homebrew
# formula, which is not quarantined. See README for distribution notes.
codesign --force --sign - "$APP"
echo "Built: $APP ($VERSION)"
