# Circularity for macOS — PLAN

Source brief: `BRIEF.md` (the "DECISIONS ALREADY MADE" block wins over everything else in it).
Design source of truth: the HTML sources in `design/circularity-design-v2/` (exact values), checked against the 2× PNG renders in the same folder (`D-wheel-chosen_*.png`, `I-panel-chosen*.png`, `H-icon-states.png`). The exact values are transcribed in **§9**, which wins over the brief's prose wherever the two differ (each conflict is listed in §9.5).
Status: planning only. No code exists yet.

---

## 0. Fixed decisions (from the brief)

| Item | Value |
|---|---|
| App name | `Circularity` — one constant (see §2.1), renameable to "Circularity for Mac" |
| Bundle ID | `com.kunal.circularity` — one constant, next to the name |
| Minimum OS | macOS 13.0 |
| Architectures | Universal (arm64 + x86_64); extra script for an arm64-only DMG |
| Project generation | XcodeGen (`project.yml`); the `.xcodeproj` is generated and git-ignored |
| App type | LSUIElement agent (no Dock icon), AppKit lifecycle, SwiftUI for panel/settings/dialogs |
| Sandbox | **Off** for the app (it writes next to originals). Hardened runtime **on** |
| Signing | Ad-hoc (`codesign -s -`). Developer ID/notary scripts exist but are gated by env vars |
| Wheel default | "Ring" (Tangerine Glass ring + Halo centre); alternates: Orbit, Halo |
| Panel default | "Stack+"; alternates: Tabs, Mini — one shared view model |
| v1 scope | Milestones a, b, c, d, f, g, h, h2, i, j, k (there is no "e"; it was media, now v1.1) |

---

## 1. Architecture overview

```
┌──────────────────────────── Circularity.app (AppKit host, LSUIElement) ────────────────────────────┐
│                                                                                                      │
│  AppDelegate ── AppCoordinator (owns every controller; builds lazily; the only "composition root")   │
│      │                                                                                               │
│      ├─ Gesture ─────── DragMonitor (global NSEvent mouse monitors, no permission)                   │
│      │                  DragSessionTicker (exists only during a drag)                                │
│      │                  GestureStateMachine (pure, unit-tested) ──► effects                          │
│      │                                                                                               │
│      ├─ Wheel ───────── WheelPanel (NSPanel, built once, hidden) + NSDraggingDestination             │
│      │                  WheelLayout (pure geometry) · SlotProvider (per file type, smart ordering)    │
│      │                  Renderers: RingRenderer / OrbitRenderer / HaloRenderer (Core Animation)       │
│      │                  CentreOrbView · SizeEstimator                                                │
│      │                                                                                               │
│      ├─ MenuBar ─────── StatusItemController (custom icon layer, drag destination)                   │
│      │                  MenuPanel (NSPanel) + PanelViewModel + layouts StackPlus/Tabs/Mini (SwiftUI) │
│      │                  CommandBar (fuzzy matcher) · PinnedPanelController                           │
│      │                                                                                               │
│      ├─ Extras ──────── StatsStore · HistoryStore · WatchFolderService (FSEventStream on demand)     │
│      │                  ClipboardConverter · WidgetBridge (App Group writer, build-flagged)          │
│      │                                                                                               │
│      ├─ Windows ─────── Settings · Onboarding · Tutorial · Resize/Compress/Crop dialogs · History    │
│      │                  (all created lazily, released on close)                                      │
│      │                                                                                               │
│      └─ Platform ────── HotkeyCenter (Carbon) · ServicesProvider · SingleInstance · LoginItem        │
│                         Notifier · Haptics · Sounds · Logging · PerfReport · DiagnosticsBuilder      │
│                                                                                                      │
│                  ▼ JobRequest                                                    ▲ JobEvent stream   │
│  ┌──────────────────────── CircularityEngine (static library, no UI) ───────────────────────────┐    │
│  │ JobQueue (actor, 2 concurrent) · BackendRegistry · OutputPlanner (naming, collisions, fallback) │  │
│  │ Backends: ImageIOBackend · PDFBackend · DocumentBackend · CombineBackend · (v1.1 FFmpeg slot)   │  │
│  │ AtomicWriter · FormatSupport (runtime ImageIO probe) · MetadataPolicy · Presets model           │  │
│  └────────────────────────────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ links Engine                                      ▲ reads App Group (flagged)
  EngineSmokeTest (CLI)                             CircularityWidget (WidgetKit extension, sandboxed)
```

Principles:
- **Engine has no AppKit UI.** It uses Foundation, ImageIO, CoreGraphics, PDFKit, UniformTypeIdentifiers, Quartz (filters), and WebKit only inside the offscreen HTML renderer. The app, the CLI and the tests all drive the same `JobQueue`.
- **Pure logic is separated from side effects** so it can be unit-tested: gesture state machine, wheel geometry, slot ordering, output naming, fuzzy matcher, watch-folder rule matching, theme contrast, settings schema migration.
- **Idle means nothing is running.** No timers, display links, polling, FSEvents (unless a watch folder is enabled) or network. SwiftUI is not loaded until a SwiftUI window or panel opens.
- **One composition root** (`AppCoordinator`) owns long-lived controllers. Everything heavy is created on demand and dropped on close.

---

## 2. Project layout and targets

```
project.yml
Config/
  Identity.xcconfig        # APP_NAME, BUNDLE_ID, APP_GROUP_ID: the single source of identity
  Base.xcconfig            # deployment target 13.0, Swift 6, ARCHS universal, strip, hardened runtime
  Debug.xcconfig / Release.xcconfig
  Widget.xcconfig          # CIRCULARITY_WIDGET=0|1
Sources/
  Shared/                  # used by the app, widget and Engine: AppIdentity, SharedModels (stats/recents snapshot), SettingsKeys
  Engine/                  # CircularityEngine static library
  App/                     # Circularity.app
    Core/  Gesture/  Wheel/  MenuBar/  Extras/  Windows/  Settings/  Appearance/  Platform/  Diagnostics/
  Widget/                  # CircularityWidget extension (only built when CIRCULARITY_WIDGET=1)
  EngineSmokeTest/         # CLI
Tests/
  CircularityTests/        # unit tests (app logic + Engine)
Resources/
  Info.plist, Circularity.entitlements, Widget.entitlements
  Assets.xcassets (AppIcon generated, accent colour, minimal)
  Localizable.xcstrings (English base; language follows the system)
  Sounds/ (3 original packs, generated by script)
scripts/
  bootstrap.sh       # xcodegen generate (+ checks for create-dmg)
  build.sh           # xcodebuild Release universal, ad-hoc sign
  make-icon.swift    # draws the original app icon → AppIcon.appiconset + .icns
  make-dmg-art.swift # DMG background + volume icon
  make-sounds.swift  # synthesises the three sound packs
  sign.sh            # Developer ID signing; exits 0 with a message if DEVELOPER_ID_APP is unset
  notarize.sh        # notarytool submit --wait + stapler; gated on NOTARY_PROFILE
  release.sh         # build → sign → dmg → notarize → staple (each gated step skips cleanly)
  dmg.sh             # create-dmg, custom background, drag-to-Applications, volume icon
  dmg-arm64.sh       # arm64-only variant
  perf.sh            # runs --perf-report, collects RSS/launch time/DMG size → docs/PERF-REPORT.md
docs/
  INSTRUMENTS.md  PERF-REPORT.md  MANUAL-TESTS.md  RELEASE-CHECKLIST.md
README.md  LICENSE (MIT)  THIRD-PARTY-NOTICES.md  PLAN.md
```

### 2.1 Targets (XcodeGen)

| Target | Type | Notes |
|---|---|---|
| `CircularityEngine` | static library | Swift 6, nonisolated by default, `Sendable` types |
| `Circularity` | application | links Engine; MainActor-by-default isolation; LSUIElement; NSServices; document types (CFBundleDocumentTypes) for "Open with" |
| `EngineSmokeTest` | command-line tool | links Engine; generates fixtures in a temp dir; exit code ≠ 0 on any failure |
| `CircularityTests` | unit-test bundle | host-less (Engine + Shared). A hardened, ad-hoc-signed host refuses injected test bundles, so app logic under test lives in Engine or Shared. Deployment target 14.0, because XCTest itself requires it; tests only run on dev machines |
| `CircularityWidget` | app extension (WidgetKit) | sandboxed, App Group entitlement, deployment target 14.0 (desktop widgets). Lives in `project-widget.yml`, which is included **only when `CIRCULARITY_WIDGET=1`** (`scripts/bootstrap.sh`). Off for ad-hoc builds |

**Identity:** `Config/Identity.xcconfig` is the only place the name and bundle ID are written. Info.plist picks them up through build settings, and Swift's `AppIdentity` (in Shared) reads them from the bundle with a compiled fallback for the CLI. Renaming the app means changing one file.

**Language mode:** Swift 6 with complete concurrency checking. The app target uses MainActor default isolation. The Engine is nonisolated, with an `actor JobQueue`. Warnings are treated as errors in CI builds (`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` in Release) to meet the "zero warnings" bar.

---

## 3. Modules in detail

### 3.1 Engine (`Sources/Engine`)

