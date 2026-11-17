#!/bin/sh
# Generates Circularity.xcodeproj from project.yml (the project file is not
# committed). Set CIRCULARITY_WIDGET=1 to include the WidgetKit extension,
# which needs a Developer ID to run (PLAN.md A6).
set -eu
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
CIRCULARITY_WIDGET="${CIRCULARITY_WIDGET:-0}"
if [ "$CIRCULARITY_WIDGET" = "1" ]; then CIRCULARITY_WIDGET=true; else CIRCULARITY_WIDGET=false; fi
export CIRCULARITY_WIDGET
xcodegen generate --spec project.yml
