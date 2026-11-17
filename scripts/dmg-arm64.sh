#!/bin/sh
# A smaller Apple silicon-only DMG: dist/Circularity-<version>-arm64.dmg.
# Rebuilds dist/Circularity.app for arm64 only, so run scripts/build.sh again
# afterwards if you need the universal app.
set -eu
cd "$(dirname "$0")/.."
ARCHS=arm64 ./scripts/build.sh
./scripts/sign.sh
DMG_SUFFIX=arm64 ./scripts/dmg.sh
