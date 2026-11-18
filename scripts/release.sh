#!/bin/sh
# Everything for a release: build → (Developer ID sign) → DMG → (notarise).
# Without DEVELOPER_ID_APP / NOTARY_PROFILE it makes an ad-hoc DMG and says so.
set -eu
cd "$(dirname "$0")/.."

./scripts/build.sh
./scripts/sign.sh
./scripts/dmg.sh
./scripts/notarize.sh

# The update feed for the opt-in update check (docs/UPDATES.md). Host it at the
# address in UPDATE_FEED_URL and the DMG at DOWNLOAD_BASE_URL.
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/Circularity.app/Contents/Info.plist)
DMG_NAME="Circularity-$VERSION.dmg"
BASE="${DOWNLOAD_BASE_URL:-https://example.com/downloads}"
# python3 escapes quotes, backslashes and newlines in the notes.
VERSION="$VERSION" URL="${BASE%/}/$DMG_NAME" NOTES="${RELEASE_NOTES:-}" python3 -c '
import json, os
feed = {"version": os.environ["VERSION"], "url": os.environ["URL"], "notes": os.environ["NOTES"], "minimumSystem": "13.0"}
open("dist/appcast.json", "w").write(json.dumps(feed, indent=2) + "\n")'
echo "==> dist/appcast.json (download address: ${BASE%/}/$DMG_NAME)"
# A copy with a fixed name, so a website can always link to the newest one
# (GitHub: …/releases/latest/download/Circularity.dmg).
cp "dist/$DMG_NAME" dist/Circularity.dmg
echo "==> dist/Circularity.dmg (same file, fixed name for website links)"
[ -n "${DOWNLOAD_BASE_URL:-}" ] || echo "    Set DOWNLOAD_BASE_URL to where the DMG will live before publishing appcast.json."

echo
if [ -z "${DEVELOPER_ID_APP:-}" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "release.sh: made an ad-hoc DMG. The first launch needs the one-time steps in README → 'The first launch'."
else
    echo "release.sh: signed, notarised and stapled."
fi
ls -lh dist/*.dmg
