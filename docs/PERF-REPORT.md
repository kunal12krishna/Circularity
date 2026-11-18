# Performance report

Measured with `Circularity --perf-report` on 18 Nov 2026 at 6:58 pm, macOS Version 27.0 (Build 26A428), 8 cores, 8 GB, Release build.

| Measure | Result | Note |
|---|---|---|
| Launch to ready | 743 ms | process start → menu bar icon and gesture ready |
| Idle memory after launch | 12.5 MB | within the 25 MB budget |
| Idle CPU (10 s sample) | 0.02 % | ≈ 0 %, as budgeted |
| Wheel (Halo): show | 61 ms, 27.8 MB while shown, 26.3 MB after hiding | first show includes building the layer tree |
| Wheel (Ring): show | 77 ms, 24.1 MB while shown, 23.1 MB after hiding |  |
| Wheel (Orbit): show | 35 ms, 27.9 MB while shown, 27.4 MB after hiding |  |
| Menu bar panel | opens in 327 ms; 27.4 MB before, 38.8 MB open, 38.0 MB after closing | SwiftUI stays loaded once used |
| Panel after 5 more open/close rounds | 38.0 MB | no growth means no leak |
| Settings window | 80.2 MB open (Appearance page), 66.1 MB after closing | SwiftUI/AppKit caches for a long page of controls stay loaded |
| Settings after 3 more open/close rounds | 66.9 MB | no growth means no leak |
| 100 MP PNG → JPG | 0.9 s, peak 830.0 MB (763.3 MB above idle) |  |
| 200-page PDF compress (balanced) | 0.3 s, peak 830.0 MB so far | Kept the original: the PDF is already compact. |
| Idle again after everything | 71.2 MB |  |
| App bundle | 6.2 MB (x86_64 arm64) |  |
| DMG Circularity-0.1.0.dmg | 3.5 MB |  |

Regenerate the table with `scripts/build.sh && dist/Circularity.app/Contents/MacOS/Circularity --perf-report docs/PERF-REPORT.md` (it rewrites this file; keep the notes below).

## Against the budget (PLAN.md §5)

| Budget | Result |
|---|---|
| Idle < 25 MB, ≈ 0 % CPU | **Met at launch:** 12.5 MB and 0.02 % CPU. No timers, polling or file watching run at rest. |
| Gesture-time objects only during a drag | Met: the 60 Hz sampler exists only between mouse down and up; the wheel's layer tree is built once and re-configured. |
| No continuous redraw | Met: Core Animation only animates during hover/show/hide. |
| Lazy windows, released on close | Met: panel and Settings return to the same footprint after repeated open/close (no growth = no leak). |
| Large jobs | 100 MP PNG → JPG peaks at 0.83 GB (the image itself is 0.4 GB decoded). The report's 200-page PDF turned out already compact (kept in 0.3 s); `EngineSmokeTest --large` compresses a compressible 200-page PDF in 6.2 s. |
| Small binary and DMG | 6.2 MB universal app, 3.5 MB DMG (2.1 MB for the arm64-only DMG). |

## Missed, and why

- **After the wheel has been used once: ~23–27 MB** (budget 25). AppKit's window server connection, Core Animation and the symbol images stay loaded after the first wheel. Ring sits under the budget; Halo and Orbit are 1–2.5 MB over.
- **After the panel or Settings has been used: ~38 MB / ~66 MB.** SwiftUI and the AppKit controls it uses load once and are kept by the system frameworks; closing the window frees our objects (repeated open/close does not grow), but not the framework caches. Ways to get under the budget later: an AppKit-drawn panel (no SwiftUI), or running Settings in a separate helper process. Neither is worth it for v1; the numbers are reported instead.

## Fixed while measuring

- **Wheel size hints cost ~35 MB** that stayed for the life of the app: the wheel encoded a sample into every format, and loading the HEIC and AVIF encoders (AVIF alone ~21 MB) kept their buffers. Now only JPEG and PNG are encoded; HEIC, AVIF and WebP are derived from the JPEG size with ratios measured on photos (HEIC ≈ 0.6×, AVIF ≈ 0.45×, WebP ≈ 0.75×), TIFF and BMP are computed, and GIF is 2× JPEG capped at the PNG size. The wheel now shows at ~25 MB instead of ~65 MB. The Compress and Resize dialogs still encode for real.
- **100 MP image peaked at 1.2 GB.** Full-size decodes went through ImageIO's thumbnail API, which made extra copies. Full-size, upright images now decode directly: 0.83 GB peak in the app (0.40 GB in an isolated test), and ~20 % faster.
