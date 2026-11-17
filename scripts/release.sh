#!/bin/sh
# Everything for a release: build → (Developer ID sign) → DMG → (notarise).
# Without DEVELOPER_ID_APP / NOTARY_PROFILE it makes an ad-hoc DMG and says so.
set -eu
cd "$(dirname "$0")/.."

./scripts/build.sh
./scripts/sign.sh
./scripts/dmg.sh
./scripts/notarize.sh

echo
if [ -z "${DEVELOPER_ID_APP:-}" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "release.sh: made an ad-hoc DMG. The first launch needs the one-time steps in README → "The first launch"."
else
    echo "release.sh: signed, notarised and stapled."
fi
ls -lh dist/*.dmg
