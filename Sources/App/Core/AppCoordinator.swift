import AppKit

/// Where files handed to the app came from.
enum FileSource: String {
    case launch, openEvent, handOff, service
}

/// The composition root (PLAN.md §1): owns every long-lived controller and
/// builds the heavy ones lazily.
final class AppCoordinator {
    let settings: SettingsStore
    private var statusItem: StatusItemController?
    private let wheel: WheelController
    private let gesture: GestureController
    private let services = ServicesProvider()

    /// The most recent files handed to the app: the target for ⌃⌥C fallbacks,
    /// ⌘K and preset tiles in later milestones (PLAN.md A3).
    private(set) var recentFiles: [URL] = []
    private var lastDrag = "No file drag yet"
    private var lastChoice = "Nothing chosen yet"

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        wheel = WheelController(settings: settings)
        gesture = GestureController(settings: settings, wheel: wheel)
    }

    func start() {
        if settings.value(SettingsKeys.showInMenuBar) { installStatusItem() }

        wheel.onFinished = { [weak self] choice in self?.handle(choice) }
        gesture.onDragReport = { [weak self] report in
            let how = report.opened.map { $0 == .shake ? "opened by shake" : "opened by \(self?.triggerName ?? "Shift")" } ?? "not opened"
            self?.lastDrag = report.verdict == "allowed" ? "Last file drag: wheel \(how)" : "Last file drag: skipped (\(report.verdict))"
        }
        gesture.start()

        services.onFiles = { [weak self] urls in self?.receive(urls, from: .service) }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        Log.app.notice("\(AppIdentity.name, privacy: .public) started (pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public))")
    }

    func receive(_ urls: [URL], from source: FileSource) {
        guard !urls.isEmpty else { return }
        recentFiles = urls
        Log.app.notice("Received \(urls.count, privacy: .public) file(s) via \(source.rawValue, privacy: .public): \(urls.map(\.lastPathComponent).joined(separator: ", "), privacy: .private)")
        // Files handed over by Open, Open With, a second launch or the Service
        // open the wheel in click mode at the pointer (PLAN.md §3.3).
        wheel.show(DraggedFiles(urls: urls), at: NSEvent.mouseLocation, mode: .click)
    }

    /// Opening the app again shows the menu bar icon even if it was hidden.
    func handleReopen() {
        Log.app.notice("Reopen requested")
        if statusItem == nil {
            settings.set(true, for: SettingsKeys.showInMenuBar)
            installStatusItem()
        }
    }

    private func handle(_ choice: WheelChoice) {
        gesture.wheelFinished()
        if let action = choice.action {
            let names = choice.files.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
            let what = names.isEmpty ? "\(choice.count) item(s)" : names
            lastChoice = "Last choice: \(choice.label) — \(what)"
            // Milestone (d) runs the engine here.
            Log.app.notice("Chosen \(action.usageKey, privacy: .public) for \(choice.files.count, privacy: .public) file(s) (conversion arrives in milestone d)")
        } else {
            lastChoice = "Last choice: Cancel (nothing changed)"
        }
    }

    // MARK: Menu (temporary until the panel in milestone h)

    private var triggerName: String {
        switch settings.value(SettingsKeys.triggerKey) {
        case "option": "Option"
        case "control": "Control"
        default: "Shift"
        }
    }

    private func installStatusItem() {
        statusItem = StatusItemController { [weak self] in self?.menuItems() ?? [] }
    }

    private func menuItems() -> [NSMenuItem] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var items: [NSMenuItem] = [
            .info("\(AppIdentity.name) \(version)"),
            .info(settings.value(SettingsKeys.paused) ? "Paused · the wheel will not appear" : "Ready · drag a file, then tap \(triggerName) or shake"),
            .info(lastDrag),
            .info(lastChoice),
            .separator(),
            ActionMenuItem("Show Test Wheel") { [weak self] in self?.showTestWheel() },
        ]

        let layout = NSMenuItem(title: "Wheel Layout", action: nil, keyEquivalent: "")
        let layouts = NSMenu()
        for (id, name) in [("ring", "Ring"), ("orbit", "Orbit"), ("halo", "Halo")] {
            layouts.addItem(ActionMenuItem(name, checked: settings.value(SettingsKeys.wheelLayout) == id) { [weak self] in
                self?.settings.set(id, for: SettingsKeys.wheelLayout)
            })
        }
        layout.submenu = layouts
        items.append(layout)

        let trigger = NSMenuItem(title: "Trigger Key", action: nil, keyEquivalent: "")
        let triggers = NSMenu()
        for (id, name) in [("shift", "Shift"), ("option", "Option"), ("control", "Control")] {
            triggers.addItem(ActionMenuItem(name, checked: settings.value(SettingsKeys.triggerKey) == id) { [weak self] in
                self?.settings.set(id, for: SettingsKeys.triggerKey)
            })
        }
        trigger.submenu = triggers
        items.append(trigger)

        items.append(ActionMenuItem("Shake to Open", checked: settings.value(SettingsKeys.shakeEnabled)) { [weak self] in
            guard let self else { return }
            settings.set(!settings.value(SettingsKeys.shakeEnabled), for: SettingsKeys.shakeEnabled)
        })
        let installed = ServiceShortcut.isInstalled
        items.append(ActionMenuItem(installed ? "⌃⌥C Opens the Wheel for Finder Selection" : "Use ⌃⌥C for Finder Selection…",
                                    checked: installed) {
            if !ServiceShortcut.install() { ServiceShortcut.openKeyboardSettings() }
        })
        items.append(ActionMenuItem("Pause", checked: settings.value(SettingsKeys.paused)) { [weak self] in
            guard let self else { return }
            settings.set(!settings.value(SettingsKeys.paused), for: SettingsKeys.paused)
        })
        items.append(.separator())
        let quit = NSMenuItem(title: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        items.append(quit)
        return items
    }

    /// Click-mode wheel on the last files handed to the app, or a generated sample picture.
    private func showTestWheel() {
        var urls = recentFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty, let sample = Self.writeSamplePicture() { urls = [sample] }
        wheel.show(DraggedFiles(urls: urls), at: NSEvent.mouseLocation, mode: .click)
    }

    private static func writeSamplePicture() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-Sample", isDirectory: true)
        let url = dir.appendingPathComponent("Sample photo.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let image = samplePicture(size: 512, scale: 1),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
