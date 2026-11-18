#!/bin/sh
# Builds the public website: wraps website/index.html (the source, also used
# for the Claude preview) into a complete page in website/public/ with an icon
# and link-preview tags. Upload that folder to GitHub Pages or any static host.
#
#   scripts/build-website.sh              page only
#   scripts/build-website.sh --with-dmg   also copies dist/Circularity.dmg into the
#                                         site, and the Download button links to it
#                                         (Cloudflare Pages allows files up to 25 MB)
#   DOWNLOAD_URL=https://… scripts/build-website.sh   link to a DMG hosted elsewhere
#
# Without either, a GitHub "origin" remote is used to make a "latest release"
# link; with none of these, the Download button says the release is coming soon.
set -eu
cd "$(dirname "$0")/.."

URL="${DOWNLOAD_URL:-}"
mkdir -p website/public
rm -f website/public/Circularity.dmg
# The product pictures the page shows.
rm -rf website/public/assets && cp -R website/assets website/public/assets
if [ "${1:-}" = "--with-dmg" ]; then
    [ -f dist/Circularity.dmg ] || { echo "build-website.sh: dist/Circularity.dmg not found. Run scripts/release.sh first." >&2; exit 1; }
    cp dist/Circularity.dmg website/public/Circularity.dmg
    URL="${URL:-Circularity.dmg}"
fi
if [ -z "$URL" ] && REMOTE=$(git remote get-url origin 2>/dev/null); then
    SLUG=$(printf '%s' "$REMOTE" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
    case "$REMOTE" in *github.com*) URL="https://github.com/$SLUG/releases/latest/download/Circularity.dmg" ;; esac
fi

python3 - "$URL" <<'PY'
import re, sys
url = sys.argv[1]
src = open("website/index.html", encoding="utf-8").read()
# Head: everything up to the end of the first <style> block; body: the rest.
cut = src.index("</style>") + len("</style>")
head, body = src[:cut], src[cut:]
head = head.replace('<meta name="claude:viewport-fit-sides" content="cover">\n', "")
body = body.replace('const DOWNLOAD_URL = "";', f'const DOWNLOAD_URL = {url!r};'.replace("'", '"'))
description = ("Convert files on your Mac without opening anything: drag a file, tap Shift, "
               "and let go on a format. Try it in your browser.")
page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="description" content="{description}">
<meta property="og:title" content="Circularity">
<meta property="og:description" content="{description}">
<meta property="og:type" content="website">
<meta name="theme-color" content="#0B0D11">
<link rel="icon" href="favicon.svg" type="image/svg+xml">
<style>:root{{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}}body{{margin:0}}img{{max-width:100%}}[hidden]{{display:none!important}}</style>
{head}
</head>
<body>
{body.strip()}
</body>
</html>
"""
open("website/public/index.html", "w", encoding="utf-8").write(page)
open("website/public/favicon.svg", "w", encoding="utf-8").write(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect width="24" height="24" rx="6" fill="#0B0D11"/>'
    '<g fill="none" stroke="#C6FF3D" stroke-width="2.4" stroke-linecap="round">'
    '<path d="M12 4.5A7.5 7.5 0 0 1 19.1 9.6"/><path d="M19.3 13.4A7.5 7.5 0 0 1 12 19.5"/><path d="M9.1 18.9A7.5 7.5 0 0 1 4.8 9.9"/></g></svg>')
print("website/public/index.html", "(download:", url or "coming soon", ")")
PY
