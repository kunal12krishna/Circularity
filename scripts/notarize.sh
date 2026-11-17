#!/bin/sh
# Notarises and staples a DMG (default: the newest dist/*.dmg). Does nothing
# unless NOTARY_PROFILE names a notarytool keychain profile, made once with:
#   xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password <app-specific>
set -eu
cd "$(dirname "$0")/.."

if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "notarize.sh: NOTARY_PROFILE is not set, so nothing was sent to Apple."
    echo "             Notarising needs a Developer ID signature (scripts/sign.sh) and a notarytool profile."
    exit 0
fi
if [ -z "${DEVELOPER_ID_APP:-}" ]; then
    echo "notarize.sh: Apple only notarises Developer ID-signed apps; set DEVELOPER_ID_APP and run scripts/release.sh." >&2
    exit 1
fi

DMG="${1:-$(ls -t dist/*.dmg 2>/dev/null | head -1)}"
[ -n "$DMG" ] && [ -f "$DMG" ] || { echo "notarize.sh: no DMG found. Run scripts/dmg.sh first." >&2; exit 1; }

echo "==> Signing the disk image"
codesign --force --sign "$DEVELOPER_ID_APP" --timestamp "$DMG"
echo "==> Submitting $DMG (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
