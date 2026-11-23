import AppKit
import CircularityEngine
import SwiftUI
import UniformTypeIdentifiers

/// `--render-previews <dir>` (PLAN.md §3.9): renders UI to PNG offscreen.
/// Renders the status glyph on board H's bars and every wheel layout in the
/// board states; (h) and (i) add the panel and windows.
enum RenderPreviews {
    static func run(into directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try renderWheels(into: directory)
            try renderDialogs(into: directory)
            try renderPanels(into: directory)
            try renderIcons(into: directory)
            try renderSettings(into: directory)
            // The before/after close-up for a photo at JPG quality 40 (artefacts visible).
            let photo = directory.appendingPathComponent("loupe-source.png")
            if let picture = samplePicture(size: 1200, scale: 1),
               let data = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) {
                try data.write(to: photo)
                if let loupe = BeforeAfter.image(photo, format: .jpg, quality: 0.4),
                   let png = NSBitmapImageRep(cgImage: loupe).representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("loupe-jpg40.png"))
                }
                try? FileManager.default.removeItem(at: photo)
            }
            let variants: [(name: String, bar: NSColor, glyph: NSColor)] = [
                ("light-mono", NSColor(hex: 0xE4E0DA), NSColor(hex: 0x1D1B18)),
                ("dark-mono", NSColor(hex: 0x26272C), NSColor(hex: 0xF2F2F2)),
            ]
            for variant in variants {
                for size in [16, 32] as [CGFloat] {
                    let url = directory.appendingPathComponent("status-idle-\(variant.name)-\(Int(size))pt@2x.png")
                    let data = try png(size: CGSize(width: size * 2, height: size * 2), scale: 2, background: variant.bar) {
                        let glyph = StatusGlyph.image(pointSize: size, color: variant.glyph, template: false)
                        glyph.draw(in: CGRect(x: size / 2, y: size / 2, width: size, height: size))
                    }
                    try data.write(to: url)
                    print(url.path)
                }
            }
            return true
        } catch {
            FileHandle.standardError.write(Data("render-previews failed: \(error)\n".utf8))
            return false
        }
    }

    private struct RenderError: Error {}

    /// The three panel layouts with sample history, stats and a running job.
    private static func renderPanels(into directory: URL) throws {
        let suite = "\(AppIdentity.bundleID).previews"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, suiteName: suite)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("circularity-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryStore(file: "preview-history-\(UUID().uuidString).json")
        let stats = StatsStore(file: "preview-stats-\(UUID().uuidString).json")
        let names = [("beach.png", "HEIC → PNG", 3_200_000, 9_800_000), ("portfolio (compressed).pdf", "Compressed", 18_400_000, 4_100_000),
                     ("hero (resized).jpg", "Resized", 2_400_000, 640_000)]
        for (i, (name, label, before, after)) in names.enumerated() {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix(".pdf") { try Data("%PDF-1.4".utf8).write(to: url) } else if let image = samplePicture(size: 120, scale: 1),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try data.write(to: url) }
            history.add(HistoryItem(id: UUID().uuidString, date: Date().addingTimeInterval(-Double([3600, 720, 120][i])),
                                    inputs: [url.path], outputs: [url.path], bytesIn: Int64(before), bytesOut: Int64(after),
                                    label: label, format: url.pathExtension.uppercased()))
        }
        stats.record(files: 18, bytesIn: 160_000_000, bytesOut: 18_000_000, format: "JPG")
        let jobs = JobCenter(settings: settings, history: history, stats: stats)
        let watch = WatchFolderService(settings: settings, jobs: jobs)
        let model = PanelModel(jobs: jobs, watch: watch, settings: settings)
        defer {
            history.clear(); stats.reset()
            try? FileManager.default.removeItem(at: AppSupport.folder.appendingPathComponent("preview-history.json"))
        }
        for (layout, name, busy) in [("stackPlus", "panel-stackplus", false), ("stackPlus", "panel-stackplus-busy", true),
                                     ("tabs", "panel-tabs", true), ("mini", "panel-mini", true)] {
            settings.set(layout, for: SettingsKeys.panelLayout)
            settings.set(layout == "tabs" ? "ring" : "halo", for: SettingsKeys.wheelLayout)
            if busy, jobs.active.isEmpty {
                jobs.injectPreviewJob(ActiveJob(id: UUID(), title: "Lease scan.pdf → Compress · balanced", firstInput: nil, isPDF: true,
                                                started: Date().addingTimeInterval(-20), fraction: 0.71, detail: "Page 31 of 44"))
            }
            let width: CGFloat = layout == "mini" ? 340 : 380
            try snapshot(PanelRoot(model: model, width: width), background: layout == "tabs" ? 0xDCD6CC : 0x1E2E36,
                         to: directory.appendingPathComponent("\(name)@2x.png"))
        }
        // Every layout in every colour setting, with the default accent (readability check).
        settings.set(ThemeCatalog.defaultAccentHex, for: SettingsKeys.accentHex)
        for (layout, scheme) in [("tabs", "auto"), ("tabs", "dark"), ("stackPlus", "light"), ("mini", "light"), ("stackPlus", "auto")] {
            settings.set(layout, for: SettingsKeys.panelLayout)
            settings.set(scheme, for: SettingsKeys.panelScheme)
            let light = model.isLight
            try snapshot(PanelRoot(model: model, width: layout == "mini" ? 340 : 380),
                         background: light ? 0xE9E7E3 : 0x1E2128, // roughly the frosted window behind it
                         to: directory.appendingPathComponent("panel-\(layout)-\(scheme)-neon@2x.png"))
        }
        settings.remove(SettingsKeys.panelScheme.name)
        settings.remove(SettingsKeys.accentHex.name)
        try snapshot(StatsWindowView(model: model).frame(width: 540, height: 560), background: 0x0D0F14,
                     to: directory.appendingPathComponent("window-stats@2x.png"))
    }

    /// Every Settings page, the whole window, the welcome steps and the tutorial.
    private static func renderSettings(into directory: URL) throws {
        let suite = "\(AppIdentity.bundleID).previews-settings"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, suiteName: suite)
        let jobs = JobCenter(settings: settings, history: HistoryStore(file: "preview-h-\(UUID().uuidString).json"),
                             stats: StatsStore(file: "preview-s-\(UUID().uuidString).json"))
        let watch = WatchFolderService(settings: settings, jobs: jobs)
        let host = PreviewSettingsHost(watch: watch, jobs: jobs)
        let model = SettingsModel(store: settings)
        model.host = host
        let preview = WheelPreviewRenderer()
        for page in SettingsPage.allCases {
            model.page = page
            try snapshot(SettingsPageView(model: model, preview: preview).frame(width: 600), background: 0x0D0F14,
                         to: directory.appendingPathComponent("settings-\(page.rawValue)@2x.png"))
        }
        // A light theme and custom sizes, to check the live preview follows.
        settings.set("ring", for: SettingsKeys.wheelLayout)
        Appearance.apply(theme: "midnight", to: settings)
        settings.set("light", for: SettingsKeys.wheelScheme)
        settings.set(1.2, for: SettingsKeys.ringThickness)
        settings.set("#5CE1FF", for: SettingsKeys.tintTools)
        settings.set("upper", for: SettingsKeys.labelCase)
        model.page = .appearance
        try snapshot(SettingsPageView(model: model, preview: preview).frame(width: 600), background: 0x0D0F14,
                     to: directory.appendingPathComponent("settings-appearance-custom@2x.png"))
        model.page = .general
        try snapshot(SettingsView(model: model).frame(width: 880, height: 640), background: 0x0D0F14,
                     to: directory.appendingPathComponent("window-settings@2x.png"))
        let onboarding = OnboardingModel(settings: settings)
        for step in 0..<3 {
            onboarding.step = step
            try snapshot(OnboardingView(model: onboarding), background: 0x0D0F14,
                         to: directory.appendingPathComponent("welcome-\(step + 1)@2x.png"))
        }
        let tutorial = TutorialModel(settings: settings)
        for step in [TutorialModel.Step.drag, .choose, .done, .finished] {
            tutorial.step = step
            if step == .done { tutorial.resultLine = "Practice photo.jpg · 41 KB" }
            try snapshot(TutorialView(model: tutorial), background: 0x0D0F14,
                         to: directory.appendingPathComponent("tutorial-\(step.rawValue + 1)@2x.png"))
        }
    }

    private final class PreviewSettingsHost: SettingsHost {
        let settingsWatch: WatchFolderService
        let settingsJobs: JobCenter
        let settingsUpdates: UpdateChecker
        init(watch: WatchFolderService, jobs: JobCenter) {
            settingsWatch = watch; settingsJobs = jobs
            settingsUpdates = UpdateChecker(settings: SettingsStore(defaults: UserDefaults(suiteName: "\(AppIdentity.bundleID).previews-updates")!))
        }
        func settingsApplyHotkeys() -> Set<UInt32> { [] }
        func settingsApplyStored(includingLoginItem: Bool) -> Set<UInt32> { [] }
        func settingsSuspendHotkeys() {}
        func settingsShowMenuBarIcon(_ visible: Bool) {}
        func settingsPracticeWheel() {}
        func settingsShowOnboarding() {}
        func settingsShowTutorial() {}
        func settingsSetDevHUD(_ on: Bool) {}
        func settingsDiagnostics() -> String { "" }
    }

    private static func snapshot<V: View>(_ view: V, background: UInt32, to url: URL) throws {
        let host = NSHostingView(rootView: view.padding(20).background(Color(hex: background)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError() }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError() }
        try data.write(to: url)
        print(url.path)
        window.contentView = nil
    }

    /// Board H: every icon state on light and dark bars, monochrome and colour.
    private static func renderIcons(into directory: URL) throws {
        let states: [StatusIconState] = [.idle, .dragOver, .converting(0.4), .converting(0.85), .done, .error, .paused]
        let rows: [(String, NSAppearance.Name, StatusIconStyle, UInt32)] = [
            ("light-mono", .aqua, .monochrome, 0xE4E0DA), ("dark-mono", .darkAqua, .monochrome, 0x26272C), ("dark-colour", .darkAqua, .colour, 0x26272C),
        ]
        let cell = CGSize(width: 60, height: 36)
        let size = CGSize(width: cell.width * CGFloat(states.count), height: cell.height * CGFloat(rows.count))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw RenderError() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (r, row) in rows.enumerated() {
            let y = size.height - cell.height * CGFloat(r + 1)
            NSColor(hex: row.3).setFill()
            CGRect(x: 0, y: y, width: size.width, height: cell.height).fill()
            NSAppearance(named: row.1)?.performAsCurrentDrawingAppearance {
                for (c, state) in states.enumerated() {
                    let image = StatusIcon.image(state, style: row.2, accent: NSColor(hex: 0xFF8A00))
                    image.draw(in: CGRect(x: CGFloat(c) * cell.width + (cell.width - 26) / 2, y: y + (cell.height - 22) / 2, width: 26, height: 22))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError() }
        let url = directory.appendingPathComponent("status-icon-states@2x.png")
        try data.write(to: url)
        print(url.path)
    }

    /// The tool dialogs, hosted in an offscreen window so AppKit-backed
    /// controls (fields, sliders, switches) draw too.
    private static func renderDialogs(into directory: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("circularity-previews-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("IMG_2041.HEIC")
        if let image = samplePicture(size: 1200, scale: 1),
           let dest = CGImageDestinationCreateWithURL(photo as CFURL, "public.heic" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        let pdf = dir.appendingPathComponent("Report.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) {
            ctx.beginPage(mediaBox: &box)
            if let image = samplePicture(size: 400, scale: 1) { ctx.draw(image, in: CGRect(x: 106, y: 300, width: 400, height: 400)) }
            ctx.endPage()
            ctx.closePDF()
        }
        let accent = SwiftUI.Color(hex: 0xFF4FA0)
        let none: (CircularityEngine.Operation, Preset?) -> Void = { _, _ in }
        let views: [(String, AnyView)] = [
            ("dialog-compress-image", AnyView(CompressDialog(files: [photo], isPDF: false, accent: accent, onRun: none, onCancel: {}))),
            ("dialog-compress-pdf", AnyView(CompressDialog(files: [pdf], isPDF: true, accent: accent, onRun: none, onCancel: {}))),
            ("dialog-resize-image", AnyView(ResizeDialog(files: [photo], isPDF: false, accent: accent, onRun: none, onCancel: {}))),
            ("dialog-resize-pdf", AnyView(ResizeDialog(files: [pdf], isPDF: true, accent: accent, onRun: none, onCancel: {}))),
            ("dialog-crop-image", AnyView(CropDialog(files: [photo], isPDF: false, accent: accent, onRun: none, onCancel: {}))),
            ("dialog-fit", AnyView(FitDialog(files: [photo, pdf], accent: accent, onRun: none, onCancel: {}))),
            ("dialog-lock", AnyView(PasswordDialog(files: [pdf], unlock: false, accent: accent, onRun: none, onCancel: {}))),
            ("dialog-unlock", AnyView(PasswordDialog(files: [pdf], unlock: true, accent: accent, onRun: none, onCancel: {}))),
            ("dialog-speed", AnyView(SpeedDialog(files: [photo], accent: accent, onRun: none, onCancel: {}))),
            ("dialog-pages", AnyView(PagesDialog(file: pdf, accent: accent, onRun: none, onCancel: {}))),
        ]
        for (name, view) in views {
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6)) // let onAppear work and estimates land
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError() }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError() }
            let url = directory.appendingPathComponent("\(name)@2x.png")
            try data.write(to: url)
            print(url.path)
            window.contentView = nil
        }
    }

    /// Wheel states matching the board screenshots (D: hover JPG, More fan,
    /// Cancel, Compress), for each layout and a few file kinds.
    private static func renderWheels(into directory: URL) throws {
        let photo = [UTType.heic]
        let states: [(String, WheelVisualState)] = [
            ("rest", WheelVisualState()),
            ("hover-jpg", WheelVisualState(hover: .segment(1))),
            ("more-fan", WheelVisualState(hover: .fanChip(0), fanOpen: true)),
            ("more-fan-flipped", WheelVisualState(hover: .fanChip(4), fanOpen: true, fanFlipped: true)),
            ("cancel", WheelVisualState(hover: .centre)),
            ("compress", WheelVisualState(hover: .segment(4))),
        ]
        let cases: [(WheelLayoutKind, [UTType], Int, UInt32, UInt32)] = [
            (.ring, photo, 1, 0xFF8A00, 0x1F2228),
            (.orbit, [.png, .png, .png], 3, 0xFF8A00, 0xE9E5DF),
            (.halo, photo, 1, 0xFF4FA0, 0x0D0F14),
        ]
        for (kind, types, count, accent, backdrop) in cases {
            for (name, state) in states {
                try renderWheel(kind: kind, types: types, count: count, accent: accent, backdrop: backdrop,
                                state: state, to: directory.appendingPathComponent("wheel-\(kind.rawValue)-\(name)@2x.png"))
            }
        }
        // Other file kinds on the default Ring.
        let extra: [(String, [UTType], WheelVisualState)] = [
            ("pdf", [.pdf], WheelVisualState(hover: .segment(0))),
            ("markdown", [UTType("net.daringfireball.markdown") ?? .plainText], WheelVisualState(hover: .segment(1))),
            ("video", [.mpeg4Movie], WheelVisualState()),
            ("batch", [.jpeg, .png], WheelVisualState(hover: .segment(2))),
        ]
        // Transparent Halo wheels for the website's "How it works".
        for (name, state) in [("hover-jpg", WheelVisualState(hover: .segment(1))), ("rest", WheelVisualState())] {
            try renderWheel(kind: .halo, types: [.heic], count: 1, accent: 0xFF4FA0, backdrop: 0, state: state,
                            to: directory.appendingPathComponent("wheel-halo-\(name)-clear@2x.png"))
        }
        // The same wheel in the Neon theme, for the website's Neon style.
        try renderWheel(kind: .halo, types: [.heic], count: 1, accent: 0xC6FF3D, backdrop: 0, state: WheelVisualState(hover: .segment(1)),
                        to: directory.appendingPathComponent("wheel-halo-neon-hover-jpg-clear@2x.png"))
        // A very long file name must stay inside the centre in every layout.
        let longName = "Family_holiday_in_the_mountains_summer_2026_final_edit_version_3_exported.HEIC"
        for kind in [WheelLayoutKind.halo, .ring, .orbit] {
            try renderWheel(kind: kind, types: [.heic], count: 1, accent: kind == .halo ? 0xFF4FA0 : 0xFF8A00, backdrop: 0x1F2228,
                            state: WheelVisualState(), fileName: longName,
                            to: directory.appendingPathComponent("wheel-\(kind.rawValue)-long-name@2x.png"))
        }
        // Wheel Studio looks, drawn by the app's own renderers (dots from WheelEffects).
        let looks: [(String, WheelLayoutKind, UInt32, CGFloat, (inout WheelStyle) -> Void)] = [
            ("studio-halo-stickers", .halo, 0xFF4FA0, 1.6, { $0.fillStyle = "stickers"; $0.corners = 0.5; $0.glow = 1; $0.ringDots = 12 }),
            ("studio-ring-outline", .ring, 0xFF4FA0, 1, { $0.fillStyle = "outline"; $0.corners = 0.35; $0.glow = 0.8; $0.dimOthers = false; $0.weight = .heavy }),
            ("studio-ring-rainbow", .ring, 0xFFFFFF, 1.4, { $0.fillStyle = "rainbow"; $0.corners = 1; $0.captions = false; $0.ringDots = 24; $0.glow = 0.6 }),
            ("studio-orbit-duo", .orbit, 0xFF4FA0, 1, { $0.fillStyle = "duo"; $0.glow = 0.8; $0.restOpacity = 0.75; $0.light = false }),
            ("studio-halo-paper", .halo, 0xFF4FA0, 1, { $0.fillStyle = "shades"; $0.discColor = .hex(0xF3EEE4); $0.textColor = .hex(0x17140F)
                $0.rimColor = .hex(0x2F5BFF); $0.rimWidth = 3; $0.tracking = 0.08 }),
        ]
        for (name, kind, accent, pop, tweak) in looks {
            try renderWheel(kind: kind, types: photo, count: 1, accent: accent, backdrop: kind == .orbit ? 0x14110D : 0x1F2228,
                            state: WheelVisualState(hover: .segment(1)), pop: pop, tweak: tweak,
                            to: directory.appendingPathComponent("\(name)@2x.png"))
        }
        for (name, types, state) in extra {
            try renderWheel(kind: .ring, types: types, count: types.count, accent: 0xFF8A00, backdrop: 0x1F2228,
                            state: state, to: directory.appendingPathComponent("wheel-ring-\(name)@2x.png"))
        }
        // Video and audio, and the Tools and Actions wheels (the default Halo look).
        let wheels: [(String, WheelKind, [UTType], String, WheelVisualState)] = [
            ("video-rest", .convert, [.mpeg4Movie], "IMG_4410.MOV", WheelVisualState()),
            ("video-hover-gif", .convert, [.mpeg4Movie], "IMG_4410.MOV", WheelVisualState(hover: .segment(2))),
            ("video-more-fan", .convert, [.mpeg4Movie], "IMG_4410.MOV", WheelVisualState(hover: .fanChip(0), fanOpen: true)),
            ("audio-rest", .convert, [.mp3], "Voice memo.mp3", WheelVisualState(hover: .segment(0))),
            ("tools-photo", .tools, [.heic], "IMG_2041.HEIC", WheelVisualState()),
            ("tools-video-trim", .tools, [.mpeg4Movie], "IMG_4410.MOV", WheelVisualState(hover: .segment(0))),
            ("tools-folder", .tools, [.folder], "Invoices", WheelVisualState()),
            ("convert-folder", .convert, [.folder], "Invoices", WheelVisualState()),
            ("actions-rest", .actions, [.folder], "Invoices", WheelVisualState()),
            ("actions-airdrop", .actions, [.heic], "IMG_2041.HEIC", WheelVisualState(hover: .segment(0))),
            ("actions-more-fan", .actions, [.heic], "IMG_2041.HEIC", WheelVisualState(hover: .fanChip(0), fanOpen: true)),
        ]
        // Every layout × every wheel, at rest and with More open, with the key guide.
        let matrix: [(String, WheelKind, [UTType], String)] = [
            ("convert-photo", .convert, [.heic], "IMG_2041.HEIC"), ("convert-video", .convert, [.mpeg4Movie], "IMG_4410.MOV"),
            ("tools-photo", .tools, [.heic], "IMG_2041.HEIC"), ("tools-pdf", .tools, [.pdf], "Report.pdf"),
            ("tools-video", .tools, [.mpeg4Movie], "IMG_4410.MOV"), ("actions", .actions, [.folder], "Invoices"),
        ]
        for layout in [WheelLayoutKind.halo, .ring, .orbit] {
            for (name, wheel, types, file) in matrix {
                for (state, stateName) in [(WheelVisualState(), "rest"), (WheelVisualState(hover: .fanChip(0), fanOpen: true), "fan")] {
                    try renderWheel(kind: layout, types: types, count: 1, accent: layout == .halo ? 0xFF4FA0 : 0xFF8A00,
                                    backdrop: layout == .orbit ? 0xE9E5DF : 0x0D0F14, state: state, fileName: file, wheel: wheel, guide: true,
                                    to: directory.appendingPathComponent("matrix-\(layout.rawValue)-\(name)-\(stateName)@2x.png"))
                }
            }
        }
        // README: the hero animation's frames and the three wheels side by side (Halo, the default look).
        let readme = directory.appendingPathComponent("readme", isDirectory: true)
        try FileManager.default.createDirectory(at: readme, withIntermediateDirectories: true)
        let frames: [(WheelKind, [UTType], String, WheelVisualState)] = [
            (.convert, [.heic], "IMG_2041.HEIC", WheelVisualState()),
            (.convert, [.heic], "IMG_2041.HEIC", WheelVisualState(hover: .segment(1))),
            (.convert, [.heic], "IMG_2041.HEIC", WheelVisualState(hover: .fanChip(2), fanOpen: true)),
            (.tools, [.heic], "IMG_2041.HEIC", WheelVisualState()),
            (.tools, [.heic], "IMG_2041.HEIC", WheelVisualState(hover: .segment(1))),
            (.tools, [.heic], "IMG_2041.HEIC", WheelVisualState(hover: .segment(2))),
            (.actions, [.heic], "IMG_2041.HEIC", WheelVisualState()),
            (.actions, [.heic], "IMG_2041.HEIC", WheelVisualState(hover: .segment(0))),
            (.convert, [.mpeg4Movie], "Holiday.MOV", WheelVisualState(hover: .segment(2))),
        ]
        for (i, (wheel, types, file, state)) in frames.enumerated() {
            try renderWheel(kind: .halo, types: types, count: 1, accent: 0xFF4FA0, backdrop: 0x0D0F14, state: state, fileName: file,
                            wheel: wheel, guide: true, to: readme.appendingPathComponent(String(format: "hero-%02d.png", i)))
        }
        for (wheel, types, file) in [(WheelKind.convert, [UTType.heic], "IMG_2041.HEIC"), (.tools, [.pdf], "Lease.pdf"),
                                     (.actions, [.folder], "Invoices")] {
            try renderWheel(kind: .halo, types: types, count: 1, accent: 0xFF4FA0, backdrop: 0x0D0F14, state: WheelVisualState(),
                            fileName: file, wheel: wheel, guide: true, to: readme.appendingPathComponent("trio-\(wheel.rawValue).png"))
        }
        for (layout, accent, backdrop) in [(WheelLayoutKind.ring, UInt32(0xFF8A00), UInt32(0x1F2228)), (.orbit, 0xFF8A00, 0xE9E5DF)] {
            try renderWheel(kind: layout, types: [.mpeg4Movie], count: 1, accent: accent, backdrop: backdrop, state: WheelVisualState(hover: .segment(2)),
                            fileName: "Holiday.MOV", wheel: .tools, guide: true, to: readme.appendingPathComponent("layout-\(layout.rawValue).png"))
        }
        for (name, wheel, types, file, state) in wheels {
            for kind in [WheelLayoutKind.halo, .orbit] where kind == .halo || name.hasSuffix("rest") {
                try renderWheel(kind: kind, types: types, count: 1, accent: kind == .halo ? 0xFF4FA0 : 0xFF8A00,
                                backdrop: kind == .orbit ? 0xE9E5DF : 0x0D0F14, state: state, fileName: file, wheel: wheel,
                                to: directory.appendingPathComponent("wheel-\(kind.rawValue)-\(name)@2x.png"))
            }
        }
    }

    private static func renderWheel(kind: WheelLayoutKind, types: [UTType], count: Int, accent: UInt32, backdrop: UInt32,
                                    state: WheelVisualState, fileName: String = "IMG_2041.HEIC", pop: CGFloat = 1,
                                    wheel: WheelKind = .convert, guide: Bool = false,
                                    tweak: ((inout WheelStyle) -> Void)? = nil, to url: URL) throws {
        let renderer: WheelRenderer = switch kind {
        case .ring: SectorRenderer(style: .ring)
        case .halo: SectorRenderer(style: .halo)
        case .orbit: OrbitRenderer()
        }
        renderer.allowsTilt = false // render(in:) skips 3D transforms
        var menu: WheelMenu = switch wheel {
        case .convert: SlotProvider.menu(for: types, canWrite: { FormatSupport.current.canWrite($0) })
        case .tools: SlotProvider.toolsMenu(for: types)
        case .actions: SlotProvider.actionsMenu(count: count)
        }
        let keys = WheelKeyMap(convert: "shift", tools: "command", actions: "control")
        menu.kind = wheel
        menu.restHint = guide ? nil : keys.restHint(for: wheel)
        if wheel != .actions, menu.notice != nil { menu.notice?.detail = "⌃ for actions: AirDrop, Copy…" }
        let single = count == 1
        let content = OrbContent(fileLine: single ? "\(fileName) · 3.2 MB" : "\(count) images · 8.7 MB",
                                 title: single ? fileName : "\(count) images",
                                 detail: single ? "3.2 MB" : "8.7 MB total", count: count,
                                 thumbnail: samplePicture(size: 240, scale: 2), clickMode: false)
        let geometry = WheelGeometry.make(kind, tweaks: WheelTweaks(pop: pop))
        var look = WheelStyle.board(accent: accent, light: kind == .orbit)
        tweak?(&look)
        renderer.configure(menu: menu, orb: content, style: look, geometry: geometry, contentsScale: 2)
        // With a tweak, render through WheelEffects too, so its dots show.
        let effects = tweak == nil ? nil : WheelEffects()
        if let effects {
            effects.attach(renderer.layer)
            effects.configure(style: look, geometry: geometry, bounds: CGRect(x: 0, y: 0, width: geometry.size, height: geometry.size), contentsScale: 2)
            renderer.layer.frame = effects.root.bounds
        }
        // The key guide, drawn as the app draws it.
        let keyGuide = KeyGuideLayer()
        if guide {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            renderer.apply(WheelVisualState(), animated: false)
            CATransaction.commit()
            let drawn = KeyGuideLayer.reach(of: effects?.root ?? renderer.layer, renderer: renderer, geometry: geometry)
            keyGuide.configure(keys: keys, current: wheel, style: look, scale: geometry.scale, contentsScale: 2)
            (effects?.root ?? renderer.layer).addSublayer(keyGuide.layer)
            keyGuide.place(center: CGPoint(x: geometry.size / 2, y: geometry.size / 2), radius: drawn,
                           below: state.fanFlipped, canvas: geometry.size)
        }
        defer { keyGuide.layer.removeFromSuperlayer() }
        var s = state
        if case .segment = s.hover {
            let o = WheelGeometry.offset(radius: geometry.contentRadius(hovered: true), angle: 60)
            s.cursor = CGPoint(x: o.x + 20, y: o.y + 20)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.apply(s, animated: false)
        CATransaction.commit()
        let size = CGSize(width: geometry.size, height: geometry.size)
        guard let image = renderImage(size: size, scale: 2, { ctx in
            if backdrop != 0 { // 0 = transparent (for the website)
                ctx.setFillColor(.hex(backdrop))
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            let top = effects?.root ?? renderer.layer
            top.layoutIfNeeded()
            top.render(in: ctx)
        }), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw RenderError()
        }
        try data.write(to: url)
        print(url.path)
    }

    private static func png(size: CGSize, scale: CGFloat, background: NSColor, draw: () -> Void) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw RenderError() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background.setFill()
        CGRect(origin: .zero, size: size).fill()
        draw()
        NSGraphicsContext.current?.flushGraphics()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError() }
        return data
    }
}

