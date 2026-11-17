import AppKit
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
        let settings = SettingsStore(defaults: defaults)
        settings.set(false, for: SettingsKeys.smartOrdering)
        settings.set(false, for: SettingsKeys.haptics)
        let wheel = WheelController(settings: settings)
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print(ok ? "PASS  \(label)" : "FAIL  \(label)")
            if !ok { failures += 1 }
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
            jobs.history.clear()
            jobs.stats.reset()
        }

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

        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: "\(AppIdentity.bundleID).dragtest")
        return failures == 0
    }

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
