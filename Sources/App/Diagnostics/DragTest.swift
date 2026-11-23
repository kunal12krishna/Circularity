import AppKit
import CoreText
import CircularityEngine

/// `--drag-test` level 1 (PLAN.md §3.9): shows the real wheel panel and calls
/// its NSDraggingDestination methods with a simulated drag carrying a real
/// file. Needs no permission. Level 2 (real synthetic mouse events) needs
/// Accessibility for the test runner and is documented in docs/MANUAL-TESTS.md.
enum DragTest {
    static func run() {
        Task { @MainActor in
            let ok = await runChecks()
            print(ok ? "DragTest: all checks passed" : "DragTest: FAILED")
            exit(ok ? 0 : 1)
        }
    }

    @MainActor
    private static func runChecks() async -> Bool {
        let defaults = UserDefaults(suiteName: "\(AppIdentity.bundleID).dragtest")!
        defaults.removePersistentDomain(forName: "\(AppIdentity.bundleID).dragtest")
        let settings = SettingsStore(defaults: defaults, suiteName: "\(AppIdentity.bundleID).dragtest")
        settings.set(false, for: SettingsKeys.smartOrdering)
        settings.set(false, for: SettingsKeys.haptics)
        let wheel = WheelController(settings: settings)
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print(ok ? "PASS  \(label)" : "FAIL  \(label)")
            if !ok { failures += 1 }
        }

        // Settings migration v1 → v2 on the real store: a Halo user's accent survives.
        let v1Suite = "\(AppIdentity.bundleID).dragtest-v1"
        if let v1 = UserDefaults(suiteName: v1Suite) {
            v1.removePersistentDomain(forName: v1Suite)
            v1.set(1, forKey: SettingsKeys.schemaVersionKey)
            v1.set("halo", forKey: SettingsKeys.wheelLayout.name)
            v1.set("#5CE1FF", forKey: SettingsKeys.haloAccentHex.name)
            let migrated = SettingsStore(defaults: v1, suiteName: v1Suite)
            check(migrated.value(SettingsKeys.accentHex) == "#5CE1FF" && v1.integer(forKey: SettingsKeys.schemaVersionKey) == 2,
                  "settings v1 → v2 keeps the Halo accent (got \(migrated.value(SettingsKeys.accentHex)))")
            v1.removePersistentDomain(forName: v1Suite)
        }

