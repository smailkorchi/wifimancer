#!/usr/bin/env bash
# Build a self-signed Release .app suitable for personal use.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ generating Xcode project"
xcodegen generate

DERIVED="$PWD/build"
APP_PATH="$DERIVED/Build/Products/Release/Wifi Mancer.app"

# Mark build/ and dist/ as Spotlight/LaunchServices invisible so duplicate
# .app copies don't pollute Launchpad.
mkdir -p "$DERIVED" dist
touch "$DERIVED/.metadata_never_index"
touch dist/.metadata_never_index

echo "→ xcodebuild Release (arm64 only — libpcap is keg-only on Apple Silicon)"
xcodebuild \
    -project WifiMancer.xcodeproj \
    -scheme WifiMancer \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

# Relocate the helper to Contents/Library/LaunchDaemons (required for SMAppService).
echo "→ relocating helper into Library/LaunchDaemons/"
LD_DIR="$APP_PATH/Contents/Library/LaunchDaemons"
mkdir -p "$LD_DIR"
if [ -f "$APP_PATH/Contents/Resources/WifiMancerHelper" ]; then
    mv "$APP_PATH/Contents/Resources/WifiMancerHelper" \
       "$LD_DIR/com.wifimancer.helper"
fi
cp Helper/com.wifimancer.helper.plist "$LD_DIR/com.wifimancer.helper.plist"

# Sign helper FIRST (nested before outer). NO --options runtime — hardened
# runtime + ad-hoc + special entitlements = AMFI kill on macOS 26.
#
# `--identifier` is mandatory: without it, codesign derives the identifier
# from the filename and STRIPS the last dotted component, so a binary named
# `com.wifimancer.helper` ends up with identifier `com.wifimancer`. That
# breaks the mach-service / SMAppService identity check because the plist
# label is the full `com.wifimancer.helper`.
echo "→ codesigning helper (ad-hoc, no hardened runtime)"
codesign --force --sign - \
    --identifier com.wifimancer.helper \
    --entitlements Helper/WifiMancerHelper.entitlements \
    "$LD_DIR/com.wifimancer.helper"

echo "→ codesigning app (ad-hoc, no hardened runtime)"
codesign --force --deep --sign - \
    --entitlements App/WifiMancer.entitlements \
    "$APP_PATH"

# Strip Gatekeeper quarantine (set if downloaded; safe to clear locally)
xattr -cr "$APP_PATH" 2>/dev/null || true

echo
echo "Built: $APP_PATH"
echo "Drag it to /Applications, then launch once and approve the helper."
