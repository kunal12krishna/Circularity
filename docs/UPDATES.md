# Updates

Circularity can keep itself up to date: once a day it checks whether a newer
version exists, and with one click it installs it in place and relaunches. It is
**off by default** (Settings → General → Updates, or the welcome's last step)
because it is the app's only network use. The check downloads one small JSON file
and sends nothing but a `User-Agent: Circularity/<version>` header.

## How an update is trusted

Every release is signed with an **Ed25519 key that never leaves the maintainer's
Mac** (`~/.config/circularity/update-signing-key`, made once by
`swift scripts/update-key.swift`). Its public half is built into the app
(`UPDATE_PUBLIC_KEY` in `Config/Base.xcconfig` → `CircularityUpdatePublicKey` in
Info.plist).

`UpdateInstaller` replaces nothing unless every check passes:

1. the downloaded DMG's **SHA-256** matches the feed;
2. the feed's **signature** of that SHA-256 verifies with the built-in public key,
   so only a DMG signed with the release key can install, wherever it's hosted;
3. the app inside has the same **bundle ID** and exactly the feed's **version**,
   and `codesign --verify --strict` passes.

Then a small script waits for the app to quit, swaps the bundle (the old one is
kept until the new one is in place, and put back if the swap fails), and opens
the new version. A failed or tampered download leaves nothing behind. If the app
lives somewhere it can't write, Settings offers a normal **Download** instead.

## Publishing a release

1. `RELEASE_NOTES="Crop for social, batch rename" ./scripts/release.sh`
   builds the DMG and writes `dist/appcast.json` with the version, the download
   address (`https://github.com/kunal12krishna/Circularity/releases/download/v<version>/Circularity.dmg`),
   the SHA-256 and the signature.
2. Upload the DMG to that GitHub release as `Circularity.dmg`
   (`gh release create v<version> dist/Circularity.dmg …`).
3. `scripts/build-website.sh` copies `dist/appcast.json` into the site, and
   deploying the site publishes it at `https://circularity.pages.dev/appcast.json`
   (`UPDATE_FEED_URL`). Every copy with updates on sees the new version within a day.

Always upload the DMG **before** deploying the feed.

## The feed

```json
{ "version": "0.5.0",
  "url": "https://github.com/kunal12krishna/Circularity/releases/download/v0.5.0/Circularity.dmg",
  "notes": "Crop for social, batch rename",
  "minimumSystem": "13.0",
  "sha256": "…64 hex…",
  "signature": "…128 hex…" }
```

`version` is compared numerically (`0.10.0` is newer than `0.9.3`). Copies older
than 0.5.0 have no feed address built in; they update by downloading once.

## Testing it

A Debug build accepts a local feed: `CIRCULARITY_UPDATE_FEED=http://127.0.0.1:8765/appcast.json`
checks it at launch, and `CIRCULARITY_AUTO_INSTALL=1` installs straight away. Make
the test DMG from a **Release** app (a re-signed Debug app can't load its debug
library), sign it with `swift scripts/sign-update.swift`, and try a tampered
signature first: it must be refused and change nothing.
