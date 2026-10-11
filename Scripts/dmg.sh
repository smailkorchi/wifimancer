#!/usr/bin/env bash
# Build a styled release DMG using dmgbuild (which writes the .DS_Store
# directly — far more reliable than driving Finder via AppleScript).
#
# Output: dist/WifiMancer-1.0.0.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.0.0"
PKG="dist/WifiMancer-${VERSION}.pkg"
OUT="dist/WifiMancer-${VERSION}.dmg"
BG_TIFF_NAME="background.tiff"

# ---- 1. Pre-reqs --------------------------------------------------------
if [ ! -f "$PKG" ]; then
    echo "→ no PKG at $PKG, building it"
    ./Scripts/pkg.sh
fi
[ -f LICENSE ]               || { echo "missing LICENSE"; exit 1; }
[ -f Resources/INSTALL.txt ] || { echo "missing Resources/INSTALL.txt"; exit 1; }

# dmgbuild lives in user-site Python; PEP 668 means we install with
# --break-system-packages on macOS Sequoia+, but only into ~/Library/Python.
# Locate it once; bootstrap if absent.
DMGBUILD="$HOME/Library/Python/3.14/bin/dmgbuild"
if [ ! -x "$DMGBUILD" ]; then
    DMGBUILD="$(command -v dmgbuild || true)"
fi
if [ -z "$DMGBUILD" ] || [ ! -x "$DMGBUILD" ]; then
    echo "→ installing dmgbuild"
    python3 -m pip install --user --break-system-packages --quiet dmgbuild
    # Re-resolve after install (Python minor version may differ on the host)
    DMGBUILD=$(python3 -c "import os, sys, sysconfig; \
        userbase = sysconfig.get_path('scripts', scheme='osx_user'); \
        print(os.path.join(userbase, 'dmgbuild'))" 2>/dev/null)
    [ -x "$DMGBUILD" ] || { echo "dmgbuild install failed"; exit 1; }
fi

# ---- 2. Render background -----------------------------------------------
echo "→ rendering DMG background"
mkdir -p build/dmg
BG_TIFF="$PWD/build/dmg/${BG_TIFF_NAME}"
swift Scripts/dmg-assets/render-bg.swift "$BG_TIFF"

# ---- 3. Build the volume icon (.icns) -----------------------------------
ICONSET_DIR="build/dmg/Volume.iconset"
VOLICON="$PWD/build/dmg/.VolumeIcon.icns"
rm -rf "$ICONSET_DIR"; mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
    cp "Resources/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}.png" \
       "$ICONSET_DIR/icon_${size}x${size}.png" 2>/dev/null || true
    cp "Resources/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}@2x.png" \
       "$ICONSET_DIR/icon_${size}x${size}@2x.png" 2>/dev/null || true
done
iconutil --convert icns --output "$VOLICON" "$ICONSET_DIR" 2>/dev/null || VOLICON=""

# ---- 4. Drive dmgbuild --------------------------------------------------
mkdir -p dist
rm -f "$OUT"

RW_DMG="$PWD/build/dmg/staging.rw.dmg"
rm -f "$RW_DMG"

WM_PKG="$PWD/$PKG" \
WM_README="$PWD/Resources/INSTALL.txt" \
WM_LICENSE="$PWD/LICENSE" \
WM_BG="$BG_TIFF" \
WM_VOLICON="$VOLICON" \
WM_FORMAT="UDRW" \
"$DMGBUILD" \
    -s Scripts/dmg-assets/dmgbuild-settings.py \
    "Wifi Mancer ${VERSION}" \
    "$RW_DMG"

# ---- 5. Hide the infrastructure files -----------------------------------
# dmgbuild leaves `.background.tiff` and `.VolumeIcon.icns` dot-prefixed but
# without chflags(hidden). Users with "Show hidden files" enabled in Finder
# would otherwise see them. Mount RW, set the flag, unmount.
DEV=$(hdiutil attach -readwrite -noverify -nobrowse "$RW_DMG" \
        | egrep '^/dev/' | head -1 | awk '{print $1}')
MNT="/Volumes/Wifi Mancer ${VERSION}"
sleep 1
for f in "$MNT"/.background* "$MNT"/.VolumeIcon.icns; do
    [ -e "$f" ] && chflags hidden "$f"
done
sync; sleep 1
hdiutil detach "$DEV" >/dev/null

# ---- 6. Compress to UDZO read-only --------------------------------------
echo "→ compressing final DMG"
hdiutil convert "$RW_DMG" \
    -format UDZO -imagekey zlib-level=9 \
    -o "$OUT" >/dev/null

# ---- 7. Done ------------------------------------------------------------
rm -rf build/dmg
echo
echo "DMG built: $OUT"
echo "  • Wifi Mancer Installer.pkg   (the installer)"
echo "  • READ ME FIRST.txt           (install + usage instructions)"
echo "  • LICENSE.txt                 (© 2026 El Qorchi Ismail)"
echo "  • Branded background, custom volume icon, fixed icon-view layout"
