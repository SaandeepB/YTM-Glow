#!/usr/bin/env bash
# Builds "YTM Glow.app" (Apple silicon) into build/ and ad-hoc signs it.
#
#   scripts/build-app.sh            # release build
#   CONFIG=debug scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="$ROOT/build/YTM Glow.app"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "warning: building on $(uname -m); the app targets Apple silicon." >&2
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product YTMGlow
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/YTMGlow" "$APP/Contents/MacOS/YTMGlow"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi
# Ship the browser extension inside the app so the popover can install it.
cp -R extension "$APP/Contents/Resources/extension"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> Done: $APP"