**Core model**
- `JobRequest` holds: inputs (`[InputItem]`, URL plus UTType, with promised files already resolved), `Operation`, `OutputPolicy`, `MetadataPolicy`, and an optional `PresetID`.
- `Operation` is an enum: `convert(to: OutputFormat)`, `resize(ResizeSpec)`, `compress(CompressSpec)`, `crop(CropSpec)`, `combinePDF`, `pdfToImages(OutputFormat)`, `extractText`, `renderDocument(to: OutputFormat, paper: PaperSize)`. v1.1 cases (`trim`, `transcode`, `videoCrop`…) are **not** declared now. Instead, operations are matched by a `Capability` table, so a new backend can add them without changing the enum's consumers. See §7.
- `JobEvent` is one of: `queued`, `started`, `progress(fraction, detail: "page 3 of 12")`, `finished(JobResult)`, `failed(JobError)`, `cancelled`.
- `JobResult` holds the output URLs, before and after byte counts, duration, and notes (for example "Kept original: compression would not shrink it").

**`protocol ConversionBackend: Sendable`**
```swift
var id: BackendID { get }
func capabilities(_ support: FormatSupport) -> [Capability]   // (input UTType set, operation kind, output formats)
func estimate(_ req: JobRequest) async throws -> ByteEstimate?  // for the centre orb
func run(_ req: JobRequest, workDir: URL, progress: ProgressSink) async throws -> [URL]  // writes into workDir only
```
- `BackendRegistry` resolves `(inputs, operation) → backend`. The v1.1 `FFmpegBackend` registers itself in the same way, once the Media Pack is present.

**`actor JobQueue`**
- Runs at most 2 jobs at once at utility QoS. Each job is a child `Task`, so cancelling it cancels the task, and backends check `Task.checkCancellation()` between pages, tiles and encode passes.
- Publishes an `AsyncStream<JobEvent>` per job and an aggregate stream (overall progress for the status icon).
- **Atomic output:** a backend writes only into a per-job work directory obtained from `FileManager.url(for: .itemReplacementDirectory, appropriateFor: destination)` (same volume). On success, `OutputPlanner` reserves the final name and the file is moved in with `moveItem` (or `replaceItemAt` when replacing). On failure or cancel, the work directory is deleted. No half-written file ever appears at the destination.

**`OutputPlanner`**
- Naming: `photo.png`, `photo (resized).jpg`, `scan (combined).pdf`, and collisions become `name (1).ext`, `name (2).ext`. A user template with tokens `{name} {format} {date} {size}` is supported. Name reservation is serialised inside the actor, so two concurrent jobs can never pick the same name.
- Destination: next to the original, a chosen folder, or a per-type folder. If writing next to the original fails with a permission error, it falls back silently to `~/Documents/Converted/` (created on demand) and records a note on the result.
- "Replace original (to Trash)": the result is moved into place only after the original is successfully trashed via `FileManager.trashItem`. The UI asks for confirmation first.

**`FormatSupport`**: a runtime probe of `CGImageDestinationCopyTypeIdentifiers()` and `CGImageSourceCopyTypeIdentifiers()`, done once and cached. The UI hides WebP and AVIF *encode* buttons when the running macOS cannot write them.

**Backends**

| Backend | Handles | Implementation notes |
|---|---|---|
| `ImageIOBackend` | image → PNG/JPG/TIFF/BMP/GIF/HEIC/WebP*/AVIF*/PDF; resize; crop; compress | Streams through `CGImageSource`, never `NSImage`. A plain convert uses `CGImageDestinationAddImageFromSource` (no full decode copy where possible). Resize uses `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`, `CreateThumbnailWithTransform` (honours EXIF orientation) and `ShouldCacheImmediately=false`. Stretch resize draws into a sized `CGContext`. Transparency is preserved, and is flattened onto white only for JPG/BMP. Metadata: keep, strip GPS (`kCGImageMetadataShouldExcludeGPS`), or strip all. |
| ↳ target-size compress | | Binary search on quality (≤ 8 encodes, into memory-mapped temp data). If even the floor quality (0.35) is too big, downscale by ×0.85 steps and search again. Reports the final quality and dimensions. |
| ↳ RAW / HEIF / AVIF / WebP read | | Whatever ImageIO decodes on the running OS. Anything else is "unsupported", shown as a friendly state, never a crash. |
| ↳ SVG read | | Rendered offscreen with **no network**: first `NSImage(contentsOf:)` when the OS can rasterise SVG, otherwise an offscreen `WKWebView` with a `WKContentRuleList` that blocks every non-`file:` load. Small icons are upscaled to 1024 px on the long edge, with a cap of 4096 px. |
| `PDFBackend` | PDF → PNG/JPG per page into a folder; PDF → TXT; PDF compress; PDF resize (page scale/paper); PDF crop (crop box) | Pages are rendered with `CGPDFPage` into a bitmap context one at a time (progress "page x of y"). Text comes from PDFKit `page.string`. **Compress** (light/balanced/strong): each page is redrawn with `drawPDFPage` into a `CGPDFContext` that has a generated Quartz filter (`QuartzFilter`, image downsample + JPEG quality) applied, so vectors and text pass through and only embedded images are recompressed. **Verification**: the output must have the same page count, the same media/crop boxes, an identical extracted text per page, and a low-resolution raster diff per page under a threshold. If anything differs, or the output isn't smaller, the original is kept and the result says so. |
| `DocumentBackend` | MD → PDF/HTML; HTML → PDF; TXT → PDF; DOCX/DOC/RTF/ODT → PDF/TXT/DOCX | Markdown goes to HTML through a small built-in CommonMark-subset renderer (headings, lists, code, tables, emphasis, links, local images). HTML/TXT → PDF is paginated in an **offscreen** `WKWebView` (never on screen) with the network blocked by a content rule list. A4 or Letter is chosen from `Locale.current.region` (US/CA/MX/… → Letter). Office formats go through `/usr/bin/textutil` as a short-lived child `Process` (`-convert html/txt/docx`), and then HTML → PDF where needed. WebKit is loaded only when the first document job runs, and the web view is released afterwards. |
| `CombineBackend` | 2+ images/PDFs → one PDF in drop order | Images become pages at their native size (or fit to A4/Letter, depending on the setting), and PDF pages are appended unchanged. |

**Presets** (`PresetStore` model in Engine; persistence in the app): `Preset { id, name, colour, appliesTo: [UTType], operation, outputOverrides }`. The built-ins are → JPG, < 2 MB, 1920w, → PDF combine, No GPS, and Copy PNG from clipboard. The wheel, the panel grid and the ⌘K bar all share this store, and "Also add this as a button" in the dialogs writes to it.

### 3.2 Gesture (`App/Gesture`)

The core gesture must not need Accessibility or Input Monitoring, and there is no event tap in v1.

- **`DragMonitor`** installs `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])`. These are mouse monitors, which need no permission. These three monitors are the only things alive while idle; they are event-driven and use no CPU at rest.
- **`DragSessionTicker`** is started on mouseDown + movement > 4 pt and **torn down on mouse up**. While it runs, it samples permission-free class properties: `NSEvent.pressedMouseButtons`, `NSEvent.mouseLocation`, `NSEvent.modifierFlags`, and `NSPasteboard(name: .drag).changeCount`. It exists because global monitors may stop receiving `leftMouseDragged` events once another app's `NSDraggingSession` takes over. It is a `DispatchSourceTimer` at ~60 Hz with leeway, and it only exists during a drag.
- **Drag confirmation:** the drag pasteboard's `changeCount` changed after mouseDown, and it contains `public.file-url` or file-promise types (`NSFilePromiseReceiver.readableDraggedTypes`).
- **`GestureStateMachine`** is a pure value type, `(State, Event, Settings, now) → (State, [Effect])`, and is fully unit-tested.
  - States: `idle → pressed → dragging(unconfirmed) → fileDrag(triggerHeldAtStart: Bool) → armed(trigger down, waiting for delay/hold) → wheelShown → wheelDismissed(dragContinues)` and back to `idle` on mouse up.
  - Rules: if the trigger key was already held when the drag started, the state machine stays out of the way until the key is released and pressed again. The trigger is Shift by default, with Option or Control as alternatives. **Tap** opens the wheel on key-down after the delay. **Hold** requires the key to be held for the delay. When the drag leaves the wheel, the wheel dismisses and the drag continues normally. Another trigger press during the same drag reopens it.
  - Effects: `startTicker`, `stopTicker`, `showWheel(at:, items:)`, `hideWheel`, `log`.
- **Shake trigger (on by default; toggle and sensitivity Low/Medium/High in Settings → Gesture):** during a confirmed file drag, the ticker counts horizontal direction reversals of `NSEvent.mouseLocation`. Three reversals of ≥ 40 pt within 600 ms open the wheel (Medium). It needs no permission and no keyboard. It is fed to the state machine as an ordinary `triggerFired` event and unit-tested with recorded paths, including normal drags (slow repositioning, hovering over a folder, dragging across displays) that must **not** trigger it. The tutorial teaches it alongside Shift, and the gesture test area shows a live shake meter so the thresholds can be tuned.
- **`TriggerPolicy`** decides whether to skip: paused, the frontmost app is on the excluded list, or a full-screen app is active. Full screen is detected with `CGWindowListCopyWindowInfo` bounds plus the owner PID of the frontmost app, which needs no Screen Recording because window names are never read. It is evaluated once per drag, not continuously.
- **Verification log:** on first launch, and in `--perf-report`, the app logs (os.Logger, category `gesture`) whether global mouse events and drag-pasteboard reads worked on this macOS version without TCC. Milestone (b) reports the result. **Fallback if it fails:** the smallest change is to rely entirely on the ticker sampling (no permission). Only if *that* fails would we propose an opt-in Input Monitoring path, and that path is reserved for v1.1 as "Advanced gestures".

### 3.3 Wheel (`App/Wheel`)

