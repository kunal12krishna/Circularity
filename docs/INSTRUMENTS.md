# Profiling with Instruments

`--perf-report` gives the numbers (docs/PERF-REPORT.md). Use Instruments when a
number moves and you need to know why. Profile the **Release** build
(`scripts/build.sh` → `dist/Circularity.app`); Debug is several times slower
and allocates differently.

## Memory at rest

1. `open -a Instruments`, template **Allocations**, target `dist/Circularity.app`.
2. Wait 10 s, mark a generation, use the wheel once, wait, mark again; repeat with the panel and Settings.
3. A generation that keeps growing on repeated use is a leak; one that stays is a cache (expected for SwiftUI and AppKit after first use).
4. Quick alternative without Instruments: `footprint -p Circularity` (categories), or
   `CIRCULARITY_PERF_HOLD=1 dist/Circularity.app/Contents/MacOS/Circularity --perf-report`, which keeps each wheel up for 6 s and prints its pid for `footprint`.

What to expect: ~12 MB idle after launch; "Malloc Small" growing by tens of MB when the wheel opens means an encoder got loaded (see the size-hint fix in PERF-REPORT.md).

## Idle CPU and wake-ups

1. Template **Time Profiler** plus **Energy Log** (or Activity Monitor → Energy, "Idle Wake Ups").
2. With no watch folders on, the app should show no samples and no timer wake-ups at rest. A watch folder adds an FSEvents stream, which only wakes on file changes.

## The wheel's animation

1. Template **Core Animation** (or **Animation Hitches**), record while dragging a file and tapping Shift.
2. Frames should be steady at the display rate while you move; nothing should be drawn while the pointer is still (the wheel has no redraw loop).

## Large files

1. Template **Allocations**, record `build/DerivedData/Build/Products/Release/EngineSmokeTest --large` (or convert a big file from the app).
2. Peak should be about one decoded copy of the image (100 MP ≈ 0.4 GB) plus the encoder. A second full-size copy usually means an extra `CGContext` draw or a full-size thumbnail decode.

## Logs

`/usr/bin/log stream --predicate 'subsystem == "com.kunal.circularity"'` shows gesture, wheel, job and timing lines live (categories: app, gesture, wheel, menubar, platform, perf).
