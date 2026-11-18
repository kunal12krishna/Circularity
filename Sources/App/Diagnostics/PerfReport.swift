import AppKit
import CircularityEngine
import PDFKit
import UniformTypeIdentifiers

/// `--perf-report [file.md]` (PLAN.md §5): measures the budgets on this Mac
/// and writes a Markdown report. It starts the real app at idle (with
/// throwaway settings, so yours are untouched), then the wheel, the panel,
/// the Settings window and two large jobs.
enum PerfReport {
    static func run(to path: URL?) {
        setvbuf(stdout, nil, _IONBF, 0) // progress lines appear at once, even in a pipe
        Task { @MainActor in
            let report = await measure()
            if let path {
                try? report.write(to: path, atomically: true, encoding: .utf8)
                print("Wrote \(path.path)")
            } else {
                print(report)
            }
            exit(0)
        }
    }

    private static func mb(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        MemoryFootprint.relieve()
    }

    /// User + system CPU seconds used by this process so far.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    /// The highest physical footprint so far (macOS keeps the peak).
    private static func peakFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.ledger_phys_footprint_peak > 0 ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint : 0
    }

    @MainActor
    private static func measure() async -> String {
        var rows: [(String, String, String)] = [] // measure, value, budget / note
        func row(_ name: String, _ value: String, _ note: String = "") {
            rows.append((name, value, note))
            print("\(name): \(value)\(note.isEmpty ? "" : " — \(note)")")
        }

        // Launch: from the kernel's process start to the app being ready.
        let suite = "\(AppIdentity.bundleID).perfreport"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, suiteName: suite)
        settings.set(true, for: SettingsKeys.onboardingCompleted)
        let coordinator = AppCoordinator(settings: settings)
        coordinator.start()
        if let start = SingleInstance.startTime(of: getpid()) {
            let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
            row("Launch to ready", String(format: "%.0f ms", (Date().timeIntervalSince1970 - started) * 1000), "process start → menu bar icon and gesture ready")
        }

        // Idle.
        await settle(3)
        let idle = MemoryFootprint.current()
        row("Idle memory after launch", mb(idle), idle < 25 * 1_048_576 ? "within the 25 MB budget" : "over the 25 MB budget")
        let cpu0 = cpuSeconds()
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        let idleCPU = (cpuSeconds() - cpu0) / 10 * 100
        row("Idle CPU (10 s sample)", String(format: "%.2f %%", idleCPU), idleCPU < 0.5 ? "≈ 0 %, as budgeted" : "above ≈ 0 %")

        // Wheel.
        let wheel = WheelController(settings: settings)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-Perf-\(UUID().uuidString).png")
        if let image = samplePicture(size: 1024, scale: 1),
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try? data.write(to: file) }
        defer { try? FileManager.default.removeItem(at: file) }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let center = CGPoint(x: screen.midX, y: screen.midY)
        for layout in ["halo", "ring", "orbit"] {
            settings.set(layout, for: SettingsKeys.wheelLayout)
            let t0 = CFAbsoluteTimeGetCurrent()
            wheel.show(DraggedFiles(urls: [file]), at: center, mode: .drag)
            CATransaction.flush()
            let showMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            try? await Task.sleep(nanoseconds: 500_000_000)
            // CIRCULARITY_PERF_HOLD=1 keeps each wheel up for 6 s, for `footprint <pid>`.
            if ProcessInfo.processInfo.environment["CIRCULARITY_PERF_HOLD"] != nil {
                print("HOLD \(layout) pid \(getpid())")
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
            let shown = MemoryFootprint.current()
            wheel.hide(animated: false)
            await settle(1)
            row("Wheel (\(layout.capitalized)): show", String(format: "%.0f ms, %@ while shown, %@ after hiding", showMS, mb(shown), mb(MemoryFootprint.current())),
                layout == "halo" ? "first show includes building the layer tree" : "")
        }

        // Panel.
        let jobs = JobCenter(settings: settings, history: HistoryStore(file: "perf-history-\(UUID().uuidString).json"),
                             stats: StatsStore(file: "perf-stats-\(UUID().uuidString).json"))
        let watch = WatchFolderService(settings: settings, jobs: jobs)
        let panelModel = PanelModel(jobs: jobs, watch: watch, settings: settings)
        let panel = MenuPanelController(model: panelModel, settings: settings)
        let before = MemoryFootprint.current()
        let tp = CFAbsoluteTimeGetCurrent()
        panel.open()
        CATransaction.flush()
        let openMS = (CFAbsoluteTimeGetCurrent() - tp) * 1000
        try? await Task.sleep(nanoseconds: 800_000_000)
        let open = MemoryFootprint.current()
        panel.close(animated: false)
        await settle(2)
        row("Menu bar panel", String(format: "opens in %.0f ms; %@ before, %@ open, %@ after closing", openMS, mb(before), mb(open), mb(MemoryFootprint.current())),
            "SwiftUI stays loaded once used")
        for _ in 0..<5 {
            panel.open()
            try? await Task.sleep(nanoseconds: 400_000_000)
            panel.close(animated: false)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        await settle(2)
        row("Panel after 5 more open/close rounds", mb(MemoryFootprint.current()), "no growth means no leak")

        // Settings window.
        let presenter = WindowPresenter()
        let model = SettingsModel(store: settings)
        presenter.show("settings", title: "Settings", size: CGSize(width: 880, height: 680)) { SettingsView(model: model) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        model.page = .appearance
        try? await Task.sleep(nanoseconds: 600_000_000)
        let settingsOpen = MemoryFootprint.current()
        presenter.close("settings")
        await settle(2)
        row("Settings window", "\(mb(settingsOpen)) open (Appearance page), \(mb(MemoryFootprint.current())) after closing",
            "SwiftUI/AppKit caches for a long page of controls stay loaded")
        for _ in 0..<3 {
            let again = SettingsModel(store: settings)
            presenter.show("settings", title: "Settings", size: CGSize(width: 880, height: 680)) { SettingsView(model: again) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            again.page = .appearance
            try? await Task.sleep(nanoseconds: 500_000_000)
            presenter.close("settings")
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await settle(2)
        row("Settings after 3 more open/close rounds", mb(MemoryFootprint.current()), "no growth means no leak")

        // Large jobs through the real engine.
        let engine = ConversionEngine()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-Perf-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = OutputPolicy(destination: .folder(dir), fallbackFolder: dir)
        let huge = dir.appendingPathComponent("huge.png")
        writeGradient(10_000, 10_000, to: huge)
        let base = MemoryFootprint.current()
        let tj = CFAbsoluteTimeGetCurrent()
        let hugeResult = try? await engine.run(JobRequest(inputs: [huge], operation: .convert(.jpg), output: policy))
        row("100 MP PNG → JPG", String(format: "%.1f s, peak %@ (%@ above idle)", CFAbsoluteTimeGetCurrent() - tj, mb(peakFootprint()),
                                       mb(peakFootprint() > base ? peakFootprint() - base : 0)),
            hugeResult?.outputs.isEmpty == false ? "" : "FAILED")
        let pdf = dir.appendingPathComponent("long.pdf")
        writeLongPDF(pages: 200, to: pdf)
        let tc = CFAbsoluteTimeGetCurrent()
        let pdfResult = try? await engine.run(JobRequest(inputs: [pdf], operation: .compressPDF(.balanced), output: policy))
        row("200-page PDF compress (balanced)", String(format: "%.1f s, peak %@ so far", CFAbsoluteTimeGetCurrent() - tc, mb(peakFootprint())),
            pdfResult.map { $0.outputs.isEmpty ? ($0.notes.first ?? "kept the original") : "smaller" } ?? "FAILED")
        await settle(3)
        row("Idle again after everything", mb(MemoryFootprint.current()))

        // Size on disk.
        let bundle = Bundle.main.bundleURL
        row("App bundle", sizeOnDisk(bundle) + " (" + (Bundle.main.executableURL.map { archs($0) } ?? "?") + ")")
        let dist = bundle.deletingLastPathComponent()
        for dmg in ((try? FileManager.default.contentsOfDirectory(at: dist, includingPropertiesForKeys: nil)) ?? []) where dmg.pathExtension == "dmg" {
            row("DMG \(dmg.lastPathComponent)", sizeOnDisk(dmg))
        }

        let mac = ProcessInfo.processInfo
        var text = "# Performance report\n\n"
        text += "Measured with `Circularity --perf-report` on \(Date().formatted(date: .abbreviated, time: .shortened)), "
        text += "macOS \(mac.operatingSystemVersionString), \(mac.processorCount) cores, \(mac.physicalMemory / 1_073_741_824) GB, "
        text += "\(bundle.path.contains("/Release/") || bundle.path.contains("/dist/") ? "Release" : "Debug") build.\n\n"
        text += "| Measure | Result | Note |\n|---|---|---|\n"
        for (a, b, c) in rows { text += "| \(a) | \(b) | \(c) |\n" }
        return text
    }

    private static func sizeOnDisk(_ url: URL) -> String {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        }
        if total == 0 { total = Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private static func archs(_ executable: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-archs", executable.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeGradient(_ w: Int, _ h: Int, to url: URL) {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [CGColor.hex(0x2B3242), CGColor.hex(0xFF8A00)] as CFArray, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func writeLongPDF(pages: Int, to url: URL) {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil), let photo = samplePicture(size: 800, scale: 1) else { return }
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
            if i % 2 == 0 { ctx.draw(photo, in: CGRect(x: 56, y: 300, width: 500, height: 420)) }
            ctx.setFillColor(.black)
            for line in 0..<20 { ctx.fill(CGRect(x: 56, y: 260 - line * 12, width: 400 + (line * 37 % 100), height: 6)) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