- **`WheelPanel`** is a borderless, non-activating `NSPanel`.
  - Window properties: level `.popUpMenu + 1`; `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]`; `isOpaque = false`; clear background; `hasShadow = false` (the shadow is drawn by a layer).
  - It is registered for file-URL and file-promise drag types. It is **built once** on first use and then `orderOut`'d and reused.
  - Panel size is **720 × 720 pt × scale**, the same as board D's canvas, with the wheel centre at (360, 360). That fits the disc shadow (218 + 40 + 90 = 348) and a hovered fan chip (270 + 28 × 1.14 ≈ 302). The panel is centred on the cursor and may extend past screen edges. The disc never shifts; the More fan flips instead.
- **`NSDraggingDestination`:**
  - `draggingEntered`/`draggingUpdated` hit-test the location with `WheelLayout` and update the hover. They always return `.copy`.
  - `draggingExited`, or a move beyond outer radius + 24 pt that isn't over a fan chip, hides the wheel while the drag continues.
  - `performDragOperation` does the following: centre means cancel; a segment or chip either enqueues a job or opens its dialog; promises are resolved with `NSFilePromiseReceiver` into a temp inbox first.
- **Click mode** (from a hotkey, Service, Open or the menu bar) uses the same panel, made key-capable. Hover and click work, as do arrow keys to move between segments, Return to choose and Esc to cancel.
- **`WheelLayout`** (pure, unit-tested) produces sector paths (6 × 60° with 3° gaps, segment 0 at 12 o'clock, clockwise), rest and hover radii (98/204 → 92/216), label anchors at mid-radius, More fan chip positions (56 pt chips, 270 pt radius, 21° apart, centred on More's angle) with an **upward flip** when any chip would leave `screen.visibleFrame`, hit testing for each region, and scaling by the size setting (70–140 %, ring thickness, gap, orb size).
- **`SlotProvider`** builds the six slots for a file type or batch.
  - Images: `PNG, JPG, WebP, More, Compress, Resize`. The More fan holds, in board D's order, **HEIC, AVIF, TIFF, GIF, PDF, Crop**, with Crop always last (leftmost). BMP is the overflow format: it takes the chip of any fan format that can't be encoded or is the source's own format.
  - If the source already is one of the ring formats, that slot is filled by the next format in priority order. If WebP can't be encoded, HEIC moves up into its slot and BMP joins the fan.
  - PDF: `PNG, JPG, TXT, More, Compress, Resize`, with More holding Crop and "Combine" (when a batch is dropped).
  - Text and office documents: `PDF, TXT, DOCX/HTML, More, …`. Only formats that make sense are shown, and empty slots are hidden.
  - Mixed image/PDF batches get "Combine PDF".
  - Video/audio show **no buttons**. Instead the centre orb shows "Video & audio arrive in the next update".
  - **Smart ordering** reorders *format* slots only, by per-type usage counts with decay. Tools and More never move.
- **Renderers** (Core Animation only, with no continuous redraw):
  - `RingRenderer` (default) uses a `NSVisualEffectView` disc (`.hudWindow`, `.behindWindow`, dark appearance) masked to a circle, a tint layer, a hairline, an inner glow and a depth-shadow layer. Every value is in §9.1. Each segment is a `CAShapeLayer` with an SF Symbol image layer (rasterised once per symbol/size and cached) and a `CATextLayer` label.
  - Hovering animates the segment path with `CASpringAnimation`, ripples to the neighbours (delay 0/30/60 ms) and dims them to 55 %. The "tilt toward the cursor" is a small `CATransform3D` rotation about the axis perpendicular to the cursor vector (≤ 6°).
  - `OrbitRenderer` draws six separate floating round glass buttons. `HaloRenderer` draws a solid graphite ring with monospace text-only labels and a neon accent, and is also the **Reduce Transparency** fallback.
  - All three share `WheelLayout`, `SlotProvider` and the centre orb.
- **`CentreOrbView`** is a 180 pt layer stack: the QuickLook thumbnail at 22 %, a kicker, a big label (crossfade + 6 pt vertical slide on change), a detail line, the file name and size, and a batch count badge. Its Cancel state changes the border and label colours.
- **`SizeEstimator`** runs when the wheel opens. It asynchronously encodes a ≤ 512 px downsample per visible format slot and compress preset, scales the byte count by the pixel ratio and shows "about 2.9 MB". It is cancelled when the wheel closes. Until a value is ready the orb shows "estimating…".
- **Motion:**
  - Bloom: a 180 ms spring from the cursor (scale 0.6 → 1, alpha 0 → 1), with segments staggered by 25 ms.
  - Release: the thumbnail flies into the chosen segment, then everything fades out.
  - Reduce Motion: a 120 ms crossfade only.
  - Animation styles are Bloom, Pop, Fade and Instant, each with a speed multiplier.
- **Feedback:** `NSHapticFeedbackManager` `.alignment` on segment change, plus optional sounds (off by default, three packs).

### 3.4 Menu bar (`App/MenuBar`)

- **`StatusItemController`** draws the board-H segmented-ring glyph with a centre dot (exact paths in §9.3) in a custom layer-backed view inside `NSStatusItem.button`.
  - It is a template image in monochrome style, with colour and minimal (dot-only) styles as alternatives.
  - States: idle, drag-over (filled chip), converting (a progress ring driven by aggregate `JobEvent`s; animations exist only while converting), done (one checkmark pulse, back to idle after 3 s via a single one-shot timer), error (red badge until the panel opens) and paused (dimmed ring + pause bars).
  - Optional extras: a percentage text next to the icon, and hiding the icon entirely (reopening the app shows it again).
  - The button view is a drag destination, so dragging onto it opens the panel already in the mini-wheel drop state.
- **`MenuPanel`** is a borderless, **non-activating, key-capable** `NSPanel` (not `NSPopover`).
  - Position: the panel's top is **8 pt below the bottom of the menu bar** (board I; see §9.5), its right edge is clamped to `visibleFrame`, and it is notch-aware (it uses the status item's window frame on its own screen). Every visual value is in §9.2.
  - Size: width S/M/L = 340/380/440, height fits the content up to 80 % of the screen.
  - Look: `.popover` material, 16 pt continuous corners, hairline, shadow.
  - Motion: opens with a 220 ms spring (scale 0.96 → 1, anchored at the status item) and closes with a 120 ms fade. It closes on an outside click (a local + global mouse-down monitor **installed only while the panel is open**) and on Esc.
  - **The SwiftUI hosting view is created on open and released on close.**
- **`PanelViewModel`** (one `@MainActor` observable) is the single source of truth for every layout. It holds the status line, pause state, jobs, presets, stats summary, recents, drop-zone state and command-bar state. `StackPlusView`, `TabsView` and `MiniView` are pure views over it.
- **Sections** (each can be shown, hidden and reordered): Header (status dot + Pause switch with long-press durations), ⌘K bar, Stats strip, In progress, Presets grid (3×1/3×2/4×2, drop files onto tiles, edit mode), Drop zone (morphs into a mini 6-segment wheel when a drag is over it, reusing `SlotProvider` and `WheelLayout` at a small scale), Recent (thumbnails, before → after, % change, hover actions, rows dragged out as real files with `NSItemProvider(contentsOf:)`, a context menu) and Footer.
- **`CommandBar`** uses a pure fuzzy matcher (unit-tested) over recents and commands.
  - Typed queries are parsed into intents: format names (`webp`), presets (`< 2mb`, `1920w`, `no gps`), `clipboard`, `pause`, `settings`, `watch`.
  - The target is the last files handed to the app (see the Finder-selection assumption in §6, A3).
  - Keys: ↑↓ to move, ↩ to run, ⌘↩ to run and reveal.
- **`PinnedPanelController`** detaches the same content into a floating, always-on-top mini window.
  - It can be resized S/M/L and docked to any corner, and its position is remembered per display (keyed by `CGDirectDisplayID` + resolution).
  - Optional click-through via `ignoresMouseEvents`, toggled from the status item menu so it is always reversible.
- **Hotkey to open the panel:** ⌃⌥Space through `HotkeyCenter`.

### 3.5 Extras (`App/Extras`)

- **`StatsStore`** keeps daily aggregates (`date, files, bytesIn, bytesOut, byFormat`) in `~/Library/Application Support/Circularity/stats.json`, with 400 days retained and a reset option. It feeds the stats sheet (30-day bars drawn with Swift Charts on macOS 13+, by-format breakdown, all-time saved).
- **`HistoryStore`** keeps recents and history in `history.json`, capped at 1,000 entries. It is loaded lazily, and search runs in memory only while the history window is open. Thumbnails come from `QLThumbnailGenerator` into an `NSCache` (countLimit 64, totalCostLimit ≈ 8 MB).
- **`WatchFolderService`:**
  - Rules: `folder (security-scoped bookmark), match: [UTType], action: Operation | PresetID, output: inPlace | subfolder(name) | folder(bookmark), trashOriginal (confirmed)`.
  - **An `FSEventStream` exists only while ≥ 1 rule is enabled.** It uses file-level events with a 1 s latency, ignores our own outputs (via an output-path set + an xattr marker), debounces until the file size is stable, and skips partially downloaded files.
  - Built-in suggestion: "Screenshots → JPG", which reads the screenshot location from `com.apple.screencapture` defaults.
  - Before adding Desktop, Documents or Downloads, an in-app sheet explains the one-time macOS folder-access prompt. Nothing is ever watched unless the user explicitly picks it.
- **`ClipboardConverter`** reads `NSPasteboard.general` **only** when the user acts (panel button, ⌘K `clipboard`, hotkey ⌃⌥V).
  - It accepts image or PDF data, converts it through the Engine using a temp file, writes the result back to the pasteboard and can optionally save a copy.
  - On macOS versions with paste-permission prompts, a refusal or empty read shows a gentle inline message. There is no retry loop.
