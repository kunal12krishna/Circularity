You are a senior macOS engineer and product designer. Build a complete, shippable, native macOS app from scratch in this empty directory. Work autonomously: do not ask me questions, make sensible decisions, and record assumptions in PLAN.md. Use git, commit after each milestone, and run `xcodebuild` after every milestone, fixing all errors and warnings before moving on.

# DECISIONS ALREADY MADE (these override anything later in this brief)

1. **Scope: v1 = core plus the menu bar extras.** Build milestones (a) skeleton, (b) gesture, (c) wheel, (d) image engine, (f) PDF + documents, (g) Resize / Compress / Crop dialogs for images and PDFs, (h) menu bar panel, (h2) menu bar extras: stats, watch folders, clipboard convert, a detachable pinned panel and a desktop widget, (i) settings + customisation + onboarding + tutorial, (j) ad-hoc signing + DMG, (k) tests + perf report.
   **Deferred to v1.1** (design the protocols and settings keys so they slot in later, but do not build them now): the FFmpeg Media Pack and all video/audio conversion, Trim, video crop/resize/compress, Sparkle updates, the `circularity` CLI, the URL scheme, Shortcuts actions, Office/iWork automation, and the opt-in event-tap "Advanced gestures". In v1, hide every video/audio button. A dropped video or audio file shows a friendly "Video & audio arrive in the next update" state in the wheel centre, not an error.
2. **Signing: no paid Apple Developer account yet.** Builds are ad-hoc signed (`codesign -s -`) with hardened runtime on. Still write `scripts/sign.sh`, `scripts/notarize.sh` (notarytool + stapler) and `scripts/release.sh`, but gate them behind env vars (`DEVELOPER_ID_APP`, `NOTARY_PROFILE`) and exit cleanly with a clear message when they are unset. The DMG (create-dmg, custom background, drag-to-Applications, volume icon) must build fine from an ad-hoc build. The README must explain the first-launch right-click → Open (or System Settings → Privacy & Security → Open Anyway) step.
3. **Defaults to use and record in PLAN.md:** bundle ID `com.kunal.circularity` (one constant, alongside the app name constant), macOS 13 minimum, universal binary, XcodeGen.
4. **Wheel look: "Tangerine Glass ring + Halo centre"** (spec below). Ship it as the default **Ring** layout. Also ship two alternative layouts users can pick in Settings → Looks: **Orbit** (separate floating round glass buttons) and **Halo** (solid graphite ring, monospace text-only labels, neon accent; this is also what Reduce Transparency falls back to).

# WHEEL VISUAL SPEC (default "Ring" layout; sizes in points at the default wheel size and scaled by the size setting)

- **Glass disc:** 436 pt diameter, centred on the cursor. NSVisualEffectView (`.hudWindow` material, `.behindWindow` blending, dark appearance) masked to a circle, tinted black at about 55%. 1 pt inner hairline at white 12%, soft inner top glow (white 7%, 34 pt blur), depth shadow (y 40, blur 90, black 50%).
- **Segments:** 6 annular sectors of 60° with a 3° gap. At rest: inner radius 98, outer 204, fill white 7%, 1 pt stroke white 10%. Segment 0 is centred at 12 o'clock and the order runs clockwise. Hovered: inner 92, outer 216 (it bulges outward), fill = accent (default tangerine `#FF8A00`), label and icon in `#1A1206`, stroke white 35%, tilted slightly toward the cursor. Neighbours dim to 55% opacity. Animate the radii with a spring and make the change ripple slightly from the hovered segment to its neighbours.
- **Slot order for images:** PNG (top), JPG, WebP, More (bottom), Compress, Resize. This puts everyday formats top/right and dialog tools left of More. Smart ordering may reorder only the format slots, never the tools or More.
- **Segment content:** SF Symbol (22 pt, medium) above a 15 pt bold SF Pro Rounded label, placed at the segment's mid-radius.
- **More fan:** 56 pt round glass chips on a 270 pt radius, 21° apart, centred on More's angle. Hovered chip: fill = accent, scaled 1.14. If the fan would leave the visible frame of the screen, flip it upward.
- **Centre orb (taken from Halo):** 180 pt circle, black 78%, 1.5 pt border white 18%. The file's QL thumbnail fills it at 22% opacity. On top, centred, stacked:
  1. A small kicker in caps, 10 pt, tracking 0.08: "CONVERT TO", "OPEN" (for tools), "REST HERE FOR" (More), or "DROP HERE TO".
  2. A large label, 32 pt heavy, in the accent colour: the hovered format or tool ("JPG", "Compress", "Cancel"). This label morphs as the hover changes (crossfade plus a slight vertical slide).
  3. A detail line, 12 pt semibold: a live output-size estimate ("about 2.9 MB") for formats and compress presets, otherwise a short hint ("width × height", "nothing is changed").
  4. The file name and size, 11 pt secondary. For batches, add a count badge on the orb.
  Hovering the centre switches to Cancel: the border turns `#FF7A6E` and the big label turns `#FF8A80`.
