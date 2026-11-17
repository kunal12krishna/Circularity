import AppKit
import CircularityEngine
import SwiftUI

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
    private let jobs: JobCenter
    private let dialogs = DialogPresenter()

    /// The most recent files handed to the app: the target for ⌃⌥C fallbacks,
    /// ⌘K and preset tiles in later milestones (PLAN.md A3).
    private(set) var recentFiles: [URL] = []
    private var lastDrag = "No file drag yet"
    private var lastChoice = "Nothing chosen yet"

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        wheel = WheelController(settings: settings)
        gesture = GestureController(settings: settings, wheel: wheel)
        jobs = JobCenter(settings: settings)
    }

    func start() {
        if settings.value(SettingsKeys.showInMenuBar) { installStatusItem() }

        wheel.prepare()
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
            switch action {
            case .compress, .resize, .crop:
                openDialog(action, files: choice.files)
            default:
                jobs.run(action, files: choice.files)
            }
        } else {
            lastChoice = "Last choice: Cancel (nothing changed)"
        }
    }

    // MARK: Tool dialogs (milestone g)

    private func openDialog(_ action: WheelAction, files: [URL]) {
        guard !files.isEmpty else { return }
        let isPDF = files.allSatisfy { DraggedFiles.type(of: $0).conforms(to: .pdf) }
        let accent = SwiftUI.Color(nsColor: NSColor(cgColor: wheelAccent) ?? .orange)
        let run: (CircularityEngine.Operation, Preset?) -> Void = { [weak self] operation, preset in
            guard let self else { return }
            dialogs.close()
            if let preset { jobs.addPreset(preset) }
            jobs.run(operation, files: files, label: action.usageKey)
        }
        let cancel: () -> Void = { [weak self] in self?.dialogs.close() }
        switch action {
        case .compress:
            dialogs.present(CompressDialog(files: files, isPDF: isPDF, accent: accent, onRun: run, onCancel: cancel), title: "Compress")
        case .resize:
            dialogs.present(ResizeDialog(files: files, isPDF: isPDF, accent: accent, onRun: run, onCancel: cancel), title: "Resize")
        case .crop:
            dialogs.present(CropDialog(files: files, isPDF: isPDF, accent: accent, onRun: run, onCancel: cancel), title: "Crop")
        default:
            break
        }
    }

    /// The accent the wheel is using (Halo's neon, or the theme accent).
    private var wheelAccent: CGColor {
        let layout = settings.value(SettingsKeys.wheelLayout)
        let hex = layout == "halo" ? settings.value(SettingsKeys.haloAccentHex) : settings.value(SettingsKeys.accentHex)
        return CGColor.hexString(hex) ?? .hex(0xC6FF3D)
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
        ]
        if jobs.runningCount > 0 {
            items.append(.info("Converting \(jobs.runningCount) job\(jobs.runningCount == 1 ? "" : "s")…"))
            items.append(ActionMenuItem("Cancel All") { [weak self] in self?.jobs.cancelAll() })
        }
        if let summary = jobs.lastSummary {
            items.append(.info("Last result: \(summary)"))
        }
        if !jobs.lastOutputs.isEmpty {
            items.append(ActionMenuItem("Reveal Last Result in Finder") { [weak self] in self?.jobs.revealLast() })
        }
        items += [
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

        let accent = NSMenuItem(title: "Halo Accent", action: nil, keyEquivalent: "")
        let accents = NSMenu()
        for (hex, name) in [("#C6FF3D", "Neon Lime"), ("#FF8A00", "Tangerine"), ("#5CE1FF", "Cyan"), ("#FF5CA8", "Pink")] {
            accents.addItem(ActionMenuItem(name, checked: settings.value(SettingsKeys.haloAccentHex) == hex) { [weak self] in
                self?.settings.set(hex, for: SettingsKeys.haloAccentHex)
            })
        }
        accent.submenu = accents
        items.append(accent)

        let trigger = NSMenuItem(title: "Trigger Key", action: nil, keyEquivalent: "")
        let triggers = NSMenu()
        for (id, name) in [("shift", "Shift"), ("option", "Option"), ("control", "Control")] {
            triggers.addItem(ActionMenuItem(name, checked: settings.value(SettingsKeys.triggerKey) == id) { [weak self] in
                self?.settings.set(id, for: SettingsKeys.triggerKey)
            })
        }
        trigger.submenu = triggers
        items.append(trigger)

        let saved = jobs.presets
        if !saved.isEmpty {
            let buttons = NSMenuItem(title: "Saved Wheel Buttons", action: nil, keyEquivalent: "")
            let list = NSMenu()
            for preset in saved {
                list.addItem(ActionMenuItem("Remove “\(preset.name)” (\(preset.applies == .pdfs ? "PDFs" : "images"))") { [weak self] in
                    self?.jobs.removePreset(id: preset.id)
                })
            }
            buttons.submenu = list
            items.append(buttons)
        }
        items.append(ActionMenuItem("Shake to Open", checked: settings.value(SettingsKeys.shakeEnabled)) { [weak self] in
            guard let self else { return }
            settings.set(!settings.value(SettingsKeys.shakeEnabled), for: SettingsKeys.shakeEnabled)
        })
        let installed = ServiceShortcut.isInstalled
        items.append(ActionMenuItem("⌃⌥C for Finder Selection", checked: installed) {
            if installed {
                ServiceShortcut.uninstall()
                ServiceShortcut.offerFinderRelaunch(turnedOn: false)
            } else if ServiceShortcut.install() {
                ServiceShortcut.offerFinderRelaunch()
            } else {
                ServiceShortcut.openKeyboardSettings()
            }
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
