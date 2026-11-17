import AppKit
import Carbon.HIToolbox
import CircularityEngine
import Combine
import SwiftUI

/// Where files handed to the app came from.
enum FileSource: String {
    case launch, openEvent, handOff, service, statusIcon
}

/// The composition root (PLAN.md §1): owns every long-lived controller and
/// builds the heavy ones lazily.
final class AppCoordinator: PanelHost {
    let settings: SettingsStore
    private var statusItem: StatusItemController?
    private let wheel: WheelController
    private let gesture: GestureController
    private let services = ServicesProvider()
    private let jobs: JobCenter
    private let watch: WatchFolderService
    private let panelModel: PanelModel
    private let panel: MenuPanelController
    private let pinned: PinnedPanelController
    private let dialogs = DialogPresenter()
    private let windows = WindowPresenter()
    private var bag: Set<AnyCancellable> = []

    /// The most recent files handed to the app or dropped on the wheel: the
    /// target for ⌘K and preset tiles (PLAN.md A3).
    private(set) var recentFiles: [URL] = []
    private var lastDrag = "No file drag yet"

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        wheel = WheelController(settings: settings)
        gesture = GestureController(settings: settings, wheel: wheel)
        jobs = JobCenter(settings: settings)
        watch = WatchFolderService(settings: settings, jobs: jobs)
        panelModel = PanelModel(jobs: jobs, watch: watch, settings: settings)
        panel = MenuPanelController(model: panelModel, settings: settings)
        pinned = PinnedPanelController(model: panelModel, settings: settings)
    }

    func start() {
        panelModel.host = self
        if settings.value(SettingsKeys.showInMenuBar) { installStatusItem() }
        panel.anchor = { [weak self] in self?.statusItem?.screenFrame }
        panel.onOpenChange = { [weak self] open in
            self?.statusItem?.setHighlighted(open)
            if open { self?.jobs.lastError = nil }
            self?.refreshIcon()
        }

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

        // Icon state follows jobs, results, errors and Pause.
        jobs.$active.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshIcon() }.store(in: &bag)
        jobs.$lastError.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshIcon() }.store(in: &bag)
        jobs.finished.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            WidgetBridge.update(stats: jobs.stats, history: jobs.history)
            if jobs.active.isEmpty { statusItem?.set(.done) }
        }.store(in: &bag)
        panelModel.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }.store(in: &bag)

        // ⌃⌥Space: the panel with ⌘K focused. ⌃⌥V: convert the clipboard.
        HotkeyCenter.shared.register(id: 1, keyCode: kVK_Space, modifiers: HotkeyCenter.controlOption) { [weak self] in
            self?.panel.open(focusCommand: true)
        }
        HotkeyCenter.shared.register(id: 2, keyCode: kVK_ANSI_V, modifiers: HotkeyCenter.controlOption) { [weak self] in
            self?.panelClipboard(nil)
        }
        if settings.value(SettingsKeys.pinned) { pinned.pin() }

        Log.app.notice("\(AppIdentity.name, privacy: .public) started (pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public))")
    }

    func receive(_ urls: [URL], from source: FileSource) {
        guard !urls.isEmpty else { return }
        recentFiles = urls
        Log.app.notice("Received \(urls.count, privacy: .public) file(s) via \(source.rawValue, privacy: .public): \(urls.map(\.lastPathComponent).joined(separator: ", "), privacy: .private)")
        // Files handed over by Open, Open With, a second launch, the Service or
        // the menu bar icon open the wheel in click mode at the pointer.
        panel.close(animated: false)
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
        guard let action = choice.action else { return }
        if !choice.files.isEmpty { recentFiles = choice.files }
        switch action {
        case .compress, .resize, .crop:
            openDialog(action, files: choice.files)
        default:
            jobs.run(action, files: choice.files)
        }
    }

    // MARK: Status icon

    private func installStatusItem() {
        let item = StatusItemController()
        item.onClick = { [weak self] in self?.panel.toggle() }
        item.menuBuilder = { [weak self] in self?.menuItems() ?? [] }
        item.onDragEntered = { [weak self] in
            guard let self, !panel.isOpen else { return }
            panel.open(dropMode: true)
        }
        item.onFilesDropped = { [weak self] urls in self?.receive(urls, from: .statusIcon) }
        statusItem = item
        refreshIcon()
    }

    private func refreshIcon() {
        guard let item = statusItem else { return }
        item.style = StatusIconStyle(rawValue: settings.value(SettingsKeys.iconStyle)) ?? .monochrome
        item.accent = panelModel.accentNS
        item.showPercent = settings.value(SettingsKeys.showPercent)
        if item.state == .dragOver { return }
        if let progress = jobs.overallProgress {
            item.set(.converting(progress))
        } else if jobs.lastError != nil {
            item.set(.error)
        } else if settings.value(SettingsKeys.paused) {
            item.set(.paused)
        } else if item.state != .done {
            item.set(.idle)
        }
    }

    // MARK: PanelHost

    func panelTargetFiles() -> [URL] { recentFiles.filter { FileManager.default.fileExists(atPath: $0.path) } }

    func panelChooseFiles(_ then: @escaping ([URL]) -> Void) {
        panel.close(animated: false)
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.prompt = "Choose"
        open.message = "Choose files to convert"
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        recentFiles = open.urls
        then(open.urls)
    }

    func panelOpenWheel(files: [URL]) {
        receive(files, from: .openEvent)
    }

    func panelOpenDialog(_ action: WheelAction, files: [URL]) {
        panel.close(animated: false)
        recentFiles = files
        openDialog(action, files: files)
    }

    func panelSettingsMenu() -> [NSMenuItem] { menuItems() }

    func panelOpenSettings() {
        let menu = NSMenu()
        for item in menuItems() { menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func panelTutorial() {
        panel.close(animated: false)
        showTestWheel()
    }

    func panelTogglePin() {
        if pinned.isPinned {
            pinned.unpin()
        } else {
            panel.close(animated: false)
            pinned.pin()
        }
    }

    func panelClose() { panel.close() }

    func panelShowHistory() {
        panel.close(animated: false)
        windows.show("history", title: "History", size: CGSize(width: 520, height: 600)) { HistoryWindowView(model: panelModel) }
    }

    func panelShowStats() {
        panel.close(animated: false)
        windows.show("stats", title: "Stats", size: CGSize(width: 560, height: 560)) { StatsWindowView(model: panelModel) }
    }

    func panelShowWatch() {
        panel.close(animated: false)
        windows.show("watch", title: "Watch Folders", size: CGSize(width: 580, height: 480)) {
            WatchFoldersView(watch: watch, accent: panelModel.accent)
        }
    }

    func panelClipboard(_ format: OutputFormat?) {
        ClipboardConverter.convert(to: format, jobs: jobs) { [weak self] message in
            self?.panelModel.notice = message
            Log.app.notice("Clipboard: \(message, privacy: .public)")
        }
    }

    // MARK: Tool dialogs (milestone g)

    private func openDialog(_ action: WheelAction, files: [URL]) {
        guard !files.isEmpty else { return }
        let isPDF = files.allSatisfy { DraggedFiles.type(of: $0).conforms(to: .pdf) }
        let accent = panelModel.accent
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

    // MARK: Settings menu (until the Settings window in milestone i)

    private var triggerName: String {
        switch settings.value(SettingsKeys.triggerKey) {
        case "option": "Option"
        case "control": "Control"
        default: "Shift"
        }
    }

    private func choiceMenu(_ title: String, _ options: [(String, String)], current: String, set: @escaping (String) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (id, name) in options { menu.addItem(ActionMenuItem(name, checked: current == id) { set(id) }) }
        item.submenu = menu
        return item
    }

    private func toggle(_ title: String, _ key: SettingsKey<Bool>) -> NSMenuItem {
        ActionMenuItem(title, checked: settings.value(key)) { [weak self] in
            guard let self else { return }
            settings.set(!settings.value(key), for: key)
            panelModel.objectWillChange.send()
        }
    }

    private func menuItems() -> [NSMenuItem] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let s = settings
        let refresh: () -> Void = { [weak self] in self?.panelModel.objectWillChange.send(); self?.refreshIcon() }
        var items: [NSMenuItem] = [
            .info("\(AppIdentity.name) \(version)"),
            .info(lastDrag),
        ]
        if let summary = jobs.lastSummary { items.append(.info("Last result: \(summary)")) }
        items += [
            .separator(),
            ActionMenuItem("Open Panel", key: "") { [weak self] in self?.panel.open() },
            ActionMenuItem("History…") { [weak self] in self?.panelShowHistory() },
            ActionMenuItem("Stats…") { [weak self] in self?.panelShowStats() },
            ActionMenuItem("Watch Folders…") { [weak self] in self?.panelShowWatch() },
            ActionMenuItem("Convert Clipboard (⌃⌥V)") { [weak self] in self?.panelClipboard(nil) },
            ActionMenuItem("Practice Wheel") { [weak self] in self?.showTestWheel() },
            .separator(),
            choiceMenu("Wheel Layout", [("halo", "Halo"), ("ring", "Ring"), ("orbit", "Orbit")], current: s.value(SettingsKeys.wheelLayout)) {
                s.set($0, for: SettingsKeys.wheelLayout); refresh()
            },
            choiceMenu("Halo Accent", [("#C6FF3D", "Neon Lime"), ("#FF8A00", "Tangerine"), ("#5CE1FF", "Cyan"), ("#FF5CA8", "Pink")],
                       current: s.value(SettingsKeys.haloAccentHex)) { s.set($0, for: SettingsKeys.haloAccentHex); refresh() },
            choiceMenu("Trigger Key", [("shift", "Shift"), ("option", "Option"), ("control", "Control")], current: s.value(SettingsKeys.triggerKey)) {
                s.set($0, for: SettingsKeys.triggerKey)
            },
            toggle("Shake to Open", SettingsKeys.shakeEnabled),
            .separator(),
            choiceMenu("Panel Layout", [("stackPlus", "Stack+"), ("tabs", "Tabs"), ("mini", "Mini")], current: s.value(SettingsKeys.panelLayout)) {
                s.set($0, for: SettingsKeys.panelLayout); refresh()
            },
            choiceMenu("Panel Width", [("s", "Small"), ("m", "Medium"), ("l", "Large")], current: s.value(SettingsKeys.panelWidth)) {
                s.set($0, for: SettingsKeys.panelWidth)
            },
            choiceMenu("Recent Items", [("5", "5"), ("10", "10"), ("25", "25")], current: "\(s.value(SettingsKeys.recentsCount))") {
                s.set(Int($0) ?? 5, for: SettingsKeys.recentsCount); refresh()
            },
            choiceMenu("Preset Grid", [("3x1", "3 × 1"), ("3x2", "3 × 2"), ("4x2", "4 × 2")], current: s.value(SettingsKeys.presetGrid)) {
                s.set($0, for: SettingsKeys.presetGrid); refresh()
            },
            choiceMenu("Menu Bar Icon", [("monochrome", "Monochrome"), ("colour", "Colour"), ("minimal", "Minimal")], current: s.value(SettingsKeys.iconStyle)) {
                s.set($0, for: SettingsKeys.iconStyle); refresh()
            },
            toggle("Show Percentage While Converting", SettingsKeys.showPercent),
            choiceMenu("Pinned Panel Size", [("s", "Small"), ("m", "Medium"), ("l", "Large")], current: s.value(SettingsKeys.pinnedSize)) { [weak self] in
                self?.pinned.setSize($0)
            },
            ActionMenuItem("Pinned Panel Ignores Clicks", checked: s.value(SettingsKeys.pinnedClickThrough)) { [weak self] in
                self?.pinned.toggleClickThrough()
            },
            .separator(),
        ]
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
        items.append(toggle("Pause", SettingsKeys.paused))
        items.append(.separator())
        let quit = NSMenuItem(title: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        items.append(quit)
        return items
    }

    /// Click-mode wheel on the last files, or a generated practice picture.
    private func showTestWheel() {
        var urls = panelTargetFiles()
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
