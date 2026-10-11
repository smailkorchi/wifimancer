#!/usr/bin/env bash
# Bundle the built .app into a signed PKG installer.
#
# Result: dist/WifiMancer-1.0.0.pkg
#
# The PKG:
#   - copies WifiMancer.app to /Applications
#   - copies the helper plist to /Library/LaunchDaemons
#   - runs postinstall to bootstrap the LaunchDaemon as root
#   - shows a license + readme in the installer flow

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.0.0"
IDENT="com.wifimancer.installer"
APP="build/Build/Products/Release/Wifi Mancer.app"

if [ ! -d "$APP" ]; then
    echo "→ no Release build, running build.sh first"
    ./Scripts/build.sh
fi

mkdir -p dist build/pkg
touch build/.metadata_never_index dist/.metadata_never_index build/pkg/.metadata_never_index

# 1. payload root mirrors final filesystem
ROOT="build/pkg/root"
rm -rf "$ROOT"
mkdir -p "$ROOT/Applications" "$ROOT/Library/LaunchDaemons"
cp -R "$APP" "$ROOT/Applications/Wifi Mancer.app"
cp Helper/com.wifimancer.helper.plist \
   "$ROOT/Library/LaunchDaemons/com.wifimancer.helper.plist"

# 2. scripts dir for postinstall
SCRIPTS="build/pkg/scripts"
rm -rf "$SCRIPTS"
mkdir -p "$SCRIPTS"

cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
# Postinstall must NEVER block the installer. Anything that can hang gets
# backgrounded with `&` and a `disown`. Worst case: helper isn't bootstrapped,
# but the app's SMAppService.daemon() will load it on first launch.

PLIST="/Library/LaunchDaemons/com.wifimancer.helper.plist"
HELPER="/Applications/Wifi Mancer.app/Contents/Library/LaunchDaemons/com.wifimancer.helper"
LABEL="com.wifimancer.helper"

[ -f "$PLIST" ]  && chown root:wheel "$PLIST"  && chmod 644 "$PLIST"
[ -f "$HELPER" ] && chown root:wheel "$HELPER" && chmod 755 "$HELPER"

# Background everything launchctl-related. The subshell + & + disown guarantees
# the parent postinstall returns immediately even if launchctl wedges.
nohup bash -c '
    launchctl bootout   system "'"$PLIST"'"     >/dev/null 2>&1
    launchctl bootstrap system "'"$PLIST"'"     >/dev/null 2>&1
    launchctl enable    system/'"$LABEL"'       >/dev/null 2>&1
    launchctl kickstart system/'"$LABEL"'       >/dev/null 2>&1
' >/dev/null 2>&1 &
disown

exit 0
POST
chmod +x "$SCRIPTS/postinstall"

COMPONENT="build/pkg/wifimancer-component.pkg"

# 3. component-plist disables bundle relocation (so installer always writes to /Applications)
COMPLIST="build/pkg/component.plist"
cat > "$COMPLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key><true/>
        <key>BundleIsRelocatable</key>     <false/>
        <key>BundleIsVersionChecked</key>  <true/>
        <key>BundleOverwriteAction</key>   <string>upgrade</string>
        <key>RootRelativeBundlePath</key>  <string>Applications/Wifi Mancer.app</string>
    </dict>
</array>
</plist>
PLIST

# 5. rebuild component pkg with the no-relocation plist
rm -f "$COMPONENT"
pkgbuild \
    --root "$ROOT" \
    --component-plist "$COMPLIST" \
    --scripts "$SCRIPTS" \
    --identifier "$IDENT.component" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT"

