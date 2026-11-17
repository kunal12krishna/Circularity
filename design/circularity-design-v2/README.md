# Circularity design references

These are the SOURCE files of the mockups from the design canvas (a custom HTML template format,
not standalone web pages; they won't render if opened directly in a browser).
Read them as exact specs: every colour, size, radius, blur, shadow, font, segment angle and
hover behaviour is in the inline styles and in the JS `renderVals()` geometry
(`pt()` / `arc()` give the ring maths: angle 0 = 12 o'clock, clockwise, sizes in points).

DEFAULTS TO BUILD:
- wheel-D-chosen.html   → default wheel ("Ring" layout): Tangerine Glass ring + Halo-style centre label
- panel-I-chosen.html   → default menu bar panel ("Stack+" layout)
- icons-H-states.html   → status item icon and all its states

ALTERNATIVE LAYOUTS (Settings → Looks / Menu bar → Layout):
- wheel-B-orbit.html, wheel-C-halo.html (also the Reduce Transparency fallback)
- panel-F-tabs.html, panel-G-mini.html
- wheel-A-tangerine-glass.html: earlier variant of D (cursor-label instead of centre label), reference only

Ignore the fake desktop/wallpaper shapes and the fake macOS menu bar strip: they are backdrop only.
Ignore `{{…}}`, <sc-for>, <sc-if>, <x-dc>: template syntax of the canvas tool.
Sample numbers (file names, sizes, "18 files") are placeholder data.
Screenshots (*.png), if present, show how each board renders.

SCREENSHOTS (rendered at 2x):
- D-wheel-chosen_*.png      default wheel: hovering JPG, More fan open, Cancel, Compress
- I-panel-chosen*.png       default menu bar panel: normal, drop zone turned mini wheel, paused
- H-icon-states.png         status item icon states
- alt-*.png                 alternative layouts (A, B, C wheels; E, F, G panels)
Fonts in the PNGs fall back to Inter; the real app uses SF Pro Rounded.
