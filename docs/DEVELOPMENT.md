# Developing Circularity

Everything you need to build, test and release Circularity. The [README](../README.md) is about using it.

## Build from source

Requirements: macOS 13+ to run; Xcode 27 to build (tested with 27.2),
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and, for the DMG,
[create-dmg](https://github.com/create-dmg/create-dmg).

```sh
brew install xcodegen create-dmg
scripts/bootstrap.sh          # generates Circularity.xcodeproj
open Circularity.xcodeproj
```

| Script | What it does |
| --- | --- |
| `scripts/build.sh` | Release build, universal, stripped, ad-hoc signed with the hardened runtime → `dist/Circularity.app` |
| `scripts/dmg.sh` | `dist/Circularity-<version>.dmg` with the background and an Applications link |
| `scripts/dmg-arm64.sh` | Apple silicon-only build and DMG |
| `scripts/sign.sh` | Developer ID signature, only when `DEVELOPER_ID_APP` is set (otherwise it says so and does nothing) |
| `scripts/notarize.sh` | Notarise and staple the DMG, only when `NOTARY_PROFILE` is set |
| `scripts/release.sh` | All of the above in order |
| `scripts/install.sh` | Installs the Release app into /Applications on this Mac and opens it (`--fresh` rebuilds it first) |
| `scripts/clean-rebuild.sh` | Deletes the Debug build and caches (keeps `dist/` and the installed app), rebuilds a test copy and opens it (`--test` runs all tests, `--reset` erases settings too) |
| `scripts/build-website.sh` | The public website in `website/public/` (`--with-dmg` puts the DMG inside, for Cloudflare Pages) |

## Test it

```sh
scripts/clean-rebuild.sh --test
```

runs everything below in one go.

- `xcodebuild -scheme Circularity test`: the unit tests.
- The `EngineSmokeTest` target: every conversion through the real engine, including the Word,
  Excel and PowerPoint samples in `Tests/Fixtures/office` and Compress for Office files
  (`SMOKE_KEEP=<folder>` keeps their results; `SMOKE_OFFICE_EXTRA=<folder>` converts and compresses
  your own Office files too). Video and audio (convert, trim, compress, speed, fit-to-size, GIF) run on
  clips the test makes itself; `SMOKE_MEDIA_EXTRA=<folder>` runs your own videos and songs through them.
- `Circularity.app/Contents/MacOS/Circularity --drag-test`: the real wheel, panel, settings and
  jobs (the wheel and windows flash briefly).
- `--check-themes Tests/Fixtures/studio-themes.json [folder]`: every Wheel Studio export (presets,
  random rolls and the ends of every range) pastes in intact, and pasting one over another leaves
  nothing of the old look behind, and no word on any wheel (Convert, Tools, Actions) is ever cut to
  fit. With a folder, each wheel is also rendered at rest and with More open.
  The file is made by the live Studio page: `node scripts/studio-exports.mjs "$PWD/website/studio.html" <out.json>`
  drives it in headless Chrome and exports every preset, every knob at both ends, the worst-case text
  settings, random rolls and share links, and checks that the app's JSON round-trips through the
  Studio's Import box. Run it again whenever the Studio changes.
- `--render-previews <folder>`: renders the wheels, panel, settings and dialogs to PNGs.
- `--perf-report [file.md]`: measures the app's performance budgets on this Mac.

Manual checks are in [docs/MANUAL-TESTS.md](docs/MANUAL-TESTS.md), the release steps in
[docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md), and how to record the demo GIF in
[docs/DEMO-GIF.md](docs/DEMO-GIF.md).

In a Debug build, `CIRCULARITY_TOOL=<password|editPages|fit|speed|copyText|searchable|trim>` opens that
tool straight on the files given on the command line, so a dialog can be driven through
Accessibility without a mouse.

## How it's put together

| Folder | What's in it |
| --- | --- |
| `Sources/Engine` | The conversion engine: a job queue (two at a time) with progress and cancellation, ImageIO / PDFKit / WebKit backends, Word through `textutil`, Excel and PowerPoint through macOS's Office engine (`OfficeBackend`) and OpenDocument read directly (`OpenDocument`), Cut out and text recognition (Vision), video and audio with AVFoundation (`MediaBackend`: remux, re-encode to HEVC, trim, speed, join, GIF, fit-to-size), PDF passwords and pages (`PDFTools`), size estimates, output naming, and atomic writes so a failed job leaves nothing behind. |
| `Sources/AppLogic` | Pure, unit-tested logic: the wheel's geometry and menu, the gesture state machine and shake detector, ⌘K parsing, presets, themes and colour contrast. |
| `Sources/App/Gesture` | Watches for file drags and decides, once per drag, whether the wheel may open. |
| `Sources/App/Wheel` | The wheel window and its three renderers (Ring and Halo in `SectorRenderer`, Orbit in `OrbitRenderer`), the key guide above the wheel (`KeyGuide`), the look resolved from settings (`WheelStyle`), motion, sounds and the before/after loupe. |
| `Sources/App/MenuBar` | The menu bar icon and the panel (presets, ⌘K, drop zone, recent results). |
| `Sources/App/Dialogs` | Resize, Compress, Crop, Trim, Make it fit, Password, Pages and Speed. |
| `Sources/App/Settings` | The Settings window, and Paste theme for Wheel Studio themes. |
| `Sources/App/Extras` | The result card and the Stash (`DropShelf`), the Actions wheel (`FileActions`), watch folders, clipboard conversion, notifications, Quick Look, the widget bridge. |
| `Sources/App/Platform` | Global shortcuts, launch at login, the Finder service, one running copy, update checks. |
| `Sources/App/Onboarding` | The welcome and the tutorial. |
| `Sources/App/Diagnostics` | `--drag-test`, `--check-themes`, `--render-previews`, `--perf-report` and the developer HUD. |
| `Sources/Widget` | The desktop widget. |
| `website/` | The website ([circularity.pages.dev](https://circularity.pages.dev/)) and the Wheel Studio. |
| `design/` | The design boards the app is drawn from. |

## Publishing a release

Releases are built and published by hand, and the website links to the newest one.

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Base.xcconfig`, and add the
   release to the changelog in `website/index.html`.
2. Run the tests (`scripts/clean-rebuild.sh --test`), then `scripts/release.sh` →
   `dist/Circularity-x.y.z.dmg`.
3. Commit, push, and publish the DMG under the fixed name `Circularity.dmg`, so the
   "latest" download link never changes:
   ```sh
   cp dist/Circularity-x.y.z.dmg dist/Circularity.dmg
   gh release create vx.y.z dist/Circularity.dmg --title "Circularity x.y.z" --notes-file notes.md
   ```
4. `scripts/build-website.sh` (its Download button points at
   `releases/latest/download/Circularity.dmg`), then upload `website/public/` to Cloudflare Pages:
   `npx wrangler pages deploy website/public --project-name circularity`.

The download count on this page comes from GitHub Releases.
