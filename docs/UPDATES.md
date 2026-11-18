# Updates

Circularity can check once a day whether a newer version exists. It is **off
by default** (Settings → General → Updates) because it is the app's only
network use. The check downloads one small JSON file and sends nothing but a
`User-Agent: Circularity/<version>` header.

## Turning it on for a release

1. Choose where two files will live, both over **https**:
   - the DMG, for example a GitHub release asset or your website;
   - `appcast.json`, at a fixed address that never changes between versions.
2. Put the feed's address in `Config/Base.xcconfig`:
   ```
   UPDATE_FEED_URL = https:/$()/example.com/circularity/appcast.json
   ```
   (`$()` stops xcconfig reading `//` as a comment.)
3. Build the release with the download folder's address:
   ```sh
   DOWNLOAD_BASE_URL=https://example.com/circularity RELEASE_NOTES="Cut out, drop shelf" ./scripts/release.sh
   ```
   This writes `dist/Circularity-<version>.dmg` and `dist/appcast.json`.
4. Upload the DMG first, then replace `appcast.json`. Every copy with update
   checks on will see the new version within a day.

## The feed

```json
{ "version": "0.2.0", "url": "https://example.com/circularity/Circularity-0.2.0.dmg", "notes": "Cut out, drop shelf", "minimumSystem": "13.0" }
```

`version` is compared numerically (`0.10.0` is newer than `0.9.3`). A newer
version shows a note in the panel, a notification (if notifications are on)
and a Download button in Settings, which opens `url` in the browser; the DMG
installs like the first time.

## Later

With a Developer ID, this can move to Sparkle for in-place updates (signed
with EdDSA); the `updates.*` settings already exist.