# 6. installer Resources directory — productbuild reads --resources and
# bundles every file inside the .pkg, then `<welcome>`, `<conclusion>`,
# `<background>` and `<license>` references in the distribution XML
# resolve relative to that directory at install time.
INSTALLER_RES="build/pkg/installer-resources"
rm -rf "$INSTALLER_RES"
mkdir -p "$INSTALLER_RES"
cp Resources/installer-welcome.html    "$INSTALLER_RES/welcome.html"
cp Resources/installer-conclusion.html "$INSTALLER_RES/conclusion.html"
cp Resources/installer-bg.png          "$INSTALLER_RES/background.png"
# License — fall back to a minimal one if the repo's LICENSE file is
# missing so productbuild doesn't error out on a clean checkout.
if [ -f LICENSE ]; then
    cp LICENSE "$INSTALLER_RES/LICENSE.txt"
else
    echo "© $(date +%Y) El Qorchi Ismail. All rights reserved." > "$INSTALLER_RES/LICENSE.txt"
fi

# 7. distribution xml — branded installer chrome
DIST="build/pkg/distribution.xml"
cat > "$DIST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Wifi Mancer</title>
    <organization>com.wifimancer</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="false" rootVolumeOnly="true" allow-external-scripts="false"/>
    <welcome    file="welcome.html"    mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <license    file="LICENSE.txt"     mime-type="text/plain"/>
    <background        file="background.png" alignment="bottomleft" scaling="proportional"/>
    <background-darkAqua file="background.png" alignment="bottomleft" scaling="proportional"/>
    <choices-outline>
        <line choice="default">
            <line choice="$IDENT.component"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$IDENT.component" visible="false">
        <pkg-ref id="$IDENT.component"/>
    </choice>
    <pkg-ref id="$IDENT.component" version="$VERSION" onConclusion="none">wifimancer-component.pkg</pkg-ref>
</installer-gui-script>
XML

# 8. final product — pass --resources so the bundled HTML/PNG/license
# end up inside the .pkg and the references above resolve.
OUT="dist/WifiMancer-$VERSION.pkg"
productbuild \
    --distribution "$DIST" \
    --resources    "$INSTALLER_RES" \
    --package-path "build/pkg" \
    --version "$VERSION" \
    "$OUT"

# 6. ad-hoc sign (no Apple Developer cert required for personal use)
# If you have a Developer ID Installer cert, replace `-` with its name.
if security find-identity -v -p basic 2>/dev/null | grep -q "Developer ID Installer"; then
    IDENT_NAME=$(security find-identity -v -p basic | awk -F'"' '/Developer ID Installer/ {print $2; exit}')
    echo "→ signing with: $IDENT_NAME"
    productsign --sign "$IDENT_NAME" "$OUT" "$OUT.signed"
    mv "$OUT.signed" "$OUT"
else
    echo "→ no Developer ID Installer cert found — leaving PKG unsigned (ad-hoc OK for personal)"
fi

echo
echo "PKG built: $OUT"
echo "Double-click to install. macOS will prompt for admin password."

# 9. Custom Finder icon on the .pkg file itself — so when someone
# downloads it, the Finder thumbnail shows the Wifi Mancer mark instead
# of the generic Apple installer-box icon. Uses NSWorkspace.setIcon
# (the only first-party API for setting a per-file custom icon resource).
if [ -f Resources/icon-rendered-1024.png ]; then
    /usr/bin/swift - <<SWIFT
import Cocoa
guard let icon = NSImage(contentsOfFile: "Resources/icon-rendered-1024.png") else {
    print("→ pkg icon: source PNG missing"); exit(0)
}
let ok = NSWorkspace.shared.setIcon(icon, forFile: "$OUT", options: [])
print("→ pkg Finder icon: \(ok ? "set" : "failed")")
SWIFT
fi

# Wipe every intermediate .app + pkg payload — only the final PKG should
# remain on disk, otherwise LaunchServices indexes the duplicates into Launchpad.
echo "→ scrubbing intermediate .app copies"
rm -rf build/Build build/pkg
# Explicitly unregister any stale paths that might have been seen.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for stale in \
    "$PWD/build/Build/Products/Release/Wifi Mancer.app" \
    "$PWD/build/pkg/root/Applications/Wifi Mancer.app"; do
    "$LSREG" -u "$stale" 2>/dev/null || true
done
