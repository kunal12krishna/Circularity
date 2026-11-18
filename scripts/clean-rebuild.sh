#!/bin/sh
# Deletes every built copy and cache of Circularity, rebuilds the Debug app
# from scratch and opens it — so you always test the newest code.
#
#   scripts/clean-rebuild.sh            clean build, keep your settings
#   scripts/clean-rebuild.sh --test     also run all automatic tests first
#   scripts/clean-rebuild.sh --reset    also erase settings, presets, watch
#                                       folders, history and stats (like a
#                                       first install: the welcome shows again)
set -eu
cd "$(dirname "$0")/.."

APP_NAME="Circularity"
BUNDLE_ID="com.kunal.circularity"
RUN_TESTS=0
RESET=0
for arg in "$@"; do
    case "$arg" in
        --test) RUN_TESTS=1 ;;
        --reset) RESET=1 ;;
        *) echo "unknown option: $arg (use --test and/or --reset)" >&2; exit 2 ;;
    esac
done

echo "==> Quitting $APP_NAME"
pkill -x "$APP_NAME" 2>/dev/null || true
# Give it a moment to exit before deleting its files.
for _ in 1 2 3 4 5; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 1; done
pkill -9 -x "$APP_NAME" 2>/dev/null || true

echo "==> Deleting built apps, the generated project and caches"
rm -rf build "$APP_NAME.xcodeproj"   # dist/ (your DMGs) is kept
rm -rf "/Applications/$APP_NAME.app"
rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/WebKit/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
       "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
TMP="${TMPDIR:-/tmp}"
rm -rf "$TMP"/"$APP_NAME"-* "$TMP"/EngineSmokeTest-* 2>/dev/null || true
# Xcode's own build folder for this project, if it was ever opened in Xcode.
rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/"$APP_NAME"-* 2>/dev/null || true

if [ "$RESET" = "1" ]; then
    echo "==> Erasing settings, history and stats"
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    rm -rf "$HOME/Library/Application Support/$APP_NAME"
fi

echo "==> Generating the project"
./scripts/bootstrap.sh >/dev/null

echo "==> Building (Debug, from scratch)"
mkdir -p build
LOG="build/debug-build.log"
if ! xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -20 >&2 || true
    echo "Build failed. Full log: $LOG" >&2
    exit 1
fi
echo "    BUILD SUCCEEDED"

APP="build/DerivedData/Build/Products/Debug/$APP_NAME.app"

if [ "$RUN_TESTS" = "1" ]; then
    echo "==> Unit tests"
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath build/DerivedData test 2>&1 | grep -E "Executed [0-9]+ tests.*seconds$|TEST (SUCCEEDED|FAILED)" | tail -2
    echo "==> Engine checks"
    build/DerivedData/Build/Products/Debug/EngineSmokeTest 2>&1 | tail -1
    echo "==> Drag test (the wheel and windows flash briefly)"
    "$APP/Contents/MacOS/$APP_NAME" --drag-test 2>&1 | grep -E "FAIL|DragTest:" || true
fi

# Make sure Finder's "Open With" and the Service point at this new copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "==> Opening $APP"
open "$APP"
