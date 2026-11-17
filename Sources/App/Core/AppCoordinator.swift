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
    private let hud = DevHUD()
    private var tutorial: TutorialModel?
    private var bag: Set<AnyCancellable> = []

    /// The most recent files handed to the app or dropped on the wheel: the
    /// target for ⌘K and preset tiles (PLAN.md A3).
    private(set) var recentFiles: [URL] = []
    private var lastDrag = "No file drag yet"
    /// When hover opened the panel: a click soon after shouldn't close it again.
    private var hoverOpenedAt: Date?

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
        wheel.onShown = { [weak self] in self?.tutorial?.wheelShown() }
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
        // Every finished job reports back in the panel (a command never ends silently).
        jobs.$lastSummary.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] summary in
            self?.panelModel.notice = "Last result: \(summary)"
        }.store(in: &bag)
        Notifier.shared.install()
        jobs.completed.receive(on: RunLoop.main).sink { [weak self] event in
            guard let self else { return }
            Notifier.shared.jobFinished(title: event.title, result: event.result, settings: settings)
            if case let .success(r) = event.result { tutorial?.jobFinished(r) }
        }.store(in: &bag)
        jobs.finished.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            WidgetBridge.update(stats: jobs.stats, history: jobs.history)
            if jobs.active.isEmpty { statusItem?.set(.done) }
        }.store(in: &bag)
        panelModel.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }.store(in: &bag)

        // ⌃⌥Space: the panel with ⌘K focused. ⌃⌥V: convert the clipboard (both rebindable).
        _ = applyHotkeys()
        if settings.value(SettingsKeys.pinned) { pinned.pin() }
        if settings.value(SettingsKeys.devHUD) { settingsSetDevHUD(true) }
        if !settings.value(SettingsKeys.onboardingCompleted) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.settingsShowOnboarding() }
        }

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

    /// Opening the app again shows the menu bar icon (even if it was hidden)
    /// and Settings.
    func handleReopen() {
        Log.app.notice("Reopen requested")
        if statusItem == nil {
            settings.set(true, for: SettingsKeys.showInMenuBar)
            installStatusItem()
        }
        showSettings()
    }

    // MARK: Shortcuts

    /// Registers the two global shortcuts from Settings; returns the ids that failed.
    private func applyHotkeys() -> Set<UInt32> {
        var failed: Set<UInt32> = []
        let pairs: [(UInt32, SettingsKey<String>, () -> Void)] = [
            (1, SettingsKeys.hotkeyPanel, { [weak self] in self?.panel.open(focusCommand: true) }),
            (2, SettingsKeys.hotkeyClipboard, { [weak self] in self?.panelClipboard(nil) }),
        ]
        for (id, key, action) in pairs {
            HotkeyCenter.shared.unregister(id: id)
            guard let spec = HotkeySpec(settings.value(key)), spec.isAllowed else { continue }
            if !HotkeyCenter.shared.register(id: id, keyCode: spec.keyCode, modifiers: spec.modifiers, action) { failed.insert(id) }
        }
        return failed
    }

    // MARK: Settings, welcome and tutorial

    func showSettings(_ page: SettingsPage? = nil) {
        panel.close(animated: false)
        let model = SettingsModel(store: settings)
        model.host = self
        if let page { model.page = page }
        windows.show("settings", title: "Settings", size: CGSize(width: 880, height: 680)) { SettingsView(model: model) }
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
        item.onClick = { [weak self] in
            guard let self else { return }
            if let t = hoverOpenedAt, Date().timeIntervalSince(t) < 1.5, panel.isOpen {
                hoverOpenedAt = nil
                return
            }
            hoverOpenedAt = nil
            panel.toggle()
        }
        item.menuBuilder = { [weak self] in self?.menuItems() ?? [] }
        item.onDragEntered = { [weak self] in
            guard let self, !panel.isOpen, settings.value(SettingsKeys.openOnDragOver) else { return }
            panel.open(dropMode: true)
        }
        item.onHover = { [weak self] in
            guard let self, !panel.isOpen, settings.value(SettingsKeys.openOnHover) else { return }
            hoverOpenedAt = Date()
            panel.open()
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

    func panelOpenSettings() { showSettings() }

    func panelTutorial() {
        panel.close(animated: false)
        settingsShowTutorial()
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

    // MARK: Right-click menu (everything else is in Settings)

    private var triggerName: String {
        switch settings.value(SettingsKeys.triggerKey) {
        case "option": "Option"
        case "control": "Control"
        default: "Shift"
        }
    }

    private func menuItems() -> [NSMenuItem] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var items: [NSMenuItem] = [
            .info("\(AppIdentity.name) \(version)"),
            .info(lastDrag),
        ]
        if let summary = jobs.lastSummary { items.append(.info("Last result: \(summary)")) }
        let paused = settings.value(SettingsKeys.paused)
        items += [
            .separator(),
            ActionMenuItem("Open Panel") { [weak self] in self?.panel.open() },
            ActionMenuItem("Settings…", key: ",") { [weak self] in self?.showSettings() },
            .separator(),
            ActionMenuItem("History…") { [weak self] in self?.panelShowHistory() },
            ActionMenuItem("Stats…") { [weak self] in self?.panelShowStats() },
            ActionMenuItem("Watch Folders…") { [weak self] in self?.panelShowWatch() },
            ActionMenuItem("Convert Clipboard (\(HotkeySpec(settings.value(SettingsKeys.hotkeyClipboard))?.display ?? "no shortcut"))") { [weak self] in
                self?.panelClipboard(nil)
            },
            ActionMenuItem("Practice Wheel") { [weak self] in self?.showTestWheel() },
            ActionMenuItem("Tutorial…") { [weak self] in self?.settingsShowTutorial() },
            .separator(),
            ActionMenuItem("Pause", checked: paused) { [weak self] in
                guard let self else { return }
                settings.set(!paused, for: SettingsKeys.paused)
            },
            .separator(),
        ]
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

// MARK: - Settings host

extension AppCoordinator: SettingsHost {
    func settingsApplyHotkeys() -> Set<UInt32> { applyHotkeys() }

    func settingsApplyStored(includingLoginItem: Bool) -> Set<UInt32> {
        settingsShowMenuBarIcon(settings.value(SettingsKeys.showInMenuBar))
        settingsSetDevHUD(settings.value(SettingsKeys.devHUD))
        if settings.value(SettingsKeys.pinned) != pinned.isPinned {
            if settings.value(SettingsKeys.pinned) {
                panel.close(animated: false)
                pinned.pin()
            } else {
                pinned.unpin()
            }
        }
        if includingLoginItem {
            let want = settings.value(SettingsKeys.launchAtLogin)
            if want != (LoginItem.isEnabled || LoginItem.needsApproval) { LoginItem.set(want) }
        }
        refreshIcon()
        return applyHotkeys()
    }

    func settingsSuspendHotkeys() {
        HotkeyCenter.shared.unregister(id: 1)
        HotkeyCenter.shared.unregister(id: 2)
    }

    func settingsShowMenuBarIcon(_ visible: Bool) {
        if visible {
            if statusItem == nil { installStatusItem() }
        } else {
            panel.close(animated: false)
            statusItem?.remove()
            statusItem = nil
        }
    }

    func settingsPracticeWheel() {
        if let practice = tutorial?.practice ?? PracticePicture.url {
            wheel.show(DraggedFiles(urls: [practice]), at: NSEvent.mouseLocation, mode: .click)
        }
    }

    func settingsShowOnboarding() {
        let model = OnboardingModel(settings: settings)
        model.host = self
        windows.show("welcome", title: "Welcome", size: CGSize(width: 560, height: 470)) { OnboardingView(model: model) }
    }

    func settingsShowTutorial() {
        windows.close("tutorial")
        let model = TutorialModel(settings: settings)
        model.host = self
        tutorial = model
        windows.show("tutorial", title: "Tutorial", size: CGSize(width: 520, height: 250), floating: true) { TutorialView(model: model) }
    }

    func settingsSetDevHUD(_ on: Bool) {
        if on {
            hud.lines = { [weak self] in
                guard let self else { return [] }
                return ["jobs \(jobs.active.count) · wheel \(wheel.isVisible ? "shown" : "hidden") · panel \(panel.isOpen ? "open" : "closed")",
                        lastDrag, "trigger \(triggerName) · \(settings.value(SettingsKeys.wheelLayout))"]
            }
            hud.show()
        } else {
            hud.hide()
        }
    }

    func settingsDiagnostics() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        let writable = SlotProvider.ringImageCandidates.filter { FormatSupport.current.canWrite($0) }.map(\.displayName)
        let settingsJSON = (try? settings.exportJSON()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        \(AppIdentity.name) \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(arch)
        Memory \(MemoryFootprint.megabytes) · jobs running \(jobs.active.count)
        Image formats written: \(writable.joined(separator: ", "))
        Launch at login: \(LoginItem.status.rawValue) · ⌃⌥C service: \(ServiceShortcut.isInstalled ? "on" : "off")
        Watch folders: \(watch.rules.count) (\(watch.rules.filter(\.enabled).count) on)
        \(lastDrag)

        Settings:
        \(settingsJSON)
        """
    }

    var settingsWatch: WatchFolderService { watch }
    var settingsJobs: JobCenter { jobs }
}

// MARK: - Welcome and tutorial host

extension AppCoordinator: OnboardingHost {
    func onboardingFinished(launchAtLogin: Bool, finderShortcutTurnedOn: Bool, startTutorial: Bool) {
        settings.set(true, for: SettingsKeys.onboardingCompleted)
        settings.set(launchAtLogin, for: SettingsKeys.launchAtLogin)
        if launchAtLogin != (LoginItem.isEnabled || LoginItem.needsApproval) { LoginItem.set(launchAtLogin) }
        if finderShortcutTurnedOn { ServiceShortcut.offerFinderRelaunch() }
        windows.close("welcome")
        if startTutorial { settingsShowTutorial() }
    }

    func onboardingPracticeWheel() { settingsPracticeWheel() }

    func tutorialClose() {
        windows.close("tutorial")
        tutorial = nil
    }
}