- **`WidgetBridge`** writes a small `WidgetSnapshot` JSON (today count, saved bytes, last 3 recents with thumbnail PNGs ≤ 64 KB) into the App Group container and calls `WidgetCenter.reloadAllTimelines()`. It is compiled only with `CIRCULARITY_WIDGET=1`, and is otherwise a no-op stub.
- **`CircularityWidget`** offers three sizes: small (today count + saved), medium (the last 3 conversions, tappable through a `widgetURL`/`Link` to reveal the file) and large (stats + recents).
  - Assumption: tapping hands off through a private `NSUserActivity`/file URL, because the public URL scheme is v1.1. If WidgetKit needs a URL, a minimal internal-only scheme is used solely by the widget and documented.
  - **It ships once a Developer ID exists**, because a sandboxed extension plus an App Group needs real signing (see §6, A6).

### 3.6 Windows (`App/Windows`), all lazy and released on close

- **Settings** is an AppKit `NSWindow` hosting a SwiftUI `NavigationSplitView` with the sidebar sections General, Gesture, Wheel, Output, Presets, Watch folders, Menu bar, Appearance, Notifications, Advanced and About. A **live preview pane** on the right shows a real `WheelLayout`-driven preview (hover and click work, image/document toggle) or a panel preview. Every change applies instantly through `SettingsStore`.
- **Onboarding** (first run) explains the Shift-drag gesture and states exactly what the app does **not** access: no Accessibility, Input Monitoring, Screen Recording, Full Disk Access, Automation, network or uploads. It then offers launch at login and, optionally, notifications (the only system prompt in onboarding, and only if the user opts in).
- **Tutorial** is interactive, with a generated practice picture: drag it, tap Shift, drop on JPG, and see the result. It works without touching the user's files, because output goes to a temp folder.
- **Resize dialog:** width × height, lock aspect, fit or stretch, the resulting pixel size and estimated bytes, and "Also add this as a button". For PDFs the options are page scale or paper size.
- **Compress dialog:** images by quality slider or target size, PDFs by light/balanced/strong, with a live estimate and "Also add this as a button".
- **Crop editor:** a movable and resizable box with ratio locks 1:1, 4:3, 3:2, 16:9, 9:16 and free. It shows a downsampled preview image (never the full 100 MP bitmap) and maps the crop rect back to source pixels. It also handles PDF crop boxes.
- **History window:** a full searchable list with the same row actions as Recent.

### 3.7 Settings, appearance and themes (`App/Settings`, `App/Appearance`)

- **`SettingsStore`** is a typed, `@MainActor` observable backed by `UserDefaults`.
  - Every key is declared once in `SettingsKeys` (Shared) with a default value and a version.
  - JSON export and import of everything goes through a versioned `SettingsSnapshot: Codable` with migrations (unit-tested).
  - "Reset all settings" is included.
  - **Reserved v1.1 keys are declared but have no UI:** `media.packEnabled`, `media.bundleMode`, `updates.channel`, `updates.automatic`, `cli.installed`, `urlScheme.enabled`, `shortcuts.enabled`, `office.automation`, `gesture.advancedEventTap`.
