#!/usr/bin/env bash
# Manual helper install (fallback if SMAppService fails).
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo."; exit 1
fi

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
APP="${1:-/Applications/Wifi Mancer.app}"
if [[ "$APP" != "/Applications/Wifi Mancer.app" ]]; then
    echo "Install the app at /Applications/Wifi Mancer.app first." >&2; exit 1
fi
HELPER_BIN="$APP/Contents/Library/LaunchDaemons/com.wifimancer.helper"
PLIST_DST="/Library/LaunchDaemons/com.wifimancer.helper.plist"
HELPER_DST="/Library/PrivilegedHelperTools/com.wifimancer.helper"
REQUIREMENT_DST="/Library/PrivilegedHelperTools/com.wifimancer.client-requirement"

if [ ! -f "$HELPER_BIN" ]; then
    echo "Helper binary not found in $APP"; exit 1
fi

for destination in "$PLIST_DST" "$HELPER_DST" "$REQUIREMENT_DST"; do
    if [[ -L "$destination" || ( -e "$destination" && ! -f "$destination" ) ]]; then
        echo "Unsafe destination: $destination" >&2; exit 1
    fi
done
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
STAGING="$(mktemp -d /Library/PrivilegedHelperTools/.wifimancer.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/App.app"
codesign --verify --deep --strict "$STAGING/App.app"
codesign -d -r- "$STAGING/App.app" 2>&1 | sed -n 's/^# designated => //p; s/^designated => //p' > "$STAGING/client-requirement"
if ! grep -Eq '^cdhash H"[0-9a-fA-F]{40}"$' "$STAGING/client-requirement"; then
    echo "Expected this personal build's exact code hash." >&2; exit 1
fi
cp "$STAGING/App.app/Contents/Library/LaunchDaemons/com.wifimancer.helper.plist" "$STAGING/helper.plist"
/usr/libexec/PlistBuddy -c 'Delete :BundleProgram' "$STAGING/helper.plist"
/usr/libexec/PlistBuddy -c "Add :Program string $HELPER_DST" "$STAGING/helper.plist"
plutil -lint "$STAGING/helper.plist"
install -o root -g wheel -m 755 "$STAGING/App.app/Contents/Library/LaunchDaemons/com.wifimancer.helper" "$STAGING/helper"
codesign --verify --strict "$STAGING/helper"
chown root:wheel "$STAGING/helper.plist" "$STAGING/client-requirement"
chmod 644 "$STAGING/helper.plist" "$STAGING/client-requirement"

launchctl bootout system/com.wifimancer.helper 2>/dev/null || true
mv -f "$STAGING/helper" "$HELPER_DST"
mv -f "$STAGING/helper.plist" "$PLIST_DST"
mv -f "$STAGING/client-requirement" "$REQUIREMENT_DST"
launchctl enable system/com.wifimancer.helper
launchctl bootstrap system "$PLIST_DST"
launchctl print system/com.wifimancer.helper

echo "Helper installed. Verify Connected in Wifi Mancer Settings."
