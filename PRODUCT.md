# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

The website and Wheel Studio are web. The app itself is a native macOS app (AppKit + SwiftUI, macOS 13+), and its UI is in scope too: design work there follows macOS conventions and the specs in `BRIEF.md` and `PLAN.md`, not web patterns.

## Users

Any Mac user: anyone who has ever opened Preview, or uploaded a file to a website, just to change its format. They are in the middle of something else (sending a photo, filling in a portal, tidying downloads) and want the converted file without leaving that task. Creators, students, office workers and power users are all inside this audience; none of them is the default.

## Product Purpose

Circularity converts files on a Mac without opening anything. Start dragging a file, tap Shift, and a wheel of formats appears around the pointer; let go on one and the new file lands next to the original. Success is a conversion that costs one gesture and no thought, with nothing uploaded and nothing to set up.

## Positioning

The gesture leads: conversion happens mid-drag, at the pointer, wherever the file is (Finder, the desktop, Mail, a browser download, Photos). The core gesture needs no permissions at all: no Accessibility, no Input Monitoring, no Screen Recording. Everything runs on-device with Apple's own frameworks.

## Operating Context

- A menu bar app with no Dock icon. Other ways in: shaking the pointer mid-drag, ⌃⌥C on the Finder selection, ⌃⌥V for the clipboard, dropping on the menu bar icon, the menu bar panel with presets and ⌘K commands, and watch folders.
- The wheel: six buttons around a centre that names the action and the expected size, a More fan for the rest, and three layouts (Halo, Ring, Orbit). Results go next to the original or to a chosen folder.
- Website: one static page (`website/index.html`) plus the Wheel Studio (`website/studio.html`), built by `scripts/build-website.sh` and deployed to Cloudflare Pages (circularity.pages.dev). The page includes a working in-browser demo of the gesture.
- Themes move between the Studio and the app as JSON (Settings → Appearance → Paste theme) or as a Studio share link.

## Capabilities and Constraints

- Images: PNG, JPG, HEIC, AVIF, TIFF, GIF, BMP (WebP where macOS can write it); compress (quality or target size), resize, crop, cut out (macOS 14+), combine into one PDF. PDFs: pages to images, text out, compress, resize, crop, combine. Documents: Markdown, HTML, RTF, Word and plain text to PDF and to each other.
- Video and audio with AVFoundation only (no FFmpeg): reads what macOS plays; writes MP4, MOV, M4V, GIF, M4A, WAV, AIFF, FLAC. Never claim WebM, MKV, MP3 or OGG output.
- Native Swift only, no web views in the app. Not sandboxed (it writes next to originals), hardened runtime, ad-hoc signed until a Developer ID release, so the first launch needs Open Anyway / right-click Open.
- Performance budget is a requirement: idle with no timers or polling, under 25 MB resident and ~0% CPU; the wheel is Core Animation only and everything heavy is created lazily.
- The Wheel Studio may only offer looks the app really draws (38 appearance settings shared with Settings → Appearance). A Studio wheel must paste into the app intact; `Circularity --check-themes Tests/Fixtures/studio-themes.json` verifies it.
- The six wheel buttons never move while the wheel is open; motion (breathing, the orbiting ring, the twirl, sparks) is decorative and off with Reduce Motion.
- Three wheels, one key each (⇧ Convert, ⌘ Tools, ⌃ Actions by default), with a key guide above the wheel. Tools: Make it fit (email/WhatsApp/Discord limits), Text from pictures and scans (on-device Vision), searchable PDF, PDF password and pages, trim, speed, compress. Actions: AirDrop, Copy, Zip, Copy path, Stash, Mail, Terminal, Move/Copy to. A result card with Undo, closed by Esc.
- Current version: 0.4.0. Free; MIT licence.

## Brand Commitments

- Name: Circularity (kept as one constant in code so it can be renamed).
- Colourway: Riso, chosen to replace a lime-on-black look that read as a copy of other AI sites. Warm paper, ink, fluorescent pink and blue; the site follows the Mac's appearance (Riso paper in Light Mode, Riso Ink in Dark Mode), and Riso is the app's default theme. Neon (lime) stays only as an optional theme and style. Lime-on-black, purple gradients and blue-violet are not to return as the main look.
- Halo is the preferred wheel layout.
- The app icon is Tangerine orange.
- Credits that must stay: inspired by Circularity for Windows by Atharv Gogia (MIT) and Tangerine for Mac by LEAP STUDIO; no code, icons, artwork or copy from either.
- Voice: plain, friendly and concrete ("Nothing opens, nothing is uploaded."), with small jokes allowed; no hype words.

## Evidence on Hand

- Real product pictures rendered from the app: `website/assets/` (made with `--render-previews`).
- The working in-browser demo on the home page, and the Wheel Studio.
- Measured facts in `docs/PERF-REPORT.md`, the test suites (`xcodebuild test`, `EngineSmokeTest`, `--drag-test`, `--check-themes`) and `README.md`.
- Not on hand, so never invent: testimonials, reviews, user or download counts, press, customer logos, ratings or awards.

## Product Principles

1. The gesture is the product: never make someone leave what they're doing to convert a file.
2. Nothing leaves the Mac, and the core gesture asks for no permissions.
3. What you see is what you get: the website demo is real, and a Studio wheel looks the same in the app.
4. Light is a feature: the performance budget beats extra features.
5. Aiming comes first: targets stay put, and motion never costs accuracy.

## Accessibility & Inclusion

- VoiceOver labels on every wheel button and control; the wheel works with the keyboard (arrows, Return, Esc).
- Respects Reduce Motion (no springs, no decorative motion), Reduce Transparency (Ring falls back to a solid disc) and Differentiate Without Colour (the hovered button gets a dashed outline).
- Text keeps at least 4.5:1 contrast in every theme and swatch (unit-tested); pink is used for fills with ink text, never as small text on paper.
