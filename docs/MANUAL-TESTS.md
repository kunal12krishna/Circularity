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
| 19 | Menu → **Use ⌃⌥C for Finder Selection…** | The item becomes "⌃⌥C Opens the Wheel for Finder Selection" with a tick. If macOS refused the change, Keyboard Shortcuts settings open instead: go to **Services → Files and Folders → Convert with Circularity** and set ⌃⌥C yourself. |
| 20 | Select an image in Finder and press **⌃⌥C**. | The wheel opens at the pointer in click mode, with no prompt. Hover and click a segment, or use the arrow keys and Return; Esc or a click outside cancels. |
| 21 | Right-click an image in Finder → **Quick Actions** (or **Services**) → **Convert with Circularity**. | Same click-mode wheel. If the entry is missing, run `/System/Library/CoreServices/pbs -update` once and try again. |
| 22 | `open -a "$APP" ~/Desktop/<file>` | Same click-mode wheel. |

**Please report back:** which of 1, 8, 10, 19 and 20 worked, and the line
`Gesture self-check: …` from the log (or the menu's "Last file drag" line).
These are the parts no automated test on this Mac can exercise.