- **Theme model:** `Theme { id, accent, secondaryTint, glassStrength 0–100, panelTintOpacity, wheelScheme, panelScheme, fonts, perCategoryTints[images/documents/tools/(video/audio reserved)] }`.
  - Built-in themes: Tangerine (default), Glass, Graphite, Midnight, Mono, Neon, Custom. Themes can be exported and imported as JSON.
  - Accent swatches: `#FF8A00`, `#FF5E3A`, `#FFB020` and `#7C8CFF` (plus 4 more in Custom's 8-swatch palette), as well as a colour well.
  - "Follow wallpaper" takes the dominant colour of `NSWorkspace.desktopImageURL(for:)`, downsampled and clustered, **only when the button is pressed**.
- **Colour scheme** (System/Light/Dark) is set separately for the wheel and the panel.
- **Size controls:** wheel S/M/L/XL plus a slider from 70–140 %, ring thickness, segment gap, orb size, label size, panel width and density, and a global UI scale.
- **Typography:** SF Pro Rounded (default), SF Pro or SF Mono (the Halo default), with a choice of label case.
- **Accessibility:**
  - The app observes `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` and applies Reduce Motion, Reduce Transparency (→ Halo disc), Increase Contrast (stronger strokes, opaque fills) and Differentiate Without Colour (diagonal hatch + 2 pt outline on the hovered segment).
  - VoiceOver: the wheel exposes an `NSAccessibilityElement` per segment and chip (role button, label, "Convert to JPG, about 2.9 MB"), and every SwiftUI view has labels.
  - **A unit test checks WCAG contrast ≥ 4.5:1** for every theme's text/background pair. For translucent surfaces, the tint is composited over both a white and a black backdrop and the worst case is checked.

### 3.8 Platform (`App/Platform`)

- **`HotkeyCenter`** registers Carbon `RegisterEventHotKey` hotkeys (no permission), each of which can be rebound or cleared: ⌃⌥Space (panel) and ⌃⌥V (clipboard). ⌃⌥C is deliberately **not** a Carbon hotkey, because it belongs to the Service (see A3) and two owners of one shortcut would conflict.
- **`ServicesProvider`** handles NSServices "Convert with Circularity" (`NSSendFileTypes` = image, PDF and document UTIs). It receives the Finder selection with no prompt when its keyboard shortcut (⌃⌥C after setup) is pressed, and also from the right-click Quick Actions menu. Either way it opens the click-mode wheel at the cursor. `ServiceShortcutInstaller` sets the user's Services shortcut to ⌃⌥C, and falls back to opening Keyboard Shortcuts settings.
- **Open with:** `CFBundleDocumentTypes` declares image, PDF and document types with `LSHandlerRank = Alternate`, and `application(_:open:)` opens the wheel in click mode.
- **`SingleInstance`:** on launch, the app checks for another running instance with the same bundle ID.
  - **Which copy stays:** the one whose process started first (kernel start time, then pid), so two copies launched at the same moment never both quit. Milestone (a) testing caught exactly that race.
  - **Hand-off:** the running copy listens from `applicationWillFinishLaunching`. A later copy waits for the running copy's `isFinishedLaunching` (at most 5 s), posts the file paths in a distributed notification keyed on the bundle ID, and quits. An empty list means "reopen", which shows the icon.
  - Launch Services was rejected for the hand-off: with two copies of the same bundle it may route the files back to the copy that is quitting.
- **`LoginItem`** uses `SMAppService.mainApp`. It is on by default after onboarding asks.
- **`Notifier`** uses `UNUserNotificationCenter`, with one notification per drop and the actions Open and Reveal. It respects Focus (via `.timeSensitive` off and normal interruption level), and permission is requested only if the user enables notifications.
- **Logging and diagnostics:**
  - `os.Logger` uses the subsystem = bundle ID and the categories gesture, wheel, engine, panel, watch and perf.
  - A local rolling error log is kept in Application Support/Logs, at most 1 MB × 3.
  - "Copy diagnostics" collects the OS version, architecture, settings (no file paths), FormatSupport, the last 200 log lines and the gesture self-check result. "Report a bug" copies the diagnostics and opens a prefilled mail or issue template locally; nothing is sent automatically.
- **Developer HUD** (opt-in) shows FPS and RSS only during a drag, using a display link that exists only while the HUD is enabled **and** a drag is active.

### 3.9 Diagnostics and test modes (in the app binary)

- **`--perf-report`** launches, waits until idle and samples `phys_footprint` (task_info) and CPU over 10 s. It then runs a 100 MP image conversion and a 200-page PDF compress (with generated fixtures), records peak RSS, launch time (from process start to `applicationDidFinishLaunching` + first idle) and the DMG size if one is present, writes JSON + Markdown and exits.
- **`--render-previews <dir>`** renders the wheel (Ring, Orbit and Halo × image/document × rest/hover/More fan/cancel), the panel layouts, settings pages and dialogs to PNG offscreen.
- **`--drag-test`** has two levels:
  1. Always available, with no permission: it drives `WheelPanel`'s dragging-destination methods with a mock `NSDraggingInfo` to check drop-on-segment, drop-on-centre (cancel) and exit-dismiss.
  2. Optional real-event level: it starts a genuine `NSDraggingSession` from a helper window and posts synthetic `CGEvent` mouse movement plus a Shift press. **This needs Accessibility to be granted to the process running the test**, so it is documented as a developer-only step. The shipping gesture never asks for it.

---

## 4. Milestones

Each milestone follows the same steps: implement it, run `xcodegen generate`, `xcodebuild -scheme Circularity -configuration Debug build` and `xcodebuild test` (once tests exist), fix **all** errors and warnings, commit (`git commit` on `main`, conventional message + attribution trailer), then write a short report covering what works, what was verified and what remains, plus exact manual steps for anything that can't be automated.

### (a) Skeleton + menu bar item
- `project.yml` with all targets (the widget target is defined but excluded by the flag), xcconfigs, Identity constants, Info.plist (LSUIElement), entitlements and hardened runtime.
- `AppDelegate`, `AppCoordinator`, a static status item glyph (idle only) and a placeholder menu with Quit.
- Logging, `SettingsStore` scaffold with the reserved keys, `SingleInstance`, and a stub of the Engine with `JobQueue` + `OutputPlanner` (naming only).
- Script that generates the app icon (a first version is fine).
- **Verify:** the universal build succeeds with zero warnings; the app launches with no Dock icon; a second launch exits and forwards files; idle RSS is measured once as a baseline.

### (b) Gesture detection + empty wheel panel (permission-free)
- `DragMonitor`, `DragSessionTicker`, `GestureStateMachine` (+ unit tests), `TriggerPolicy` and the gesture self-check log.
- `WheelPanel` is shown and hidden at the cursor as a plain disc, with the dragging-destination plumbing that returns `.copy`, logs the drop target and runs no conversion yet.
- **Verify:** unit tests; mock `--drag-test` level 1. **Manual (reported honestly):** drag a file from Finder, tap Shift mid-drag and confirm the wheel appears without any TCC prompt on macOS 27; check System Settings → Privacy that the app is not listed under Accessibility or Input Monitoring; test that a drag starting with Shift already held does not open the wheel; and check file promises from Photos and Safari. Also select files in Finder, press the Service shortcut and confirm the wheel opens with those files and no prompt (and record whether "Use ⌃⌥C" applied automatically or needed the settings fallback). Also check that a shake mid-drag opens the wheel and that 20 ordinary drags (moving files between Finder windows, onto the Dock, into Mail) produce no false shake triggers.

### (c) Wheel UI and animations
- `WheelLayout` (+ tests for sector angles, hit tests, More fan and the flip), `SlotProvider` (with stubbed capabilities), `RingRenderer` matching the visual spec, the centre orb with morphing label and Cancel state, the More fan, bloom/ripple/release motion, Reduce Motion and Reduce Transparency (Halo disc), haptics, VoiceOver elements and keyboard navigation in click mode.
- `OrbitRenderer` and `HaloRenderer`.
- `--render-previews` (wheel only).
- **Verify:** preview PNGs are inspected against the spec numbers; the layer count stays constant across opens (built once); no animations remain after hiding.

**Built (b) + (c) together — notes and deviations:**
- Pure logic lives in `Sources/AppLogic` (gesture state machine, shake detector, wheel geometry, slot rules), compiled into the app and the host-less tests.
- The developer menu on the status item (Show Test Wheel, Wheel Layout, Trigger Key, Shake to Open, ⌃⌥C, Pause) stands in for Settings and the panel until (h)/(i).
- Choosing a segment records the choice ("Last choice: …"); conversion arrives in (d). Until the engine exists, the orb's detail line shows a short format hint instead of the live size estimate.
- WebP cannot be written by ImageIO on macOS 27, so it is hidden and AVIF/HEIC move up (verified at runtime by `FormatSupport`).
- Document menus have fewer than six actions: the unused segments are drawn but inert, rather than hidden, so the ring keeps its shape.
- Orbit's buttons use translucent fills without a per-button behind-window blur (13 extra visual-effect views were not worth the cost); Ring keeps the real glass disc.
- Ring and Orbit are drawn in their board colour schemes (dark and light); the light/dark/system choice per surface arrives with Appearance in (i).
- Memory: soft shadows and glows are rendered at quarter resolution. Measured with `--drag-test`: 9.8 MB before the first wheel, 18.7 MB while showing, 17.7 MB after hiding (budget < 25 MB).
- Manual checks for real drags, file promises, the ⌃⌥C Service shortcut and permissions: `docs/MANUAL-TESTS.md`.

### (d) Image engine
- `FormatSupport`, `ImageIOBackend` (convert, resize, crop, compress by quality and by target size, metadata policies, orientation, transparency, SVG), atomic writer, collision naming, the Documents/Converted fallback and cancellation.
- Wheel drops now run real jobs. Results get one notification per drop if notifications are enabled.
- `EngineSmokeTest` v1 covers image fixtures (generated PNG with alpha, rotated-EXIF JPEG, 100 MP synthetic, SVG with an external `href` that must **not** be fetched).
- **Verify:** smoke-test assertions (outputs decode, dimensions are correct, target sizes are respected, nothing is left behind on cancel); peak RSS on the 100 MP convert.

### (f) PDF + documents
- `PDFBackend` (to images and text, compress with verification and keep-original, resize and crop boxes), `DocumentBackend` (Markdown renderer, offscreen WebKit HTML → PDF with network blocked, `textutil` bridge, paper size by region) and `CombineBackend`.
- Slots for PDFs and documents; the friendly state for video and audio.
- Smoke tests: 200-page generated PDF, Markdown/HTML/TXT/RTF/DOCX fixtures (DOCX created with `textutil` itself), a combine in drop order, and an HTML page whose remote image request is checked as blocked.
- **Verify:** smoke tests; page counts; text equality; the compress-verification path is exercised in both directions (it keeps the original when the output isn't smaller).

### (g) Resize / Compress / Crop dialogs (images + PDFs)
- SwiftUI dialogs with live estimates, "Also add this as a button" → `PresetStore`, and the crop editor with ratio locks.
- The wheel and More fan open the dialogs; presets appear on the wheel for matching types.
- **Verify:** unit tests for crop-rect mapping and preset matching; dialog previews rendered; windows are released on close (checked by a deinit log and a memory graph spot check).

### (h) Menu bar panel: Stack+ layout, icon states, drop-on-icon, ⌘K bar
- `StatusItemController` (all states, styles, percentage, hide icon), `MenuPanel` (placement, notch, spring, outside click and Esc, content released on close), `PanelViewModel`, `StackPlusView` (Header, ⌘K, Stats strip placeholder, In progress, Presets grid, Drop zone → mini wheel, Recent, Footer), `HistoryStore`, the history window, row drag-out and row actions, and the ⌃⌥Space hotkey.
- **Verify:** fuzzy-matcher tests; panel preview renders; manual checks of notch placement, drop on the icon and dragging out a recent row into Finder.

### (h2) Menu bar extras, then Tabs and Mini
- `StatsStore` + stats sheet, `WatchFolderService` (+ rule-matching tests and the protected-folder explainer), `ClipboardConverter` + ⌃⌥V, the pinned panel (S/M/L, corner docking, per-display memory, click-through), `WidgetBridge` and the `CircularityWidget` target (built only with `CIRCULARITY_WIDGET=1`).
- Then `TabsView` and `MiniView` over the same view model.
- **Verify:**
  - With no watch folders there is no FSEventStream: checked with `lsof`/log, and the idle CPU sample stays ~0 %.
  - The clipboard is never read without an action, checked by code audit plus a log.
  - `xcodebuild … CIRCULARITY_WIDGET=1` compiles; it is expected not to run without signing, and that is documented.

### (i) Settings, appearance, onboarding, tutorial
- Full settings window with all sections and live preview, the theme system + Custom editor + JSON import/export, per-category tints, size and typography controls, accessibility modes, the contrast unit test, settings export/import/reset, launch at login, rebinding hotkeys, the excluded-apps list, a gesture test area, sound packs (generated), onboarding with the "what we don't access" screen, the tutorial with a practice picture and About (version, detected tools/FormatSupport, credits to Circularity for Windows by Atharv Gogia, MIT, and Tangerine by LEAP STUDIO as inspiration, licences).
- **Verify:** contrast test passes for every theme; settings snapshot round-trip and migration tests; previews of every settings page.

### (j) Ad-hoc signing, gated notarisation scripts, DMG
- `build.sh` (Release, universal, stripped, ad-hoc `codesign --force --deep -s - --options runtime`), `sign.sh`, `notarize.sh` and `release.sh` (each prints a clear message and exits 0 when `DEVELOPER_ID_APP`/`NOTARY_PROFILE` are unset), `dmg.sh` using create-dmg (generated background art, volume icon, app + Applications link layout) and `dmg-arm64.sh`.
- README section on first launch: right-click → Open, or System Settings → Privacy & Security → Open Anyway.
- **Verify:** `codesign -dv --verbose=4` shows adhoc + runtime; `lipo -archs` shows `x86_64 arm64`; the DMG mounts and its layout is correct; the DMG size is recorded.

### (k) Tests, perf report, polish
- Complete the unit tests (gesture state machine, ring and More-arc layout, output naming, fuzzy matcher, watch rules, settings migration, theme contrast, slot ordering), finish `EngineSmokeTest` (every conversion, resize, crop and compress through the real queue; batches; cancellation; unsupported formats), real-event `--drag-test` level 2 documented, and `--perf-report` + `docs/PERF-REPORT.md` with measured numbers.
- Fix anything that misses budget. Write `docs/INSTRUMENTS.md`, `docs/MANUAL-TESTS.md`, README (with a GIF-recording checklist), LICENSE (MIT), THIRD-PARTY-NOTICES and `docs/RELEASE-CHECKLIST.md` (ad-hoc DMG now; later Developer ID, notarise, staple, appcast and Homebrew cask).

---

## 5. Performance budget and how it is enforced

| Budget | Mechanism | Measured by |
|---|---|---|
| Idle < 25 MB RSS, ~0 % CPU | AppKit-only at launch (SwiftUI, WebKit, QuickLook and Charts are not touched until needed); the wheel panel is built on first use; no timers, polling or FSEvents unless a watch folder is enabled; App Nap is not disabled | `--perf-report` (phys_footprint, 10 s CPU sample) |
| Gesture-time objects only during a drag | Ticker, HUD display link and estimator tasks are created on drag start and cancelled on mouse up (asserted in debug builds) | debug assertions + log |
| No continuous redraw | Core Animation implicit and spring animations only; no `draw(_:)` loops | Instruments (Core Animation FPS only during interaction) |
| Lazy windows, released on close | Each window controller is owned optionally by the coordinator and set to nil on `windowWillClose`; deinit is logged in debug builds | deinit logs + memory graph |
| Large-job memory | Streamed ImageIO, thumbnail-based resize, per-page PDF loop inside `autoreleasepool` | `--perf-report` peak RSS on 100 MP and 200-page fixtures |
| Small binary and DMG | Strip symbols (`STRIP_INSTALLED_PRODUCT`, `DEAD_CODE_STRIPPING`), minimal asset catalog, no third-party frameworks | DMG size in the report |

**Risk:** a SwiftUI-capable AppKit agent can idle above 25 MB once SwiftUI has loaded. Mitigation: SwiftUI is never instantiated at idle, and panel content is torn down on close. If the budget is still missed after the panel has been opened once, the report will say so honestly, with numbers and what was tried.

---

## 6. Assumptions (decisions made autonomously)

- **A1. The brief file.** `circularity-brief-v3.md` was renamed to `BRIEF.md`.
- **A2. Mockups.** The board sources and 2× PNG renders are in `design/circularity-design-v2/` (HTML in the canvas template format, see its README). Values for D (wheel), I (panel) and H (icons) are transcribed in §9 and were checked against `D-wheel-chosen_{hover-JPG,more-fan-open,cancel,compress}.png`, `I-panel-chosen{,_drop-zone-mini-wheel,_paused}.png` and `H-icon-states.png`.
  - B (Orbit), C (Halo), F (Tabs) and G (Mini) are read and transcribed when their milestones start: B and C in (c), F and G in (h2).
  - A is reference only.
  - Fake wallpaper, fake menu bar and placeholder data in the boards are ignored.
- **A3. How the wheel opens, with zero permissions and no right-click.** (Decided after review.)
  - **While dragging (main path):** drag a file and tap **Shift**. The wheel opens at the cursor; release on a segment. Nothing to right-click or choose from a menu. A **quick shake** of the cursor mid-drag also opens it, for one-handed use. **This is on by default** (the user chose all three triggers active). It can be turned off in Settings → Gesture. See §3.2.
  - **Without dragging (files already selected in Finder):** select the files and press **⌃⌥C**. The wheel opens at the cursor; hover and click, or use the arrow keys + Return.
    - How it works: ⌃⌥C is the **keyboard shortcut of our macOS Service**, not a Carbon hotkey. When a Service's shortcut is pressed, macOS hands the Finder selection to the app. No Accessibility, Automation or any other TCC permission is involved, and no menu is shown.
    - Service shortcuts declared in Info.plist (`NSKeyEquivalent`) must include ⌘. So the app ships a ⌘-based default and offers a one-click "Use ⌃⌥C" in onboarding and Settings, which writes the user's own Services shortcut preference (the same setting as System Settings → Keyboard → Keyboard Shortcuts → Services). If that write doesn't take effect on the running macOS, the button opens that settings page instead, so the shortcut can be set there.
    - This is verified on macOS 27 in milestone (b).
  - The ⌘K bar and preset tiles act on the files most recently handed to the app (by the Service, a drop, Open or the drop zone). Otherwise they show an Open panel.
  - The right-click Quick Actions → "Convert with Circularity" entry remains available, but nothing depends on it.
  - A Finder-selection mode that uses Automation is added to the v1.1 backlog as opt-in.
- **A4. Drag events while another app owns the drag session.** Global `leftMouseDragged` delivery during a Finder drag is not guaranteed, so a drag-scoped ticker samples permission-free `NSEvent` class properties instead. This stays within "timers only during a drag".
- **A5. The ad-hoc build and the WebKit/textutil helpers** run inside the hardened runtime without extra entitlements. JIT is not needed because WebKit's JIT runs in its own XPC processes. This is to be confirmed in milestone (f); if an entitlement turns out to be needed, it will be added and documented.
- **A6. The widget** is built only with `CIRCULARITY_WIDGET=1`. The App Group ID will be `$(TeamIdentifierPrefix)com.kunal.circularity`, the macOS-preferred team-prefixed form, once a Team ID exists. Until then, ad-hoc DMGs contain no widget. It ships once a Developer ID exists.
- **A7. Paper size:** Letter for US, CA, MX, PH, CL, CO, VE and GT region codes; A4 everywhere else.
- **A8. PDF compression** uses public Quartz `QuartzFilter` on a `CGPDFContext`. If the filter API turns out to be unusable on the running OS, the fallback recompresses pages that contain only images by redrawing them, and leaves vector pages untouched. The verification gate still applies, so nothing ever silently degrades.
- **A9. Notifications** need a one-time system prompt. It is asked only when the user enables notifications (onboarding offers it, defaulting to off), so the core gesture stays prompt-free.
- **A10. A watched protected folder and the clipboard** may trigger system prompts by design. Both are explicit user actions, explained in-app beforehand.
- **A11. Same-format slots** are replaced by the next format in priority order rather than shown disabled.
- **A12. Sounds and the app icon** are original and generated by scripts in the repo, so there are no licensing questions.
- **A13. Toolchain:** Xcode 27.2 on macOS 27 (arm64) for development; XcodeGen and create-dmg are installed via Homebrew. The x86_64 slice is compiled but can only be smoke-run under Rosetta, which will be stated in reports.
- **A14. Git:** the branch is `main` (renamed from `master` before the first commit). Milestone commits go on `main`. The generated `.xcodeproj`, `build/`, `dist/` and `.DS_Store` are git-ignored (the `.gitignore` arrives in milestone a).
- **A15. "Replace original"** always moves the original to the Trash (it is recoverable) and is never a destructive overwrite.
- **A16. Localisation:** English only in v1, but every user-facing string goes through a String Catalog, so the language follows the system once translations exist.

---

## 7. v1.1 backlog (designed for, not built)

| Feature | Hook already in v1 |
|---|---|
| FFmpeg Media Pack (LGPL, VideoToolbox H.264/HEVC, lame/vorbis/opus/webp/aom), downloaded on first use, checksum-verified, cached in Application Support, short-lived child process, utility QoS; build flag to bundle | `ConversionBackend` + `BackendRegistry` capability table; `media.*` settings keys; per-category tint for video/audio reserved; the video/audio friendly state in the wheel centre is the entry point for "Get Media Pack" |
| Video/audio conversion, Trim, video crop/resize/compress, AVIF/WebM encode | New `Capability` entries + dialogs; the wheel's `SlotProvider` gets video/audio slot tables |
| Sparkle 2 updates + "Check for updates" in the footer | `updates.*` keys; footer slot reserved |
| `circularity` CLI | Engine is already a UI-free library driven by `JobRequest` (EngineSmokeTest proves it) |
| URL scheme | `urlScheme.enabled` key; `AppCoordinator.handle(intent:)` entry point shared with Services and Open |
| Shortcuts actions (App Intents) | Same `handle(intent:)` entry point; presets are already a serialisable model |
| Office/iWork automation | `office.automation` key; `DocumentBackend` routing point |
| Opt-in event-tap "Advanced gestures" (Input Monitoring) | `gesture.advancedEventTap` key; `GestureStateMachine` takes abstract events, so an event-tap source plugs in beside `DragMonitor` |
| Opt-in Automation-based Finder selection (see A3) | Target-resolution rule isolated in `SelectionResolver` |
| Widget in shipped builds; Developer ID + notarisation + Homebrew cask + appcast | `CIRCULARITY_WIDGET` flag; gated scripts; release checklist |

---

## 8. Risks to spike early

1. **Drag detection on macOS 27 without TCC** (milestone b). This is make-or-break. A4 is the fallback.
2. **The wheel receiving dragging-destination callbacks** when it is ordered in mid-drag above `.popUpMenu`, including in full-screen Spaces (b/c).
3. **Paginated HTML → PDF from an offscreen WKWebView** on macOS 13 through 27 (f). The fallback is NSAttributedString + CoreText pagination.
4. **SVG rasterisation with the network blocked** on macOS 13 (d).
5. **Quartz-filter PDF compression** quality and verification (f), with the A8 fallback.
6. **The idle RSS budget** with SwiftUI present in the binary (a, then k).

---

## 9. Design spec: exact values from the boards

The values below come from the HTML sources in `design/circularity-design-v2/`, checked against the PNG renders there. They are at 100 % scale, in points; the PNGs are 2×, so divide pixel positions by 2.

**About the PNGs:** they render text in Inter, not SF Pro Rounded (see the folder's README), so text widths, wraps and clipping in them are not authoritative. Geometry, colours and states are.

**How CSS maps to AppKit**
- **Fonts:** `ui-rounded` is SF Pro Rounded. CSS weights 600, 700 and 800 map to `.semibold`, `.bold` and `.heavy`.
- **Letter-spacing:** CSS `letter-spacing: Nem` becomes a kern of N × font size in points.
- **Colours:** `rgba(r,g,b,a)` becomes sRGB `NSColor`.
- **Angles:** 0° = 12 o'clock, increasing clockwise, as in the boards' `pt()`/`arc()`.
- **Blur:** CSS `backdrop-filter: blur(n) saturate(1.6)` cannot be set exactly on `NSVisualEffectView`. The listed material plus the tint layer is the closest match. The blur radius is kept in the theme model for the Glass-strength slider.

**Shared colour tokens** (the Tangerine dark default, used by both the wheel and the panel)

| Token | Value | Used for |
|---|---|---|
| `text.primary` | `#F4F1EC` | main text, idle segment labels |
| `text.onAccent` | `#1A1206` | text and glyphs on accent fills |
| `text.strong2` | `#E6E1D8` | orb detail line, footer buttons, drop-zone title, cancel ✕ |
| `text.secondary` | `#C9C3B9` | orb kicker and file line, panel status line, Pause label |
| `text.meta` | `#B4AEA5` | job meta, recent size line, drop-zone hint |
| `text.tertiary` | `#A9A39A` | section headers, stat labels, ⌘K glyph, "2 min", keyboard hint |
| `text.placeholder` | `#9C968D` | ⌘K placeholder; also the paused status dot |
| `chip.text` | `#D9D3CA` | ⌘K key chip |
| `link` | `#FFB366` | "Cancel all", "Edit", "Show all". This is a fixed tint of the default accent; other themes derive it as the accent mixed 40 % with white, and it must pass the contrast test |
| `accent` | `#FF8A00` (swatches `#FF5E3A`, `#FFB020`, `#7C8CFF`) | |
| `cancel.border` / `cancel.text` | `#FF7A6E` / `#FF8A80` | |
| `delta.smaller` | `#8BE0A4` | recent rows, file got smaller |
| `delta.larger` | `#B4AEA5` | file got larger: neutral grey, **not** red |
| `thumb.photoBg` / `thumb.docBg` / `thumb.docGlyph` | `#F6C79B` / `#EDE8E1` / `#5E574D` | placeholder thumbnails before QuickLook returns |
| `error` | `#E5483D` | status-item error badge |

### 9.1 Wheel: "Ring" layout (board D, `wheel-D-chosen.html`)

**Canvas and disc**
- The panel content is 720 × 720 with the centre at (360, 360).
- Disc:
  - Diameter 436 (inset 142).
  - Tint `rgba(24,24,28,0.55)` over the `.hudWindow` material.
  - 1 pt inner hairline `rgba(255,255,255,0.12)`.
  - Inner top glow: inset, y 2, blur 34, `rgba(255,255,255,0.07)`.
  - Drop shadow: y 40, blur 90, `rgba(0,0,0,0.5)`.

**Segments** (6 of them; the slot at index *i* has its midpoint at *i* × 60°)

| | At rest | Hovered (and More while its fan is open) |
|---|---|---|
| Angular span | mid ± 28.5° (57° segment, 3° gap) | same |
| Inner / outer radius | 98 / 204 | 92 / 216 |
| Fill | `rgba(255,255,255,0.07)` | accent |
| Stroke (1 pt) | `rgba(255,255,255,0.10)` | `rgba(255,255,255,0.35)` |
| Label and glyph colour | `#F4F1EC` | `#1A1206` |
| Opacity of the *other* segments | 1 | **0.55**, but only while a segment or chip is hovered. Nothing dims while Cancel is hovered or nothing is hovered |

**Slot angles:** PNG 0°, JPG 60°, WebP 120°, More 180°, Compress 240°, Resize 300°.

**Segment content**
- Content is a vertical stack centred at the *current* mid-radius: 151 at rest, 154 when hovered, so it moves with the bulge.
- The stack is a 22 pt glyph, a 6 pt gap, then the label at 15 pt bold with a kern of 0.3.
- Glyphs are SF Symbols weighted to the boards' 1.8 stroke:

  | Slot | SF Symbol |
  |---|---|
  | Format | `photo` |
  | More | `ellipsis` |
  | Compress | `arrow.down.right.and.arrow.up.left` |
  | Resize | `arrow.up.left.and.arrow.down.right` |
  | Crop (fan chip) | `crop` |
- VoiceOver labels follow the boards' `verb`: "Convert to PNG", "More formats", "Compress…", "Resize…".

**More fan**
- Chips: 56 × 56 circles at radius 270, at angles 180° + (k − (n−1)/2) × 21°. For the default six chips that gives:

  | Chip | Angle |
  |---|---|
  | HEIC | 127.5° |
  | AVIF | 148.5° |
  | TIFF | 169.5° |
  | GIF | 190.5° |
  | PDF | 211.5° |
  | Crop | 232.5° |

  Formats sit on the right and Crop on the left.
- The fan is visible while More or any chip is hovered.
- Chip at rest:
  - Fill `rgba(28,28,32,0.72)` over a 20 pt-blur material.
  - 1 pt border `rgba(255,255,255,0.16)`.
  - Shadow y 10, blur 24, `rgba(0,0,0,0.4)`.
  - Text-only label, 12 pt bold, `#F4F1EC`.
- Hovered chip: accent fill, `#1A1206` text, scale 1.14.
- **Flip** (when a chip would leave `visibleFrame`): the arc is centred on 0° instead, at angles 0° + ((n−1)/2 − k) × 21°, so formats stay on the right and Crop on the left.

**Centre orb**
- 180 × 180 circle, fill `rgba(14,14,16,0.78)`.
- Border 1.5 pt, `rgba(255,255,255,0.18)`, or `#FF7A6E` when Cancel is hovered.
- Shadows: inset top highlight (y 1, `rgba(255,255,255,0.12)`) plus drop shadow (y 10, blur 30, `rgba(0,0,0,0.35)`).
- The QuickLook thumbnail fills it, clipped to the circle, at **opacity 0.22**.
- Text is a centred vertical stack with a gap of 3:

  | Line | Size and weight | Kern | Colour |
  |---|---|---|---|
  | 1. Kicker | 10 pt bold | 0.8 | `#C9C3B9` |
  | 2. Big label | 32 pt heavy, one line, **shrinks to fit 160 pt** (minimum scale 0.75), never wraps or truncates | 0.64 | accent, or `#FF8A80` when Cancel is hovered |
  | 3. Detail | 12 pt semibold | — | `#E6E1D8` |
  | 4. File line (after a 6 pt top margin) | 11 pt regular | — | `#C9C3B9`; format `NAME.EXT · 3.2 MB` |

**Orb copy per hover state**

| Hovered | Kicker | Big | Detail |
|---|---|---|---|
| *nothing* or the centre | DROP HERE TO | Cancel | nothing is changed |
| Format segment or chip | CONVERT TO | `JPG` | `about 2.9 MB` (from the live estimate) |
| More | REST HERE FOR | More | `6 more options` (the count of chips) |
| Compress / Resize / Crop | OPEN | Compress / Resize / Crop | `quality or target size` / `width × height` / `1:1 · 4:3 · 16:9` |

When nothing is hovered, the big "Cancel" stays in the accent colour. The red colours apply only while the centre itself is hovered.

**Cursor:** no custom label and no custom drag image. The board's pointer and 30 × 30 thumbnail stand for the system drag image.

### 9.2 Menu bar panel: "Stack+" layout (board I, `panel-I-chosen.html`)

**Container**
- Width 380 (size M; S and L are 340 and 440).
- Corner radius 16 (continuous).
- Background `rgba(30,30,34,0.74)` tint over the `.popover` material (dark).
- 1 pt border `rgba(255,255,255,0.12)`.
- Inner top highlight: y 1, `rgba(255,255,255,0.08)`.
- Shadow: y 30, blur 70, `rgba(0,0,0,0.5)`.
- **Padding 14, vertical gap 12 between sections**, giving a content width of 352.
- Top edge 8 pt below the menu bar.

**Header** (a row with a gap of 10)
- App tile: 34 × 34, radius 10, accent fill. It holds the §9.3 glyph at 20 pt in `#1A1206`, stroke 2.4.
- Title "Circularity": 15 pt heavy.
- Status line: 12 pt, `#C9C3B9`, after a 7 pt dot with a gap of 6. It may wrap to **2 lines** (the PNGs show it wrapping beside the Pause control), then truncates at the tail. The dot aligns with the first line.
  - The dot is accent while active and `#9C968D` while paused.
  - Copy uses " · " separators, for example "Converting 1 file · Shift-drag ready" and "Paused · the wheel will not appear".
- Pause control: the label "Pause" (12 pt semibold, `#C9C3B9`), a gap of 8, then a switch.
  - Switch track: 34 × 20, radius 10; `rgba(255,255,255,0.18)` when off, accent when on.
  - Knob: 16 pt white, x = 2 when off and 16 when on, shadow y 1, blur 3, `rgba(0,0,0,0.4)`.

**⌘K bar**
- Height 38, radius 10, horizontal padding 12, gap 8.
- Fill `rgba(255,255,255,0.07)`, border `rgba(255,255,255,0.08)`.
- Prompt glyph: 14 pt, colour `#A9A39A`. It is drawn from the board's own path, `M4 17l6-6-6-6M12 19h8` (a `>_` prompt) in a 24 box, stroke 2.4, round caps and joins, because no SF Symbol matches it.
- Input: 12 pt. The placeholder `Search recents, or type “webp”, “< 2mb”, “clipboard”…` is `#9C968D`, one line, **truncated at the tail with an ellipsis**. The PNG clips it mid-word, which would look broken.
- Key chip "⌘K": 10 pt bold, padding 2 × 6, radius 5, fill `rgba(255,255,255,0.10)`, text `#D9D3CA`.

**Stats strip**
- 3 equal columns, gap 8.
- Tile: padding 8 × 10, radius 10, fill `rgba(255,255,255,0.05)`, inner gap 1.
- Label: 10 pt bold, kern 0.6, `#A9A39A`. The labels are `TODAY`, `SAVED · WEEK` and `WATCHING`.
- Value: 17 pt heavy. The saved value is in the accent colour.

**Section header rows** (In progress, Presets, Recent)
- Space-between row.
- Title: 11 pt bold, kern 0.88, `#A9A39A`. The titles are `IN PROGRESS · <n>`, `PRESETS · DROP ONTO ONE` and `RECENT`.
- Action: 12 pt semibold in `link`, with padding 4. The actions are "Cancel all", "Edit" and "Show all".

**Job card**
- Row: padding 10, radius 12, gap 10, fill `rgba(255,255,255,0.06)`, border `rgba(255,255,255,0.06)`.
- Thumbnail: 42 × 42, radius 9.
- Text column (gap 6):
  - Title: 13 pt bold, one line, ellipsis. Format `<name> → <target>`, for example "Lease scan.pdf → Compress · balanced".
  - Progress bar: height 5, radius 3, track `rgba(255,255,255,0.12)`, fill accent.
  - Meta line: 11 pt, `#B4AEA5`, for example "Page 31 of 44 · about 9 s left".
- Cancel button: a 28 pt circle with fill `rgba(255,255,255,0.08)` and a 12 pt ✕ in `#E6E1D8`.

**Presets grid**
- 3 columns (or 4 for the 4×2 setting), gap 8.
- Tile: height 58, radius 12, 1 pt border `rgba(255,255,255,0.08)`, fill `rgba(255,255,255,0.06)`, centred column with a gap of 2.
  - Big label: 14 pt heavy.
  - Small label: 10 pt semibold at opacity 0.8.
- Hovered or drag-targeted tile: fill and border accent, text `#1A1206`.
- Built-in tiles (big / small): `→ JPG`/images, `< 2 MB`/compress, `1920w`/resize, `→ PDF`/combine, `No GPS`/strip metadata, `Copy PNG`/clipboard.

**Drop zone**
- Height 128, radius 14, 1.5 pt **dashed** border.
- Idle: border `rgba(255,255,255,0.22)`, fill `rgba(255,255,255,0.03)`.
- Drag over: border accent, fill accent at 8 %.
- Idle content (a column with a gap of 8):
  - A 30 pt download glyph in accent.
  - "Drop files to convert", 13 pt bold, `#E6E1D8`.
  - "or click to choose · works on the menu bar icon too", 11 pt, `#B4AEA5`.
- Active state (the mini wheel):
  - Centred at (176, 64) inside the 352 × 128 box.
  - Segments span mid ± 28° (4° gap), radius 26 → 58.
  - Segment fill `rgba(255,255,255,0.08)`, hovered accent. Stroke `rgba(255,255,255,0.14)`.
  - Text labels, 10 pt bold, at r 42: `#E6E1D8`, or `#1A1206` when hovered. The labels are shortened: **PNG, JPG, WebP, More, Shrink, Size**.
  - Centre: a 48 pt circle, `rgba(14,14,16,0.8)`, with "Drop" at 10 pt bold, `#C9C3B9`.

**Recent**
- The list has a gap of 2 and pulls up 4 pt (margin-top −4).
- Row: padding 7 × 8, radius 10, gap 10. Hovered row fill `rgba(255,255,255,0.08)`.
- Thumbnail: 36 × 36, radius 8.
- Name: 13 pt bold, ellipsis.
- Size line: 11 pt, `#B4AEA5`.
  - Format: `HEIC → PNG · 3.2 MB → 9.8 MB` when the format changed, `1920 × 1080 · 2.4 MB → 640 KB` for a resize.
  - The delta follows at bold weight: `−78%` (true minus sign) in `delta.smaller`, or `+206%` in `delta.larger`.
- Right side when idle: relative time, 11 pt, `#A9A39A` ("2 min", "1 h").
- Right side when hovered: 4 buttons, each 26 × 26, radius 7, fill `rgba(255,255,255,0.10)`, with a 14 pt glyph, gap 2. In order: Show in Finder (`folder`), Quick Look (`eye`), Convert again as (`arrow.triangle.2.circlepath`), Undo: move result to Trash (`arrow.uturn.backward`).

**Footer**
- Top border 1 pt `rgba(255,255,255,0.10)`, padding-top 10, gap 4.
- Text buttons: height 30, padding 0 × 10, radius 8, 12 pt semibold, `#E6E1D8`, with a 14 pt glyph and a gap of 6. They are Settings (`gearshape`) and Tutorial (`play.circle`).
- Hint: "⌘, settings · ⌘Q quit", 11 pt, `#A9A39A`, pushed to the trailing side.
- Icon buttons: 30 × 30. **Pin** (`pin`) is added immediately before **Quit** (`power`). Board I has no Pin button, but the brief requires one (see §9.5).

**Light colour scheme:** board I is dark only. Light values are derived by inverting the white overlays to black overlays at the same alphas, and the text tokens become their dark counterparts from board H's light row (`#1D1B18` primary, `#5E574D` secondary). All of them are checked by the contrast unit test.

### 9.3 Status item icon (board H, `icons-H-states.html`)

**Glyph**
- Defined in a 24 × 24 box, stroke width 2.4, round caps.
- Drawn at **16 pt** in the menu bar (the standard status-item glyph size); the board-H cells show it at 32 pt. Board I's menu-bar strip is backdrop only, per the design README. Its in-bar icon (segment 1 lit, the others at 35 %) is **not** a state to build. Converting always uses board H's progress ring.
- Paths (copied verbatim into `StatusGlyph.swift` and the app-icon script):
  - Segment 1: `M12 3 a9 9 0 0 1 8.5 6` (about 0° → 70.6°)
  - Segment 2: `M20.8 13.5 A9 9 0 0 1 12 21` (about 99.7° → 180°)
  - Segment 3: `M8.5 20.3 A9 9 0 0 1 3.4 9.5` (about 202.9° → 286.2°)
  - Centre dot: a circle at (12, 12) with r 2.2, filled.
- The gaps are deliberately uneven (about 29°, 23° and 74°). That is the original mark.

**States**

| State | Drawing |
|---|---|
| Idle | glyph in `fg` |
| Drag over icon | glyph on a chip: 26 × 22, radius 5 (52 × 44, radius 9 at the board's scale). Chip fill: light mono `rgba(0,0,0,0.12)`, dark mono `rgba(255,255,255,0.20)`, colour style accent with the glyph in `#1A1206` |
| Converting *p* | a full circle at r 9 in `fg` at 30 % opacity, then a progress arc at r 9 in `ac`: start at 12 o'clock, clockwise, round cap, length *p* × 56.55. Centre dot r 2.2 in `fg` |
| Done | a circle at r 9 plus a check `M8 12.5 l2.7 2.7 L16 9.8` in `ac`, with round joins. It pulses once, then returns to idle after 3 s. With Reduce Motion, nothing pulses |
| Error | the glyph with segment 1 shortened to `M12 3 a9 9 0 0 1 4 1`, plus a badge circle at (19, 5) with r 4.2 in `#E5483D`, and a white "!" drawn as `M19 3.2 v2.2` and `M19 6.9 v0.1` at stroke 1.6. It stays until the panel opens |
| Paused | the three segments in `fg` at **40 %** opacity, with no centre dot, plus two pause bars: rectangles at x 9.2 and 12.8, y 8.5, 2 × 7, rx 1, filled `fg` at 100 % |

**Colour per style**

| Style | `fg` | `ac` |
|---|---|---|
| Monochrome (light bar) | `#1D1B18` | same as `fg` |
| Monochrome (dark bar) | `#F2F2F2` | same as `fg` |
| Colour | `#F2F2F2` on a dark bar | accent; used **only** for progress and done |

- Red is used **only** for errors, in every style.
- The board's mono colours stand for the menu bar's template tint. Because the error badge must stay red, which a template image cannot do, the icon is drawn in a custom view. Mono `fg` is taken from the status button's effective appearance (`labelColor`), so it still follows the menu bar exactly like a template.
- The "minimal" style (dot only) comes from the brief and has no board. It is the centre dot at r 2.2 plus the badge and progress behaviour scaled to it.

**Status item while the panel is open:** the system's own status-button highlight (`button.highlight(true)`), not a custom chip, because the board-I strip it resembles is backdrop only. The **drag-over** chip above is custom, because it is a board-H state.

### 9.4 Motion values

The boards are static, so the brief's timings remain the spec:
- Bloom: 180 ms spring, scale 0.6 → 1, alpha 0 → 1.
- Segment pop-in stagger: 25 ms.
- Radii: spring, rippling to the neighbours with delays of 0, 30 and 60 ms.
- Orb label: crossfade plus a 6 pt vertical slide.
- Panel: opens with a 220 ms spring (scale 0.96 → 1), closes with a 120 ms fade.
- Drop-zone ↔ mini-wheel morph: a spring.
- Reduce Motion: a 120 ms crossfade only.

### 9.5 Where the boards and the brief differ (the boards win unless noted)

| Topic | Brief | Board | Decision |
|---|---|---|---|
| Disc tint | black 55 % | `rgba(24,24,28,0.55)` | board |
| Orb fill | black 78 % | `rgba(14,14,16,0.78)` + shadows | board |
| Orb text when nothing is hovered | (not stated) | "DROP HERE TO / Cancel / nothing is changed" in accent | board |
| Dimming of neighbours | always on hover | not while Cancel is hovered | board |
| More fan contents | "the rest" | HEIC, AVIF, TIFF, GIF, PDF, Crop | board; BMP is the overflow (§3.3) |
| Segment tilt toward the cursor | yes | not shown (static board) | keep the brief's tilt, ≤ 6° |
| Segment glyphs | SF Symbols | custom stroke icons | SF Symbols chosen to match (§9.1) |
| Panel offset | 6 pt below the status item | 8 pt below the menu bar | board |
| Pin button in the footer | required | absent | brief: add the Pin icon button before Quit |
| Mini-wheel labels | same as the big wheel | shortened (Shrink, Size) | board |
| Growth delta colour | (not stated) | neutral `#B4AEA5`, not red | board |
| Status icon "minimal" style | required | absent | brief: dot-only, defined in §9.3 |
| Wheel panel size | (not stated) | 720 × 720 canvas | board |