extension NSColor {
    /// sRGB colour from a 0xRRGGBB literal (design tokens, PLAN.md §9).
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension RenderPreviews {
    /// A wheel exactly as the app would draw it with `settings` (a HEIC photo,
    /// JPG lit, on `backdrop`), dots included. `--check-themes <file> <dir>`
    /// uses it to put each Wheel Studio export next to the Studio's own picture.
    /// `fanOpen`: the More fan open with its second chip lit, instead of a lit ring button.
    /// Every wheel (Convert, Tools, Actions on photos, PDFs, video, audio) in
    /// this theme's look, every button at rest and hovered and the More fan:
    /// the words that didn't fit and had to be cut. Should always be empty.
    static func labelCuts(_ settings: SettingsStore) -> [String] {
        let kind = WheelLayoutKind(rawValue: settings.value(SettingsKeys.wheelLayout)) ?? .halo
        let renderer: WheelRenderer = switch kind {
        case .ring: SectorRenderer(style: .ring)
        case .halo: SectorRenderer(style: .halo)
        case .orbit: OrbitRenderer()
        }
        renderer.allowsTilt = false
        let geometry = Appearance.geometry(settings, layout: kind), look = Appearance.wheelStyle(settings, layout: kind)
        let content = OrbContent(fileLine: "a.heic", title: "a.heic", detail: "1 MB", count: 1, thumbnail: nil, clickMode: false)
        let all: (OutputFormat) -> Bool = { _ in true }
        let menus: [WheelMenu] = [
            SlotProvider.menu(for: [.heic], canWrite: all), SlotProvider.menu(for: [.mpeg4Movie], canWrite: all),
            SlotProvider.menu(for: [.mp3], canWrite: all), SlotProvider.menu(for: [.pdf], canWrite: all),
            SlotProvider.toolsMenu(for: [.heic], cutout: true), SlotProvider.toolsMenu(for: [.pdf]),
            SlotProvider.toolsMenu(for: [.mpeg4Movie]), SlotProvider.actionsMenu(count: 1),
        ]
        TextFit.cuts = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for menu in menus {
            renderer.configure(menu: menu, orb: content, style: look, geometry: geometry, contentsScale: 1)
            var states = [WheelVisualState()] + (0..<6).map { WheelVisualState(hover: .segment($0)) }
            states += menu.fan.indices.map { WheelVisualState(hover: .fanChip($0), fanOpen: true) }
            for state in states { renderer.apply(state, animated: false) }
        }
        CATransaction.commit()
        return Array(Set(TextFit.cuts.filter { !$0.hasPrefix("a.heic") })).sorted()
    }

    static func renderTheme(_ settings: SettingsStore, backdrop: UInt32 = 0x1F2228, fanOpen: Bool = false, to url: URL) throws {
        let kind = WheelLayoutKind(rawValue: settings.value(SettingsKeys.wheelLayout)) ?? .halo
        let renderer: WheelRenderer = switch kind {
        case .ring: SectorRenderer(style: .ring)
        case .halo: SectorRenderer(style: .halo)
        case .orbit: OrbitRenderer()
        }
        renderer.allowsTilt = false
        let menu = SlotProvider.menu(for: [.heic], canWrite: { FormatSupport.current.canWrite($0) })
        let content = OrbContent(fileLine: "IMG_2041.HEIC · 3.2 MB", title: "IMG_2041.HEIC", detail: "3.2 MB", count: 1,
                                 thumbnail: samplePicture(size: 240, scale: 2), clickMode: false)
        let geometry = Appearance.geometry(settings, layout: kind), look = Appearance.wheelStyle(settings, layout: kind)
        renderer.configure(menu: menu, orb: content, style: look, geometry: geometry, contentsScale: 2)
        let effects = WheelEffects()
        effects.attach(renderer.layer)
        effects.configure(style: look, geometry: geometry, bounds: CGRect(x: 0, y: 0, width: geometry.size, height: geometry.size), contentsScale: 2)
        renderer.layer.frame = effects.root.bounds
        var state = WheelVisualState(hover: fanOpen ? .fanChip(1) : .segment(1))
        state.fanOpen = fanOpen
        let o = WheelGeometry.offset(radius: geometry.contentRadius(hovered: true), angle: 60)
        state.cursor = CGPoint(x: o.x + 20, y: o.y + 20)
        // The key guide in this theme's look, placed as the app places it (measured at rest).
        CATransaction.begin(); CATransaction.setDisableActions(true)
        renderer.apply(WheelVisualState(), animated: false)
        CATransaction.commit()
        let drawn = KeyGuideLayer.reach(of: effects.root, renderer: renderer, geometry: geometry)
        let keyGuide = KeyGuideLayer()
        keyGuide.configure(keys: GestureController.keyMap(settings), current: .convert, style: look, scale: geometry.scale, contentsScale: 2)
        effects.root.addSublayer(keyGuide.layer)
        keyGuide.place(center: CGPoint(x: geometry.size / 2, y: geometry.size / 2), radius: drawn, below: false,
                       canvas: geometry.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        renderer.apply(state, animated: false)
        CATransaction.commit()
        let size = CGSize(width: geometry.size, height: geometry.size)
        guard let image = renderImage(size: size, scale: 1, { ctx in
            ctx.setFillColor(.hex(backdrop)); ctx.fill(CGRect(origin: .zero, size: size))
            effects.root.layoutIfNeeded(); effects.root.render(in: ctx)
        }), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw RenderError() }
        try data.write(to: url)
    }
}
