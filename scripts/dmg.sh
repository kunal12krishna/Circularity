#!/bin/sh
# Makes dist/Circularity-<version>[-<suffix>].dmg from dist/Circularity.app with
# create-dmg: generated background, the app's icon as the volume icon, and the
# app next to an Applications link.
#
#   scripts/dmg.sh                 dist/Circularity-0.1.0.dmg
#   DMG_SUFFIX=arm64 scripts/dmg.sh  dist/Circularity-0.1.0-arm64.dmg
#   DMG_NO_FINDER=1 scripts/dmg.sh   skip the Finder layout step (headless machines)
set -eu
cd "$(dirname "$0")/.."
APP="dist/Circularity.app"
[ -d "$APP" ] || { echo "dmg.sh: $APP not found. Run scripts/build.sh first." >&2; exit 1; }
command -v create-dmg >/dev/null 2>&1 || { echo "dmg.sh: create-dmg not found: brew install create-dmg" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="Circularity-$VERSION${DMG_SUFFIX:+-$DMG_SUFFIX}"
OUT="dist/$NAME.dmg"
ART="build/dmg"
mkdir -p "$ART"

echo "==> Drawing the background"
swift scripts/make-dmg-art.swift "$ART" >/dev/null
tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null 2>&1

rm -f "$OUT"
set -- --volname "Circularity" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$ART/background.tiff" \
    --window-pos 200 120 --window-size 660 420 \
    --icon-size 112 --text-size 13 \
    --icon "Circularity.app" 180 200 \
    --hide-extension "Circularity.app" \
    --app-drop-link 480 200 \
    --format ULFO --filesystem APFS
if [ "${DMG_NO_FINDER:-0}" = "1" ]; then set -- "$@" --skip-jenkins; fi

echo "==> Making $OUT"
STAGE="build/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Circularity.app"
create-dmg "$@" "$OUT" "$STAGE" >build/dmg.log 2>&1 || { tail -20 build/dmg.log >&2; echo "dmg.sh: create-dmg failed (log: build/dmg.log)" >&2; exit 1; }
rm -rf "$STAGE"

hdiutil verify "$OUT" >/dev/null 2>&1 || { echo "dmg.sh: $OUT failed verification" >&2; exit 1; }
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