        guard let file = writeSampleHEIC() else {
            print("FAIL  could not write a sample file")
            return false
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let center = CGPoint(x: screen.midX, y: screen.midY)
        let g = WheelGeometry.ring()
        func point(_ offset: CGPoint) -> CGPoint { CGPoint(x: g.size / 2 + offset.x, y: g.size / 2 - offset.y) }
        func segment(_ i: Int) -> CGPoint { point(WheelGeometry.offset(radius: 150, angle: WheelGeometry.midAngle(ofSlot: i))) }
        let info = SimulatedDrag(file: file)

        var finished: WheelChoice?
        var dismissed = false
        wheel.onFinished = { finished = $0 }
        wheel.onDragDismissed = { dismissed = true }
        func show() async {
            finished = nil
            dismissed = false
            wheel.show(DraggedFiles(urls: [file]), at: center, mode: .drag)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        print("Memory before the first wheel: \(MemoryFootprint.megabytes)")
        // 1. Drop on JPG (slot 1).
        await show()
        print("Memory with the wheel showing: \(MemoryFootprint.megabytes)")
        check(wheel.isVisible, "wheel panel appears at the given point")
        wheel.dragPointer(at: segment(1))
        let dropped = wheel.performDrop(info, at: segment(1))
        check(dropped, "drop on a segment is accepted")
        check(finished?.action == .convert(.jpg), "drop on JPG chooses Convert to JPG (got \(finished?.label ?? "nothing"))")
        check(finished?.files == [file], "the dropped file URL comes from the drag pasteboard")
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(!wheel.isVisible, "wheel hides after the drop")

        // End to end: the choice runs through the engine and a JPG lands next to the original.
        let jobs = JobCenter(settings: settings, history: HistoryStore(file: "dragtest-history.json"), stats: StatsStore(file: "dragtest-stats.json"))
        if let choice = finished, let action = choice.action {
            check(jobs.run(action, files: choice.files) == nil, "the job starts")
            for _ in 0..<50 where jobs.lastSummary == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            let out = jobs.lastOutputs.first
            check(out?.pathExtension == "jpg" && out?.deletingLastPathComponent() == file.deletingLastPathComponent(),
                  "the JPG is written next to the original (\(jobs.lastSummary ?? "no result"))")
            check(FileManager.default.fileExists(atPath: file.path), "the original is untouched")

            // What the Resize dialog submits, then a saved button from it.
            func waitForResult() async -> URL? {
                let before = jobs.lastOutputs
                for _ in 0..<60 where jobs.runningCount > 0 || jobs.lastOutputs == before {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                return jobs.lastOutputs.first
            }
            jobs.run(.resize(ResizeSpec(width: 128, height: nil)), files: [file], label: "resize")
            let resized = await waitForResult()
            check(resized?.lastPathComponent == "IMG_2041 (resized).heic", "Resize dialog result: \(resized?.lastPathComponent ?? "none")")
            let button = Preset(applies: .images, action: .compressQuality(0.5))
            jobs.addPreset(button)
            check(jobs.presets.first?.name == "Q50", "“Also add this as a button” saves Q50")
            jobs.run(.preset(button.id), files: [file])
            let compressed = await waitForResult()
            check(compressed != nil || (jobs.lastSummary ?? "").hasPrefix("Kept"),
                  "the saved button runs (\(jobs.lastSummary ?? "no result"))")
            jobs.removePreset(id: button.id)

            // Panel: a preset tile dropped-on with a file, and a ⌘K command.
            let watch = WatchFolderService(settings: settings, jobs: jobs)
            let panelModel = PanelModel(jobs: jobs, watch: watch, settings: settings)
            panelModel.run(PanelModel.builtins[0], files: [file]) // → JPG
            let tileResult = await waitForResult()
            check(tileResult?.pathExtension == "jpg", "panel tile → JPG converts a dropped file (\(tileResult?.lastPathComponent ?? "none"))")
            jobs.run(.resizeWidth(64), files: [file])
            let commandResult = await waitForResult()
            check(commandResult?.lastPathComponent.contains("(resized)") == true, "⌘K “64w” resizes (\(commandResult?.lastPathComponent ?? "none"))")
            check(jobs.history.items.count >= 3 && jobs.stats.today.files >= 3, "history and stats record conversions")
            check(!watch.isStreaming, "no watch folders: no FSEvents stream runs")

            // Watch folder, for real: FSEvents → stable size → convert.
            let watched = file.deletingLastPathComponent().appendingPathComponent("watched", isDirectory: true)
            try? FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
            watch.add(WatchRule(folder: watched.path, match: .images, format: .jpg))
            check(watch.isStreaming, "a watch folder starts the FSEvents stream")
            try? await Task.sleep(nanoseconds: 500_000_000)
            try? FileManager.default.copyItem(at: file, to: watched.appendingPathComponent("Screenshot.heic"))
            var watchedOutput: URL?
            for _ in 0..<80 where watchedOutput == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
                watchedOutput = (try? FileManager.default.contentsOfDirectory(at: watched, includingPropertiesForKeys: nil))?
                    .first { $0.pathExtension == "jpg" }
            }
            check(watchedOutput?.lastPathComponent == "Screenshot.jpg", "a file dropped into a watched folder becomes Screenshot.jpg")
            for rule in watch.rules { watch.remove(rule.id) }

            // The real panel: open (SwiftUI built), close (released).
            MemoryFootprint.relieve()
            let beforePanel = MemoryFootprint.current()
            let menuPanel = MenuPanelController(model: panelModel, settings: settings)
            menuPanel.open()
            try? await Task.sleep(nanoseconds: 800_000_000)
            check(menuPanel.isOpen, "the panel opens (frame \(menuPanel.frameForTesting.map { "\($0)" } ?? "none"))")

            // ⌃⌥Space path: ⌘K focused, real key events typed into the window.
            menuPanel.open(focusCommand: true)
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let window = menuPanel.windowForTesting {
                for (ch, code) in [("1", 18), ("0", 29), ("k", 40), ("b", 11)] as [(String, UInt16)] {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: ch,
                                                    charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) {
                            window.sendEvent(e)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }
            check(panelModel.query == "10kb", "typing “10kb” into ⌘K keeps focus (got “\(panelModel.query)”)")
            check(menuPanel.isOpen, "the panel stays open while typing")
            check(panelModel.results.first?.kind == .command(.compressUnder(10_000)), "“10kb” means Compress under 10 KB")
            panelModel.query = ""
            let openMB = Double(MemoryFootprint.current()) / 1_048_576
            menuPanel.close()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            MemoryFootprint.relieve()
            check(!menuPanel.isOpen, "the panel closes")
            print(String(format: "Memory: before panel %.1f MB, panel open %.1f MB, after close %.1f MB",
                         Double(beforePanel) / 1_048_576, openMB, Double(MemoryFootprint.current()) / 1_048_576))
            for round in 2...4 {
                menuPanel.open()
                try? await Task.sleep(nanoseconds: 600_000_000)
                menuPanel.close()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                MemoryFootprint.relieve()
                print(String(format: "Memory after panel open/close #%d: %.1f MB", round, Double(MemoryFootprint.current()) / 1_048_576))
            }
            check(!watch.isStreaming, "removing the last rule stops the stream")

            // Settings → Output really applies to jobs: folder, name template, timestamps, per-type folder.
            let results = file.deletingLastPathComponent().appendingPathComponent("Results", isDirectory: true)
            let pdfs = file.deletingLastPathComponent().appendingPathComponent("PDFs", isDirectory: true)
            for dir in [results, pdfs] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            func same(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }
            settings.set("folder", for: SettingsKeys.destination)
            settings.set(results.path, for: SettingsKeys.outputFolder)
            settings.set("{name} {format}", for: SettingsKeys.namingTemplate)
            jobs.run(.convert(.png), files: [file], label: "settings")
            let named = await waitForResult()
            check(same(named?.deletingLastPathComponent(), results) && named?.lastPathComponent.hasPrefix("IMG_2041 ") == true
                  && named?.pathExtension == "png", "Output folder and name template apply (\(named?.lastPathComponent ?? "none"))")
            settings.set("time", for: SettingsKeys.collisionStyle)
            jobs.run(.convert(.png), files: [file], label: "settings")
            let stamped = await waitForResult()
            check(stamped?.lastPathComponent.contains(" at ") == true, "a taken name gets a timestamp (\(stamped?.lastPathComponent ?? "none"))")
            settings.set(pdfs.path, for: SettingsKeys.folderPDFs)
            jobs.run(.convert(.pdf), files: [file], label: "settings")
            let pdf = await waitForResult()
            check(same(pdf?.deletingLastPathComponent(), pdfs), "PDFs go to their own folder (\(pdf?.path ?? "none"))")
            settings.set("stripAll", for: SettingsKeys.metadata)
            settings.set(0.4, for: SettingsKeys.qualityJPG)
            let policy = jobs.outputPolicy(for: .convert(.jpg))
            check(policy.metadata == .stripAll && policy.quality[.jpg] == 0.4, "metadata and quality settings reach the engine")
            for key in [SettingsKeys.destination.name, SettingsKeys.outputFolder.name, SettingsKeys.namingTemplate.name,
                        SettingsKeys.collisionStyle.name, SettingsKeys.folderPDFs.name, SettingsKeys.metadata.name, SettingsKeys.qualityJPG.name] {
                settings.remove(key)
            }

            // Review fixes, checked for real.
            // a) "Move the original to the Trash" never fires for a PDF split into a folder of pages.
            let pdfURL = file.deletingLastPathComponent().appendingPathComponent("Two pages.pdf")
            if let ctx = CGContext(pdfURL as CFURL, mediaBox: nil, nil) {
                for _ in 0..<2 { ctx.beginPDFPage(nil); ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200)); ctx.endPDFPage() }
                ctx.closePDF()
            }
            settings.set(true, for: SettingsKeys.replaceOriginal)
            jobs.run(.pdfPages(.png, scale: 1), files: [pdfURL], label: "pages")
            let pages = await waitForResult()
            try? await Task.sleep(nanoseconds: 300_000_000)
            check(pages != nil && FileManager.default.fileExists(atPath: pdfURL.path),
                  "a PDF split into page images keeps its original even with “Move the original to the Trash” on")
            settings.remove(SettingsKeys.replaceOriginal.name)

            // b) Practice pictures ignore Output settings and aren't recorded.
            settings.set("folder", for: SettingsKeys.destination)
            settings.set(results.path, for: SettingsKeys.outputFolder)
            let historyBefore = jobs.history.items.count
            if let practice = TutorialModel.freshPractice() {
                jobs.run(.convert(.jpg), files: [practice], label: "practice")
                let out = await waitForResult()
                check(same(out?.deletingLastPathComponent(), practice.deletingLastPathComponent()) && jobs.history.items.count == historyBefore,
                      "a practice conversion stays next to the practice picture and isn't recorded")
            }
            settings.remove(SettingsKeys.destination.name)
            settings.remove(SettingsKeys.outputFolder.name)

            // c) A hostile settings file: bad values are skipped, huge numbers don't crash.
            let hostile = ##"{"app":"x","schemaVersion":2,"values":{"menubar.recentsCount":1e30,"wheel.usage":{"png":1e300},"wheel.layout":"triangle","general.hotkey.panel":"0:512","appearance.accentHex":"#5CE1FF","wheel.scale":9}}"##
            if let imported = try? settings.importJSON(Data(hostile.utf8)) {
                check(imported.applied == 2 && settings.value(SettingsKeys.wheelLayout) != "triangle"
                      && settings.value(SettingsKeys.recentsCount) == 5 && settings.value(SettingsKeys.accentHex) == "#5CE1FF",
                      "importing bad values skips them (applied \(imported.applied), skipped \(imported.skipped))")
            } else {
                check(false, "importing a settings file with bad values")
            }
            for name in ["appearance.accentHex", "wheel.usage"] { settings.remove(name) }

            // The tutorial follows a real conversion of its practice picture.
            let tutorial = TutorialModel(settings: settings)
            tutorial.wheelShown()
            check(tutorial.step == .choose, "tutorial: the wheel appearing moves on to “choose a format”")
            if let practice = tutorial.practice {
                var practiceResult: JobResult?
                jobs.run(.convert(.jpg), files: [practice], label: "tutorial") { if case let .success(r) = $0 { practiceResult = r } }
                for _ in 0..<50 where practiceResult == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                if let practiceResult { tutorial.jobFinished(practiceResult) }
            }
            check(tutorial.step == .done, "tutorial: converting the practice picture completes step 2")
            jobs.history.clear()
            jobs.stats.reset()
        }

        // A theme from the website's theme builder applies (same JSON as "Copy theme" there).
        let websiteTheme = ##"{"app":"Circularity","schemaVersion":2,"values":{"appearance.theme":"custom","appearance.accentHex":"#FF5CA8","wheel.layout":"ring","appearance.wheelScheme":"light","appearance.glassStrength":0.4,"appearance.tint.tools":"#5CE1FF","wheel.scale":1.1,"appearance.ringThickness":1.15,"appearance.segmentGap":4,"appearance.orbScale":0.95,"appearance.labelScale":1.05,"appearance.font":"mono","appearance.labelCase":"upper","menubar.colorScheme":"dark","general.paused":true}}"##
        if let applied = try? settings.importJSON(Data(websiteTheme.utf8), only: SettingsModel.themeKeys, wholeLook: SettingsModel.lookKeys) {
            check(applied.applied == 14 && settings.value(SettingsKeys.accentHex) == "#FF5CA8" && settings.value(SettingsKeys.wheelLayout) == "ring"
                  && !settings.value(SettingsKeys.paused),
                  "a website theme applies its 14 look settings and nothing else (skipped \(applied.skipped))")
        } else {
            check(false, "a website theme applies")
        }
        for key in SettingsModel.themeKeys { settings.remove(key) }

        // Shortcuts: a rebound one registers, and a taken one is reported (not silently lost).
        let combo = HotkeySpec(keyCode: 111, modifiers: HotkeySpec.control | HotkeySpec.option | HotkeySpec.shift) // ⌃⌥⇧F12
        check(HotkeyCenter.shared.register(id: 90, keyCode: combo.keyCode, modifiers: combo.modifiers) {}, "a rebound shortcut registers")
        check(!HotkeyCenter.shared.register(id: 91, keyCode: combo.keyCode, modifiers: combo.modifiers) {},
              "a shortcut that is already taken is reported")
        HotkeyCenter.shared.unregister(id: 90)
        HotkeyCenter.shared.unregister(id: 91)

        // The Settings window and the welcome open for real, on every page.
        // A job that writes nothing still answers by the pointer (the shelf in message mode).
        let shelf = DropShelf()
        shelf.showMessage("Kept the original", "Its pictures are already small.", original: TutorialModel.freshPractice(),
                          accent: .systemPink)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(shelf.isShowing, "a kept-original result shows a message by the pointer")
        if let dir = ProcessInfo.processInfo.environment["CIRCULARITY_SHELF_PNG"], let rep = shelf.snapshot(),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("shelf-message.png"))
        }
        check(shelf.holdsEscape, "the result card holds Esc while it's on screen")
        shelf.hide()
        check(!shelf.holdsEscape && !HotkeyCenter.shared.isRegistered(id: 40), "…and lets go of Esc the moment it goes")

        // The result card for a real result: savings, Undo, snapshot.
        let smaller = file.deletingLastPathComponent().appendingPathComponent("IMG_2041 card.heic")
        try? FileManager.default.copyItem(at: file, to: smaller)
        shelf.show([smaller], accent: .systemPink, bytesIn: Int64((try? smaller.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) * 3,
                   undoable: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(shelf.isShowing && shelf.holdsEscape, "a result shows on the card, Esc ready")
        if let dir = ProcessInfo.processInfo.environment["CIRCULARITY_SHELF_PNG"], let rep = shelf.snapshot(),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("shelf-result.png"))
        }
        shelf.hide()

        // The Stash collects across actions and doesn't hold Esc until the pointer is on it.
        let performer = FileActionPerformer(shelf: shelf, accent: { .systemPink })
        performer.perform(.stash, files: [file])
        performer.perform(.stash, files: [smaller, file])
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(performer.stash.stashed.map(\.lastPathComponent) == ["IMG_2041.heic", "IMG_2041 card.heic"],
              "the Stash collects, once each (\(performer.stash.stashed.map(\.lastPathComponent)))")
        check(!performer.stash.holdsEscape, "the Stash leaves Esc alone until the pointer is on it")
        if let dir = ProcessInfo.processInfo.environment["CIRCULARITY_SHELF_PNG"], let rep = performer.stash.snapshot(),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("shelf-stash.png"))
        }
        performer.stash.hide()
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(performer.stash.stashed.isEmpty, "a closed Stash is empty next time")

        // Zip, for real (macOS's ditto): one item and several.
        let zipOne = file.deletingLastPathComponent().appendingPathComponent("one.zip")
        let zipMany = file.deletingLastPathComponent().appendingPathComponent("many.zip")
        let zipped = (try? FileActionPerformer.makeZip([file], to: zipOne)) != nil
            && (try? FileActionPerformer.makeZip([file, smaller], to: zipMany)) != nil
        let listing = { (url: URL) -> String in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo"); p.arguments = ["-1", url.path]
            let out = Pipe(); p.standardOutput = out; try? p.run(); p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        check(zipped && listing(zipOne).split(separator: "\n") == ["IMG_2041.heic"]
              && Set(listing(zipMany).split(separator: "\n")) == ["IMG_2041.heic", "IMG_2041 card.heic"],
              "Zip: one file, and several side by side at the root")
        check(FileActionPerformer.zipName([file]) == "IMG_2041.heic.zip" && FileActionPerformer.zipName([file, smaller]) == "Archive.zip",
              "Zip names follow Finder")

        // Rename for real: a swap (a ↔ b) and a new name, recorded so Undo puts them back.
        let renameDir = file.deletingLastPathComponent().appendingPathComponent("rename", isDirectory: true)
        try? FileManager.default.createDirectory(at: renameDir, withIntermediateDirectories: true)
        for (name, text) in [("a.txt", "A"), ("b.txt", "B"), ("c.txt", "C")] {
            try? text.write(to: renameDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let history = HistoryStore(file: "dragtest-rename-history.json")
        history.clear()
        let renamer = FileActionPerformer(shelf: shelf, accent: { .systemPink })
        renamer.record = { history.add($0) }
        renamer.rename([(renameDir.appendingPathComponent("a.txt"), "b.txt"), (renameDir.appendingPathComponent("b.txt"), "a.txt"),
                        (renameDir.appendingPathComponent("c.txt"), "Trip 03.txt")])
        let read = { (name: String) in (try? String(contentsOf: renameDir.appendingPathComponent(name), encoding: .utf8)) ?? "-" }
        check(read("b.txt") == "A" && read("a.txt") == "B" && read("Trip 03.txt") == "C", "Rename: a swap and a new name, contents intact")
        check(history.items.first?.kind == "move" && history.items.first?.outputs.count == 3, "Rename is recorded for Undo")
        if let id = history.items.first?.id { history.undo(id) }
        check(read("a.txt") == "A" && read("b.txt") == "B" && read("c.txt") == "C", "Undo puts the old names back")
        history.clear()
        try? FileManager.default.removeItem(at: renameDir)

        let presenter = WindowPresenter()
        let settingsModel = SettingsModel(store: settings)
        presenter.show("settings", title: "Settings", size: CGSize(width: 880, height: 680)) { SettingsView(model: settingsModel) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        for page in SettingsPage.allCases where page != .watch {
            settingsModel.page = page
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        let settingsWindow = NSApp.windows.first { $0.identifier?.rawValue == "settings" }
        check(settingsWindow?.isVisible == true, "the Settings window opens and shows every page")
        settings.set("ring", for: SettingsKeys.wheelLayout)
        Appearance.apply(theme: "tangerine", to: settings)
        check(settings.value(SettingsKeys.accentHex) == "#FF8A00", "choosing a theme sets its accent")
        presenter.close("settings")
        let welcome = OnboardingModel(settings: settings)
        presenter.show("welcome", title: "Welcome", size: CGSize(width: 560, height: 470)) { OnboardingView(model: welcome) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(NSApp.windows.contains { $0.identifier?.rawValue == "welcome" && $0.isVisible }, "the welcome window opens")
        presenter.close("welcome")
        // Closing and reopening at once gives a new window, not the old one.
        let firstTutorial = TutorialModel(settings: settings)
        presenter.show("tutorial", title: "Tutorial", size: CGSize(width: 520, height: 250), floating: true) { TutorialView(model: firstTutorial) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let oldWindow = NSApp.windows.first { $0.identifier?.rawValue == "tutorial" && $0.isVisible }
        presenter.close("tutorial")
        let secondTutorial = TutorialModel(settings: settings)
        presenter.show("tutorial", title: "Tutorial", size: CGSize(width: 520, height: 250), floating: true) { TutorialView(model: secondTutorial) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let newWindow = NSApp.windows.first { $0.identifier?.rawValue == "tutorial" && $0.isVisible }
        check(newWindow != nil && newWindow !== oldWindow && newWindow?.contentViewController != nil,
              "reopening the tutorial shows a fresh window that stays filled")
        presenter.close("tutorial")
        settings.remove(SettingsKeys.wheelLayout.name)

        // The before/after close-up appears beside JPG for a photo.
        await show()
        wheel.dragPointer(at: segment(1))
        for _ in 0..<20 where !wheel.isLoupeVisible { try? await Task.sleep(nanoseconds: 100_000_000) }
        check(wheel.isLoupeVisible, "hovering JPG shows the before/after close-up")
        wheel.dragPointer(at: segment(5)) // Resize: nothing to compare
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(!wheel.isLoupeVisible, "it goes away on Resize, which has none")
        wheel.hide(animated: false)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 2. Drop on the centre cancels.
        await show()
        wheel.dragPointer(at: point(.zero))
        let cancelled = wheel.performDrop(info, at: point(.zero))
        check(!cancelled, "drop on the centre is refused (nothing happens)")
        check(finished?.action == nil && finished != nil, "centre reports Cancel")
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 3. Rest on More while the pointer reports ~60×/s (like a real drag),
        //    then drop on the first fan chip.
        await show()
        for _ in 0..<25 {
            wheel.dragPointer(at: segment(3))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        check(wheel.isFanOpen, "resting on More with continuous pointer updates opens the fan")
        let fanCount = SlotProvider.menu(for: [.heic], canWrite: { FormatSupport.current.canWrite($0) }).fan.count
        let chip = point(g.fanOffsets(count: fanCount, flipped: false)[0])
        wheel.dragPointer(at: chip)
        _ = wheel.performDrop(info, at: chip)
        check(finished?.action != nil && finished?.action != .more, "fan chip drop chooses a fan action (got \(finished?.label ?? "nothing"))")
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 4. Moving well outside dismisses while the drag continues.
        await show()
        wheel.dragPointer(at: segment(0))
        wheel.dragPointer(at: point(CGPoint(x: 0, y: -330)))
        check(dismissed, "moving away dismisses the wheel")
        check(finished == nil, "dismissing chooses nothing")
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(!wheel.isVisible, "wheel is hidden after dismissal")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        print("Memory 1 s after the wheel hid: \(MemoryFootprint.megabytes)")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        MemoryFootprint.relieve()
        print("Memory settled (idle again): \(MemoryFootprint.megabytes)")

        // 5. If the system never delivers the drop: the sampler's pointer
        //    positions plus mouse-up still choose the hovered segment.
        await show()
        func screenPoint(_ i: Int) -> CGPoint {
            let o = WheelGeometry.offset(radius: 150, angle: WheelGeometry.midAngle(ofSlot: i))
            return CGPoint(x: center.x + o.x, y: center.y - o.y)
        }
        wheel.trackDrag(screenPoint: screenPoint(0))
        wheel.dragEnded(screenPoint: screenPoint(0))
        try? await Task.sleep(nanoseconds: 700_000_000)
        check(finished?.action == .convert(.png) && finished?.files == [file],
              "release over PNG without a delivered drop still converts to PNG (got \(finished?.label ?? "nothing"))")

        // 6. Click mode (⌃⌥C, Open With): hover then click a segment.
        finished = nil
        wheel.show(DraggedFiles(urls: [file]), at: center, mode: .click)
        try? await Task.sleep(nanoseconds: 350_000_000)
        wheel.clickPointer(at: segment(1))
        wheel.click(at: segment(1))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(finished?.action == .convert(.jpg), "click mode: clicking JPG chooses JPG (got \(finished?.label ?? "nothing"))")

        // Text from a picture, through JobCenter exactly as the Text button runs it.
        do {
            let sign = file.deletingLastPathComponent().appendingPathComponent("Sign.png")
            let ctx = CGContext(data: nil, width: 2400, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 2400, height: 900))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Meeting moved to Thursday 4 pm",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 110), .foregroundColor: NSColor.black]))
            ctx.textPosition = CGPoint(x: 80, y: 400); CTLineDraw(line, ctx)
            if let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: sign)
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Circularity-Text-test-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var policy = OutputPolicy(destination: .folder(folder))
            policy.fallbackFolder = folder
            var text: String?
            var failed: String?
            let textJobs = JobCenter(settings: settings, history: HistoryStore(file: "dragtest-history.json"), stats: StatsStore(file: "dragtest-stats.json"))
            let started = Date()
            textJobs.run(.recognizeText, files: [sign], label: "copyText", policy: policy, interactive: false, record: false) { result in
                switch result {
                case let .success(r): text = r.outputs.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                case let .failure(e): failed = e.localizedDescription
                }
            }
            for _ in 0..<300 where text == nil && failed == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            check(text?.contains("Thursday") == true,
                  String(format: "Text: read in %.1f s (%@)", Date().timeIntervalSince(started), text ?? failed ?? "timed out after 30 s"))
            // Cancel must stop it at once, even mid-recognition.
            text = nil; failed = nil
            textJobs.run(.recognizeText, files: [sign], label: "copyText", policy: policy, interactive: false, record: false) { result in
                if case let .failure(e) = result { failed = "\(type(of: e))" } else { text = "finished" }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            textJobs.cancelAll()
            for _ in 0..<50 where text == nil && failed == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            check(failed == "CancellationError" || text == "finished", "Text: Cancel stops it (\(failed ?? text ?? "still running after 5 s"))")
            check(textJobs.active.isEmpty, "Text: nothing left running after Cancel")
            try? FileManager.default.removeItem(at: folder)
        }

        // 7. Three wheels: open Tools, switch to Actions mid-drag, drop on Copy path.
        try? await Task.sleep(nanoseconds: 400_000_000)
        finished = nil
        wheel.show(DraggedFiles(urls: [file]), at: center, mode: .drag, kind: .tools)
        try? await Task.sleep(nanoseconds: 350_000_000)
        check(wheel.kind == .tools, "the Tools key opens the Tools wheel")
        check(wheel.keyGuideLit == .tools, "the key guide lights Tools")
        wheel.dragPointer(at: segment(1))
        wheel.switchTo(.actions)
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(wheel.kind == .actions && wheel.isVisible, "another wheel's key switches in place")
        check(wheel.keyGuideLit == .actions, "the key guide above the wheel lights Actions (\(String(describing: wheel.keyGuideLit)))")
        _ = wheel.performDrop(info, at: segment(4))
        check(finished?.action == .file(.copyPath), "Actions: drop on Path chooses Copy path (got \(finished?.label ?? "nothing"))")
        check(FileActionPerformer.paths([file, folderOf(file)]) == "\(file.path)\n\(folderOf(file).path)", "Copy path: one full path per line")
        check(FileActionPerformer.folders([file, folderOf(file)]) == [folderOf(file).standardizedFileURL],
              "Terminal opens the file's folder once, even with the folder too")
        let taken: Set<String> = [folderOf(file).appendingPathComponent("IMG_2041.heic").path, folderOf(file).appendingPathComponent("IMG_2041 2.heic").path]
        check(FileActionPerformer.freeDestination(for: file, in: folderOf(file), exists: taken.contains).lastPathComponent == "IMG_2041 3.heic",
              "Move/Copy to a folder never overwrites (IMG_2041 3.heic)")
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Click mode: a wheel key switches too.
        finished = nil
        wheel.show(DraggedFiles(urls: [file]), at: center, mode: .click)
        try? await Task.sleep(nanoseconds: 350_000_000)
        wheel.modifiersChanged(.control)
        check(wheel.kind == .actions, "click mode: ⌃ switches to Actions")
        wheel.modifiersChanged([])
        wheel.modifiersChanged(.command)
        check(wheel.kind == .tools, "click mode: ⌘ switches to Tools")
        wheel.cancelFromKeyboard()
        try? await Task.sleep(nanoseconds: 400_000_000)

        // A folder: Convert says what to do; Actions works.
        let folder = file.deletingLastPathComponent()
        wheel.show(DraggedFiles(urls: [folder]), at: center, mode: .drag)
        try? await Task.sleep(nanoseconds: 300_000_000)
        wheel.switchTo(.actions)
        finished = nil
        _ = wheel.performDrop(SimulatedDrag(file: folder), at: segment(0))
        check(finished?.action == .file(.airDrop) && finished?.files == [folder], "a folder can be AirDropped from the Actions wheel")
        try? await Task.sleep(nanoseconds: 400_000_000)

        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: "\(AppIdentity.bundleID).dragtest")
        return failures == 0
    }

    private static func folderOf(_ url: URL) -> URL { url.deletingLastPathComponent() }

    private static func writeSampleHEIC() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-DragTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("IMG_2041.heic")
        guard let image = samplePicture(size: 256, scale: 1),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}

/// A minimal NSDraggingInfo carrying one file URL on a private pasteboard.
private final class SimulatedDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    init(file: URL) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("\(AppIdentity.bundleID).dragtest.\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects([file as NSURL])
        super.init()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
