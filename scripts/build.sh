#!/bin/sh
# Release build of Circularity: universal (arm64 + x86_64), stripped, ad-hoc
# signed with the hardened runtime. Result: dist/Circularity.app
#
#   scripts/build.sh            universal
#   ARCHS=arm64 scripts/build.sh  Apple silicon only (smaller)
#
# Ad-hoc signing needs no Apple account. People who download it must
# right-click → Open the first time (see README). For a Developer ID build,
# run scripts/sign.sh afterwards.
set -eu
cd "$(dirname "$0")/.."

ARCHS="${ARCHS:-arm64 x86_64}"
APP_NAME="Circularity"
DERIVED="build/DerivedData-release"
DIST="dist"

./scripts/bootstrap.sh >/dev/null

echo "==> Building $APP_NAME (Release, $ARCHS)"
LOG="build/release-build.log"
mkdir -p build
if ! xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        -derivedDataPath "$DERIVED" ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -20 >&2 || true
    echo "Build failed. Full log: $LOG" >&2
    exit 1
fi

# Zero warnings: Release already treats warnings as errors; double-check the log.
if grep -E "warning:" "$LOG" | grep -v "appintentsmetadataprocessor" | grep -q .; then
    grep -E "warning:" "$LOG" | grep -v "appintentsmetadataprocessor" | sort -u >&2
    echo "Build produced warnings (see above)." >&2
    exit 1
fi

mkdir -p "$DIST"
rm -rf "$DIST/$APP_NAME.app"
ditto "$DERIVED/Build/Products/Release/$APP_NAME.app" "$DIST/$APP_NAME.app"

echo "==> Ad-hoc signing with the hardened runtime"
codesign --force --sign - --options runtime --timestamp=none "$DIST/$APP_NAME.app"
codesign --verify --strict --verbose=1 "$DIST/$APP_NAME.app"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DIST/$APP_NAME.app/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$DIST/$APP_NAME.app/Contents/Info.plist")
echo "==> $DIST/$APP_NAME.app"
echo "    version  $VERSION ($BUILD)"
echo "    archs    $(lipo -archs "$DIST/$APP_NAME.app/Contents/MacOS/$APP_NAME")"
echo "    size     $(du -sh "$DIST/$APP_NAME.app" | cut -f1)"
codesign -dv "$DIST/$APP_NAME.app" 2>&1 | grep -E "^(Signature|CodeDirectory)" | sed 's/^/    /'