- **Cursor:** no floating label near the cursor; the centre label replaces it. Keep a small drag ghost (the system's).
- **Motion:** a 180 ms spring bloom from the cursor (scale 0.6 → 1, alpha 0 → 1), segments popping in with a 25 ms stagger, and a release where the thumbnail is drawn into the chosen segment and then everything fades out. Reduce Motion: a 120 ms crossfade and nothing else. Reduce Transparency: use the Halo layout's solid graphite disc.
- **Accent swatches:** `#FF8A00` (default), `#FF5E3A`, `#FFB020`, `#7C8CFF`, plus a custom colour picker.

Reference mockups (interactive, on a Claude design canvas): A Tangerine Glass, B Orbit, C Halo, and D the chosen mix. Match D for the Ring layout, B for Orbit and C for Halo.

# MENU BAR PANEL SPEC (default layout "Stack+"; replaces the shorter MENU BAR PANEL section in the original brief)

Reference mockups on the same canvas, "Menu bar panel" page: E Stack, F Tabs, G Halo Mini, H icon states, and **I the chosen mix (E's layout + F's preset tiles + G's ⌘K bar)**. Match I for the default. Ship **Tabs** (F) and **Mini** (G) as alternative panel layouts in Settings → Menu bar → Layout. All three layouts share one view model, so switching layout never changes behaviour.

**Container.** A custom NSStatusItem view plus a borderless, non-activating, key-capable NSPanel, not NSPopover. The panel hangs 6 pt below the status item, with its right edge clamped to the screen's visible frame and correct placement next to the notch. Width S/M/L = 340/380/440 pt (default M); height fits the content up to 80% of the screen, after which Recent scrolls. Background: NSVisualEffectView `.popover` material with a dark tint (or light, per colour scheme), 16 pt continuous corners, 1 pt hairline at white 12%, shadow y30 blur70 at 50%. Opens with a spring (scale 0.96→1 from the status item, 220 ms) and closes with a 120 ms fade. It closes on outside click and Esc. The panel's SwiftUI content is created on open and **released on close** (perf budget).

**Sections, top to bottom (each one can be shown, hidden and reordered in Settings):**
1. **Header:** an app glyph tile in the accent colour, "Circularity" in 15 pt heavy, a status line with a coloured dot ("Converting 1 file", "Ready, Shift-drag ready", "Paused, the wheel will not appear", "Watching 2 folders"), and a Pause switch (⌘P). Long-press Pause offers *Pause for 1 hour / until tomorrow / until I resume*.
2. **⌘K command bar** (focused when the panel opens from the keyboard): fuzzy search over recents, plus commands. Typing a format ("webp") or a preset ("< 2mb", "1920w", "no gps") applies it to the current Finder selection or the last-dropped file; "clipboard" converts the clipboard; "pause", "settings" and "watch" do what they say. Results list with ↑↓, ↩ to run, ⌘↩ to run and reveal.
3. **Stats strip** (3 tiles): Today (files converted), Saved this week (bytes, accent colour), Watching (number of folders). Clicking a tile opens the stats sheet: per-day bars for 30 days, a breakdown by format, and the all-time total saved. Stats are stored locally as small daily aggregates and can be reset.
4. **In progress:** one card per job with a thumbnail, "name → target", a progress bar, a meta line (percentage, page x of y, time left), and per-job cancel. Cancel all is in the section header. When idle, the section collapses with a spring.
5. **Presets grid** (3×2, drag files onto a tile to run it; click a tile to run it on the Finder selection). Tiles are user presets plus built-ins (→ JPG, < 2 MB, 1920w, → PDF combine, No GPS, Copy PNG from clipboard). Edit mode supports drag-to-reorder, add, remove, and changing a tile's colour. Hovered or drag-targeted tile: fill = accent.
6. **Drop zone:** a dashed box, "Drop files to convert, or click to choose". When a file is dragged over it, it **morphs into a mini 6-segment wheel** (same segments as the big wheel for that file type) and dropping on a segment converts. Dragging a file onto the **status item itself** opens the panel already in that state.
7. **Recent:** shows the last N (5/10/25, default 5) with "Show all" leading to a full searchable history window. Each row has a thumbnail, the name, before → after sizes, and a percentage change (green when smaller). Hovering a row shows Reveal, Quick Look (Space), Convert again as…, and Undo (move the result to Trash). Rows can be **dragged out as real files**. Right-click adds Open, Copy, Copy path, Open with…, Remove from history.
8. **Footer:** Settings (⌘,), Tutorial, a Pin button (detach), Quit (⌘Q), and a keyboard-hint line.

**Status item icon** (match board H): an original segmented-ring glyph with a centre dot, drawn as a template image. States: idle, file dragged over the icon (filled chip), converting (a progress ring that tracks overall progress), done (one checkmark pulse, back to idle after 3 s), error (red badge until the panel is opened), paused (dimmed ring + pause bars). Styles: monochrome template (default), colour (accent for progress and done), and minimal (dot only). Optional: show the percentage as text next to the icon while converting. Optional: hide the icon entirely, leaving the panel reachable by hotkey, and opening the app again shows it.

**Extras (in v1):**
- **Pinned panel:** the Pin button detaches the panel into a floating mini window that stays on top. It can be resized S/M/L and docked to any screen corner, and its position is remembered per display. Click-through can be turned on so it never steals focus.
- **Desktop widget (WidgetKit extension):** small (today count + saved), medium (the last 3 conversions as tappable thumbnails that reveal the file), large (stats + recents). Data is shared through an App Group container written by the main app. Note: widget extensions must be sandboxed and App Groups need proper signing, so **build the extension but leave it out of ad-hoc builds behind a build flag**. Document in PLAN.md that it ships once a Developer ID exists.
- **Watch folders:** add folders, each with a rule (formats it matches → action or preset → output: in place, a subfolder, or another folder; plus optional "move original to Trash" with confirmation). Use an FSEventStream only while at least one watch folder is enabled; with none, nothing runs, so the idle budget still holds. Built-in suggestion: "Screenshots → JPG". Watching a protected folder (Desktop, Documents, Downloads) triggers the system's one-time folder-access prompt, so explain that in-app *before* adding it. Never watch anything without the user explicitly choosing it.
- **Clipboard convert:** from the panel, the ⌘K bar, or a hotkey (default ⌃⌥V), take the image or PDF on the clipboard, convert it (PNG, JPG, WebP where supported, or a preset), and put the result back on the clipboard. Optionally also save it to a folder. Read the clipboard **only on an explicit user action**, never by polling (newer macOS versions may show a paste-permission prompt; handle refusal gracefully).

**Panel customisation (Settings → Menu bar):** layout (Stack+ / Tabs / Mini), panel width S/M/L, density (comfortable/compact), sections on/off and their order, number of recents, preset grid on/off and its size (3×1, 3×2, 4×2), stats on/off, icon style and its states, percentage next to the icon, open on hover over the icon (off by default), open on drag-over (on), and a keyboard shortcut to open the panel (default ⌃⌥Space).

# APPEARANCE, COLOUR SCHEMES AND SIZE (applies to the wheel, panel and windows)

- **Colour scheme:** System / Light / Dark, set separately for the wheel and the panel (for example a dark wheel with a light panel).
- **Themes** (each sets the accent, tints, glass strength and fonts): Tangerine (default), Glass, Graphite, Midnight, Mono, Neon, plus **Custom**. Custom has an accent picker with 8 swatches + a colour wheel, a secondary tint, glass strength (0–100), panel tint opacity, and a "follow wallpaper" accent that takes the dominant wallpaper colour on demand, not continuously. Themes can be exported and imported as JSON.
- **Per-category tints** for the wheel (images, documents, tools; video/audio reserved), each one editable.
- **Size controls:** wheel size (S/M/L/XL plus a slider from 70% to 140%), ring thickness, segment gap, centre orb size, label size, panel width and density, and a global "UI scale" for the panel and windows.
- **Typography:** SF Pro Rounded (default), SF Pro, SF Mono (Halo default), and a choice of label case (Title / UPPER).
- **Accessibility:** respect Reduce Motion, Reduce Transparency, Increase Contrast and Differentiate Without Colour (add a pattern or outline to hovered segments). Full VoiceOver, keyboard navigation everywhere, and a minimum 4.5:1 text contrast in every theme. Add a unit test that checks theme contrast.

# GENERAL SETTINGS (Settings window, SwiftUI sidebar; every change applies instantly, live preview pane on the right)

- **General:** launch at login (SMAppService, on by default after onboarding asks), show in menu bar, global hotkeys (wheel for the Finder selection ⌃⌥C, open panel ⌃⌥Space, clipboard convert ⌃⌥V; each can be rebound or cleared), language follows the system, and reset all settings.
- **Gesture:** trigger key (Shift/Option/Control), tap vs hold, delay slider, excluded apps list, skip when a full-screen app is active, and a test area.
- **Wheel:** layout (Ring/Orbit/Halo), per-file-type button order with drag-to-reorder, hover-to-expand More with its delay, smart ordering on/off, haptics, sounds (off by default, three sound packs), and animation style + speed.
- **Output:** next to the original or a chosen folder, per-type output folders, a naming template ({name} {format} {date} {size}), collision style, auto-open / reveal / copy to clipboard, metadata stripping, default quality per format, and "replace original (to Trash)" with confirmation.
- **Presets:** the full preset editor (shared with the panel grid and the wheel).
- **Watch folders, Menu bar, Appearance:** as above.
- **Notifications:** one notification per drop, sounds, and respecting Focus.
- **Advanced:** logs, Copy diagnostics, Report a bug, export/import all settings as JSON, the `--perf-report` trigger, and a "show developer HUD" option (FPS and RSS overlay while a drag is in progress).
- **About:** version, detected tools, credits to Circularity for Windows (Atharv Gogia, MIT) and Tangerine (LEAP STUDIO) as inspiration, and licences.

# ORIGINAL BRIEF (apply it within the scope and decisions above)

# PRODUCT
Name: "Circularity" (keep as ONE constant so it can be renamed, e.g. to "Circularity for Mac"). A tiny menu bar file converter that lives at your cursor. While dragging a file from Finder (or any app), the user taps SHIFT mid-drag and a beautiful translucent wheel of format buttons appears around the cursor. They keep dragging onto a segment and release to convert. Everything runs locally; nothing is uploaded; the original file is never modified (always answer the drop with Copy, never Move).

It is inspired by Circularity for Windows (open source, MIT, github.com/AtharvGogia/Circularity-for-Windows, by Atharv Gogia) and Tangerine for Mac (closed source, by LEAP STUDIO), whose idea this builds on. Re-implement the behaviour in ORIGINAL Swift code. Do not copy code, icons, artwork or copy text from either. Credit both as inspiration in the About screen.

# STACK AND DISTRIBUTION
- Native Swift only (AppKit + SwiftUI). No web views, no Electron/Tauri. macOS 13+ minimum. LSUIElement agent app (no Dock icon). Generate the project with XcodeGen (project.yml): app target + Engine library + EngineSmokeTest CLI + unit tests.
- Hardened runtime, NOT sandboxed (needed to write results next to originals). Ad-hoc signing for now (see Decisions); Developer ID signing, notarization (notarytool), stapling scripts written but gated. Package a polished DMG with create-dmg: custom background art, drag-to-Applications layout, volume icon.
- Launch at login via SMAppService. os.Logger for logging. (Sparkle 2: v1.1.)
- Size: strip symbols, no unused frameworks, minimal asset catalog. Universal (arm64 + x86_64) plus a script for an arm64-only DMG.
- (v1.1) Video/audio/WebM/AVIF-encode support comes from a "Media Pack": a slim LGPL FFmpeg (no GPL parts, no x264; VideoToolbox for H.264/HEVC; libmp3lame, libvorbis/opus, libwebp, libaom allowed) downloaded on first use from our own release (checksum-verified, cached in Application Support, short-lived child process, utility QoS), with a build flag to bundle it instead. In v1, WebP/AVIF *encoding* may be unavailable if ImageIO cannot write them on the running macOS; detect at runtime and hide those buttons rather than failing. Include THIRD-PARTY-NOTICES.

# MINIMAL PERMISSIONS (hard requirement; goal is ZERO prompts for the core gesture)
- Detect drags with global NSEvent MOUSE monitors only (they need no permission). Read Shift via NSEvent.modifierFlags while a drag is active. Confirm a real file drag from NSPasteboard(name: .drag) containing file URLs or file promises (NSFilePromiseReceiver, for Photos, Mail, browsers). Verify this works on the running macOS version without Accessibility or Input Monitoring and log the result; if it does not, tell me and add the smallest fallback.
- No event tap at all in v1.
- No Screen Recording, no Full Disk Access, no Automation in v1.
- Files arrive through drops, Open, Services and the menu bar drop zone (user-intent, no TCC prompt). Output setting: "Next to original" or a chosen folder; if writing next to the original is denied, fall back to a Converted folder in Documents without nagging.
- A first-run screen states exactly what the app does NOT access.

# THE GESTURE
1. A global mouse monitor tracks leftMouseDown, leftMouseDragged, leftMouseUp. A drag is confirmed when the left button is held, the pointer moved more than ~4 pt, and the drag pasteboard changed with file URLs/promises.
2. When Shift goes down during a confirmed file drag, open the wheel at the cursor. If Shift was already held when the drag started, stay out of the way so Finder behaviour is untouched. Trigger key is configurable (Shift default; Option/Control alternatives), with hold vs tap and an adjustable delay.
3. The wheel is a borderless, non-activating NSPanel (level above popUpMenu, canJoinAllSpaces + fullScreenAuxiliary, transparent, ignoresCycle) registered for file URL drags. Implement NSDraggingDestination: draggingEntered/Updated drive hover state, performDragOperation enqueues the job, draggingExited dismisses while the drag carries on normally. Always return .copy. Dropping on the centre cancels.
4. Click mode (no drag): same wheel via global hotkey (default ⌃⌥C, registered with the Carbon hotkey API, no permission) for the Finder selection, via Finder Services/Quick Action "Convert with Circularity", via dropping files on the menu bar icon, and via opening files with the app. Hover and click, arrow keys + Return, Esc cancels. Single instance: a second launch hands files to the running copy.
5. Stay out of the way: skip when a full-screen app is active, in a user-editable excluded-apps list, or when paused.

# THE WHEEL
- At most 6 buttons on the ring. If a file has more options the bottom button becomes "More" and resting on it fans the rest out in an arc outside the ring; everyday formats top/right, dialog tools (Resize, Compress, Crop) always left of More; flip the arc upward near the bottom of the screen. Multi-monitor and notch aware.
- Visuals and motion: see WHEEL VISUAL SPEC above.
- Feedback: alignment haptic on segment change, optional sounds (off by default), live output-size estimate on hover (in the centre orb). Remembers recent choices ("smart ordering").
- VoiceOver labels on everything.

# MENU BAR PANEL (must be amazing; the MENU BAR PANEL SPEC above wins where they differ)
Custom NSStatusItem + custom glass NSPanel (not a plain popover), SwiftUI, spring-animated, ~380 pt wide:
- Animated icon: idle glyph, live progress ring during conversions, checkmark pulse on completion, error badge on failure; monochrome and colour styles.
- Header: status, pause toggle, hint of the Shift-drag gesture.
- Live jobs: cards with thumbnail, "photo.heic → JPG 43%", ETA, per-job cancel, Cancel all.
- Drop zone: dragging a file over the menu bar icon opens the panel and morphs the zone into a mini wheel.
- Recent conversions: searchable, thumbnails, before/after size, hover actions (Reveal, Open, Copy, Quick Look on Space, Convert again as…, Undo = move result to Trash), and results can be dragged back out as real files.
- Footer: Settings, Tutorial, Quit (Check for updates arrives with Sparkle in v1.1). Full keyboard navigation.

# CONVERSION ENGINE
Protocol-based backends (designed so the v1.1 FFmpeg backend plugs in), 2 concurrent jobs, progress, cancellation, no half-written output on fail or cancel (write to a temp file, then move atomically), streamed ImageIO (no giant in-memory copies).
- Images → PNG, JPG, TIFF, BMP, GIF, HEIC (ImageIO), WebP/AVIF where ImageIO can encode them, PDF. Read HEIC/HEIF, AVIF, WebP, RAW (where ImageIO allows), SVG (render locally, never fetch external resources, small icons upscale to 1024 px, cap 4096 px). Honour EXIF orientation and transparency.
- Resize (images): width × height, fit or stretch, dialog shows resulting size.
- Compress: images by quality or target file size (highest quality that fits, downscale only if needed); PDF light/balanced/strong, re-compressing only embedded images, verifying every page against the original and keeping the original if anything differs.
- Crop (images): interactive editor, movable/resizable box, locks 1:1, 4:3, 3:2, 16:9, 9:16.
- Documents: PDF → PNG/JPG (one per page, into a folder) and TXT (PDFKit); Markdown → PDF/HTML, HTML → PDF, TXT → PDF (render offscreen without a visible web view; A4 or Letter by region); DOCX/DOC/RTF/ODT → PDF/TXT/DOCX via textutil.
- Combine two or more images/PDFs into one PDF in drop order.
- Custom buttons: "Also add this as a button" in Resize/Compress dialogs creates one-click presets (e.g. "1920×1080", "Under 2 MB"), shown only for matching file types.
- Output naming: `photo.png`, `photo (resized).jpg`, `scan (combined).pdf`, with (1), (2) on collisions; configurable template ({name} {format} {date} {size}). One notification per drop with Open and Reveal actions. Local crash/error log and a "Report a bug" button that copies diagnostics.

# CUSTOMIZATION AND FEATURES (APPEARANCE and GENERAL SETTINGS above win where they differ)
- Looks: wheel layout (Ring / Orbit / Halo), 6+ themes (Tangerine, Glass, Graphite, Midnight, Mono, Neon), light/dark/auto, accent colour picker, wheel size, thickness, segment gap, corner style, blur, opacity, icon style (filled/outline/text-only), font, centre orb style, animation style (Bloom, Pop, Fade, Instant) and speed, haptics, sound packs, menu bar icon styles.
- Behaviour: trigger key and delay, hover-to-expand More, per-app rules, per-file-type button layouts with drag-to-reorder, custom presets, per-type default output folders, auto-open/reveal, copy results to clipboard, optional "replace original (to Trash)" with confirmation, metadata stripping (EXIF/GPS), default quality per format, batch handling.
- Power: global hotkeys, export/import settings as JSON, notifications that respect Focus.
- Settings window (SwiftUI) with a live wheel preview you can hover and click, switchable between image/document; every change applies instantly. First-run welcome, an interactive tutorial with a practice picture, About with detected tools and "Copy diagnostics". SF Pro Rounded headings, tangerine brand, an original app icon generated by script, README with a GIF-recording checklist.

# PERFORMANCE BUDGET (hard requirement, measure and report)
- Idle: no timers, no polling, no display link, no network, App Nap enabled; target under 25 MB resident and ~0% CPU.
- Active gesture: timers/display links exist only while a drag is in progress and are torn down at drag end. The wheel panel is built once and kept hidden and cheap, Core Animation only, no continuous redraw.
- Settings, Tutorial, Crop windows and the menu bar panel content are created lazily and fully released on close. Small thumbnails with a tightly limited NSCache.
- Add a `--perf-report` mode and an Instruments checklist; report idle RSS, RSS during a large (e.g. 100 MP) image convert and a 200-page PDF compress, DMG size, and launch time, and fix whatever misses budget.

# QUALITY BAR
- EngineSmokeTest CLI: generate sample images and PDFs, run every conversion, resize, crop and compress through the real queue; assert outputs decode, have correct dimensions and respect target sizes; test naming, batches, cancellation, unsupported formats.
- `--render-previews` renders the wheel (all three layouts), settings and dialogs to PNG. `--drag-test` posts synthetic events to verify drop-on-segment and drag-off-dismiss.
- Unit tests for the gesture state machine, ring/More-arc layout, output naming.

# PROCESS
1. Write PLAN.md first (architecture, modules, milestones, assumptions, and the v1.1 backlog). Do not wait for approval.
2. Milestones, each built and committed: (a) skeleton + menu bar item; (b) gesture detection + empty wheel panel, verified permission-free; (c) wheel UI and animations; (d) image engine; (f) PDF and documents; (g) resize/compress/crop dialogs; (h) menu bar panel (Stack+ layout, icon states, drop-on-icon, ⌘K bar); (h2) stats, watch folders, clipboard convert, pinned panel, widget extension (flagged off for ad-hoc builds), then the Tabs and Mini layouts; (i) settings, appearance/themes/size controls, onboarding, tutorial; (j) ad-hoc signing, gated notarization scripts, DMG; (k) tests, perf report, polish.
3. After each milestone, state what works, what you verified and what remains. Be honest about anything you could not test (e.g. a real drag with permissions state), and give me exact manual steps for it.
4. Finish with README, MIT LICENSE, and a release checklist (ad-hoc DMG now; later: Developer ID, notarize, staple, appcast, Homebrew cask).
