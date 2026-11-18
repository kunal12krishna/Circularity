#!/bin/sh
# Installs Circularity into /Applications on this Mac: builds the Release app
# if dist/ has none, quits any running copy (including the Debug build), copies
# it in, registers it with macOS (Open With, the ⌃⌥C service) and opens it.
#
#   scripts/install.sh            install dist/Circularity.app (building it if needed)
#   scripts/install.sh --fresh    rebuild the Release app first
set -eu
cd "$(dirname "$0")/.."
APP="dist/Circularity.app"
DEST="/Applications/Circularity.app"

if [ "${1:-}" = "--fresh" ] || [ ! -d "$APP" ]; then
    ./scripts/build.sh
fi

echo "==> Quitting any running Circularity"
pkill -x Circularity 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x Circularity >/dev/null || break; sleep 1; done
pkill -9 -x Circularity 2>/dev/null || true

echo "==> Installing to $DEST"
rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --strict "$DEST"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Forget copies inside the project, so Open With and the service use this one.
for old in build/DerivedData/Build/Products/*/Circularity.app build/DerivedData-release/Build/Products/*/Circularity.app dist/Circularity.app; do
    [ -d "$old" ] && "$LSREGISTER" -u "$old" >/dev/null 2>&1 || true
done
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Contents/Info.plist")
echo "==> Installed Circularity $VERSION"
open "$DEST"
echo "    If you use Launch at login: Settings → General → turn it off and on once, so it points at this copy."
