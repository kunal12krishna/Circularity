# Manual tests

Automated checks cover the logic: `xcodebuild … test` (60 unit tests),
`EngineSmokeTest`, `Circularity --drag-test` (the real wheel panel driven by a
simulated drag) and `Circularity --render-previews <dir>` (PNG renders of every
layout and state). What only a person can check — a real drag from another app,
what macOS shows on screen, and permission prompts — is listed here.

Build and launch first:

```sh
cd ~/Desktop/circularity
./scripts/bootstrap.sh
xcodebuild -project Circularity.xcodeproj -scheme Circularity -configuration Release -derivedDataPath build/DerivedData build
APP="$PWD/build/DerivedData/Build/Products/Release/Circularity.app"
open "$APP"
```

Optional live log in a second Terminal window (use the full path: zsh has its own `log`):

```sh
/usr/bin/log stream --level info --predicate 'subsystem == "com.kunal.circularity"'
```

## Milestones (b) + (c): gesture and wheel

| # | Do this | Expect |
|---|---|---|
| 1 | Drag any image from Finder. Partway through the drag, tap **Shift** (press and release). Keep the mouse button down. | The wheel blooms at the pointer. No permission dialog appears, ever. |
| 2 | Still dragging, move over the segments. | The hovered segment turns orange and bulges, the others dim, the centre says e.g. "CONVERT TO / JPG". You feel a light tick on each change (Force Touch trackpads). |
| 3 | Rest on **More** (bottom). | Six (or five) round chips fan out below the ring. Near the bottom of the screen they appear above it instead. |
| 4 | Release over **JPG**. | The thumbnail flies into the segment and the wheel fades. The menu bar menu now says "Last choice: Convert to JPG — <name>". **No file is converted yet** (milestone d). The original is untouched. |
| 5 | Start a new drag, tap Shift, release over the **centre**. | Nothing happens; the file slides back. The menu says "Last choice: Cancel". |
| 6 | Start a drag, tap Shift, then drag far away from the wheel. | The wheel disappears and the drag carries on normally (you can still drop into a Finder folder). Tapping Shift again in the same drag brings the wheel back. |
| 7 | Hold **Shift first**, then start dragging a file. | No wheel (Finder's own Shift-drag is left alone). Release Shift and tap it again mid-drag: the wheel appears. |
| 8 | Start a drag and give the pointer a **quick left-right shake** (three fast swings). | The wheel opens without the keyboard. |
| 9 | Do 20 ordinary drags: between Finder windows, onto the Dock, into Mail, slowly over a folder. | The wheel never opens by itself. If it does, note how you were moving and turn sensitivity down (Settings arrive in (i); for now **menu → Shake to Open** turns it off). |
| 10 | Drag a photo from **Photos** (file promise), tap Shift, drop on PNG. | Same as 4; the log says "Received 1 promised file(s)". |
| 11 | Drag a **PDF**, a **.md** file, and a **video**. | PDF: PNG, JPG, TXT, More, Compress, Resize. Markdown: PDF, HTML, TXT (other segments empty). Video: empty ring, centre says "Video & audio arrive in the next update". |
| 12 | Drag two images at once. | Centre shows "2 images" and a count badge; PDF in the fan becomes "Combine into one PDF". |
| 13 | Menu → **Wheel Layout → Orbit**, repeat 1–4. Then **Halo**. | Orbit: separate round buttons, light orb, a dark pill near the pointer naming the action. Halo: solid dark disc, monospace labels with captions, neon green. |
| 14 | Menu → **Pause**, drag a file, tap Shift. | No wheel. The menu shows "Last file drag: skipped (paused)". Un-pause afterwards. |
| 15 | Put an app in full screen (e.g. Safari, ⌃⌘F), drag a file from it, tap Shift. | No wheel (full-screen apps are left alone). |
| 16 | Menu → **Trigger Key → Option**, then drag and tap Option. | The wheel opens on Option instead of Shift. |
| 17 | System Settings → Accessibility → Display: turn on **Reduce motion**, open the wheel. | A plain 120 ms fade, no bloom or springs. Turn on **Reduce transparency**: the Ring becomes the solid Halo disc (in your accent colour). |
| 18 | System Settings → Privacy & Security → **Accessibility** and **Input Monitoring**. | Circularity is not listed in either. |

### ⌃⌥C for selected Finder files (no drag)

| # | Do this | Expect |
|---|---|---|
| 19 | Menu → **Use ⌃⌥C for Finder Selection…** | A dialog says "⌃⌥C is ready" and offers **Relaunch Finder** (Finder only reads new shortcuts when it starts; its windows reopen by themselves). Afterwards the menu item shows a tick. If macOS refused the change, Keyboard Shortcuts settings open instead: go to **Services → Files and Folders → Convert with Circularity** and set ⌃⌥C yourself. |
| 20 | Select an image in Finder and press **⌃⌥C**. | The wheel opens at the pointer in click mode, with no prompt. Hover and click a segment, or use the arrow keys and Return; Esc or a click outside cancels. |
| 21 | Right-click an image in Finder → **Quick Actions** (or **Services**) → **Convert with Circularity**. | Same click-mode wheel. If the entry is missing, run `/System/Library/CoreServices/pbs -update` once and try again. |
| 22 | `open -a "$APP" ~/Desktop/<file>` | Same click-mode wheel. |

**Please report back:** which of 1, 8, 10, 19 and 20 worked, and the line
`Gesture self-check: …` from the log (or the menu's "Last file drag" line).
These are the parts no automated test on this Mac can exercise.

## Milestones (d) + (f): conversion

Make a test folder with a few files first (copies — though originals are never changed):
an iPhone photo (HEIC), a PNG screenshot, a multi-page PDF, a `.md`, a `.docx` and a `.txt`.

| # | Do this | Expect |
|---|---|---|
| 23 | Shift-drag the HEIC photo and hover each format. | The centre's third line shows a live estimate, e.g. "about 2.9 MB", a moment after the wheel appears. |
| 24 | Drop it on **JPG**. | Within a second or two `IMG_xxxx.jpg` appears next to the original, upright. Menu: "Last result: IMG_xxxx.jpg · 2.1 MB (−34%)". **Reveal Last Result in Finder** selects it. |
| 25 | Do 24 again. | The second file is `IMG_xxxx (1).jpg`; nothing is overwritten. |
| 26 | Drag the PNG, More → **PDF**; then **Compress**. | A one-page PDF; then `name (compressed).jpg` (or `.heic` if the PNG has transparency) — or "Kept the original: it is already as small as it gets". |
| 27 | Drag the PDF → **PNG**. | A folder `name (pages)` with `name page 01.png`, `page 02` … |
| 28 | Drag the PDF → **TXT**; then → **Compress**. | The text file; then either `name (compressed).pdf` or "Kept the original: the PDF is already compact" (text-only PDFs rarely shrink). |
| 29 | Select two images and a PDF, drag them together, More → **PDF** (Combine). | `firstname (combined).pdf` with every page, in the order you dragged. |
| 30 | Drag the `.md` → **PDF**, **HTML** and **TXT**; the `.docx` → **PDF** and **TXT**; the `.txt` → **PDF**. | Each result opens correctly. PDFs are A4 (Letter in the US/Canada) with margins and real, selectable text. No network activity. |
| 31 | Drag a file from a folder you can't write to (e.g. a mounted disk image or a read-only share). | The result goes to **Documents › Converted**; the menu says so. |
| 32 | The first time you convert something on the **Desktop**, in **Documents** or in **Downloads**. | macOS asks once whether Circularity may access that folder. Allow it. If you don't, results go to Documents › Converted (or ~/Converted) and the menu says so. A new build may ask again (ad-hoc signing). |

## Milestone (g): dialogs and saved buttons

| # | Do this | Expect |
|---|---|---|
| 33 | Drag a photo, tap Shift, drop on **SQZ / Compress**. | A dark Halo-style dialog opens. Move the quality slider: "about 1.2 MB (−58%)" updates. **Compress** writes `name (compressed).jpg` (or .heic). |
| 34 | Compress again, switch to **TARGET SIZE**, pick **500 KB**. | The result is at most 500 KB. |
| 35 | Drop a photo on **SIZE / Resize**, click **1920w**. | Height follows the aspect; the line shows "1920 × 1440 px · about …". Click the link icon to unlock and type both numbers to stretch. **Resize** writes `name (resized).<same format>`. |
| 36 | More → **Crop**. Drag the box, its corners and edges; try **1:1** and **16:9**. | The box stays inside the image and keeps the ratio; the subtitle shows the pixel size. **Crop** writes `name (cropped).…`. |
| 37 | In Compress or Resize, turn on **Also add this as a button on the wheel** and run it. Then open the wheel on another image and rest on More. | Your button (e.g. "Q70", "1920w", "<2 MB") is the first chip; dropping on it runs it with no dialog. PDF buttons only appear for PDFs. Remove buttons from the menu → **Saved Wheel Buttons**. |
| 38 | Drop a **PDF** on Compress, Resize (Scale / Paper) and Crop. | PDF versions of each dialog; results are `name (compressed).pdf` (or "Kept the original …"), `name (resized).pdf`, `name (cropped).pdf`. |
| 39 | Menu → **⌃⌥C for Finder Selection** (ticked) → click it. | It turns off and offers to relaunch Finder. Click it again to turn it back on. |
| 40 | Menu → **Halo Accent** → Cyan / Pink / Tangerine / Neon Lime. | The Halo wheel and the dialogs use that colour. |

## Milestones (h) + (h2): menu bar panel and extras

| # | Do this | Expect |
|---|---|---|
| 41 | Click the menu bar icon. | The panel springs open under it (board I, in your accent). Click elsewhere or press Esc: it fades away. |
| 42 | Right-click the icon. | The settings menu (layouts, accents, icon style, panel width, recents, grid, ⌃⌥C, Pause…). |
| 43 | Convert something, watch the icon. | A progress ring while converting; a short pulse and a tick when done; back to the ring glyph after 3 s. A failed job shows a red badge until you open the panel. |
| 44 | Drag a file over the icon and hold. | The panel opens with the drop zone ready. Drag down onto the drop zone: it turns into a mini wheel. Drop on a segment: that conversion runs. Drop on the icon itself: the full wheel opens. |
| 45 | Drop a file on a preset tile (→ JPG, < 2 MB, 1920w, No GPS). | It runs on that file. Click a tile: it runs on the last files you used, or asks you to choose. |
| 46 | Press ⌃⌥Space, type `webp`, `< 1mb`, `1280w` or `no gps`, press ↩. | It runs on the last files. Typing part of a recent file's name lists it; ↩ opens it, ⌘↩ reveals it. |
| 47 | Copy an image (e.g. ⌘⇧⌃4 screenshot to clipboard), press ⌃⌥V. | The clipboard now holds a PNG; paste it anywhere. The panel shows a note. |
| 48 | Recent: hover a row. | Reveal, Quick Look, Convert again, Undo (moves the result to the Trash). Drag a row into Finder or Mail: the real file goes. Right-click for more. |
| 49 | Click **Show all**, **TODAY** and **WATCHING**. | History (searchable), Stats (30-day chart, by format, reset), Watch Folders. |
| 50 | Watch Folders → **Screenshots → JPG**, take a screenshot. | A JPG of it appears next to it a couple of seconds later. Desktop is protected: macOS asks once (the app explains first). |
| 51 | Click **Edit** in Presets. | Drag tiles to reorder, ✕ to remove, the palette to recolour; Restore brings the built-ins back. |
| 52 | Click the **pin** in the footer. | The panel becomes a floating window in a corner. Drag it near another corner: it snaps there and remembers it for that display. Unpin from its footer. Right-click the icon → Pinned Panel Size / Ignores Clicks. |
| 53 | Right-click the icon → **Panel Layout → Tabs**, then **Mini**. | Tabs: light, Now / Recent / Presets (⌘1 ⌘2 ⌘3). Mini: dark Halo panel with a big Halo drop wheel and a recent strip. Same behaviour in all three. |
| 54 | Drag two photos, tap Shift. | "Combine" (PDF) is on the ring. Rest on **More**: the fan opens. |
