#!/bin/sh
# Re-signs dist/Circularity.app with a Developer ID (hardened runtime, secure
# timestamp). Does nothing unless DEVELOPER_ID_APP is set, e.g.
#   DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" scripts/sign.sh
set -eu
cd "$(dirname "$0")/.."
APP="dist/Circularity.app"

if [ -z "${DEVELOPER_ID_APP:-}" ]; then
    echo "sign.sh: DEVELOPER_ID_APP is not set, so the app keeps its ad-hoc signature."
    echo "         Set it to your \"Developer ID Application: …\" identity to sign for distribution."
    exit 0
fi
[ -d "$APP" ] || { echo "sign.sh: $APP not found. Run scripts/build.sh first." >&2; exit 1; }

echo "==> Signing $APP as $DEVELOPER_ID_APP"
codesign --force --sign "$DEVELOPER_ID_APP" --options runtime --timestamp "$APP"
codesign --verify --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP" || echo "sign.sh: Gatekeeper will accept it once it is notarised (scripts/notarize.sh)."
