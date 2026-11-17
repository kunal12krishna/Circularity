# Release checklist

## Every release (ad-hoc, available now)

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `Config/Base.xcconfig`.
2. Tests, all green:
   - `xcodebuild -project Circularity.xcodeproj -scheme Circularity test`
   - `build/…/Debug/EngineSmokeTest` (add `--large` for the big-file checks)
   - `build/…/Debug/Circularity.app/Contents/MacOS/Circularity --drag-test`
3. `scripts/release.sh` (builds, makes the DMG; skips Developer ID and notarising without credentials).
4. Check the build:
   - `codesign -dv --verbose=4 dist/Circularity.app` → `flags=0x10002(adhoc,runtime)`
   - `lipo -archs dist/Circularity.app/Contents/MacOS/Circularity` → `x86_64 arm64`
   - `hdiutil attach dist/Circularity-<version>.dmg`: background, app on the left, Applications on the right; `codesign --verify --strict` on the app inside.
5. On a second Mac (or a new user account): install from the DMG and follow the README's first-launch steps. Run `docs/MANUAL-TESTS.md` rows 1–10 and 55–74.
6. Optional: `scripts/dmg-arm64.sh` for the smaller Apple silicon DMG (then run `scripts/build.sh` again for the universal app).
7. Write the release notes: what's new, fixed, known issues. Tag: `git tag v<version>`.

## Later: Developer ID (needs an Apple Developer account)

1. Create a "Developer ID Application" certificate in Xcode → Settings → Accounts.
2. Store notary credentials once:
   `xcrun notarytool store-credentials circularity --apple-id <id> --team-id <TEAMID> --password <app-specific password>`
3. `DEVELOPER_ID_APP="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=circularity scripts/release.sh`
   - signs the app with the hardened runtime and a secure timestamp,
   - makes the DMG, signs it, notarises it and staples the ticket.
4. Check: `spctl -a -vv -t open --context context:primary-signature dist/*.dmg` → `accepted, source=Notarized Developer ID`.
5. Then the README's first-launch section can go, and the DMG background note (`scripts/make-dmg-art.swift`) can be removed.
6. With a team ID the widget can ship too: `CIRCULARITY_WIDGET=1 scripts/bootstrap.sh` (App Group needs the team prefix).

## Later still

- Sparkle appcast for updates (`updates.*` settings keys are reserved).
- Homebrew cask: `brew install --cask circularity` pointing at the notarised DMG.
