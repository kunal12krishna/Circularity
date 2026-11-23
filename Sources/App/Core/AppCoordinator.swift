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
    private let shelf = DropShelf()
    private lazy var fileActions = FileActionPerformer(shelf: shelf) { [weak self] in
        self.map { Appearance.accentNS($0.settings) } ?? .systemPink
    }
    private let trimWindow = TrimWindow()
    private lazy var updates = UpdateChecker(settings: settings)
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
            if open { self?.updates.checkIfDue() }
            self?.statusItem?.setHighlighted(open)
            if open { self?.jobs.lastError = nil }
            self?.refreshIcon()
        }

        wheel.prepare()
        wheel.onFinished = { [weak self] choice in self?.handle(choice) }
        wheel.onShown = { [weak self] in
            self?.tutorial?.wheelShown()
            self?.shelf.hide() // a new wheel: the last result card makes way (and lets go of Esc)
        }
        fileActions.record = { [weak self] item in self?.jobs.history.add(item) }
        shelf.onUndo = { [weak self] outputs in
            guard let self else { return nil }
            if let item = jobs.history.item(writing: outputs) { return jobs.history.undo(item.id) }
            NSWorkspace.shared.recycle(outputs) { _, _ in }
            return nil
        }
        wheel.onSwitched = { [weak self] kind in self?.tutorial?.wheelSwitched(kind) }
        shelf.onTurnOff = { [weak self] in
            guard let self else { return }
            settings.set(false, for: SettingsKeys.afterShelf)
            panelModel.notice = "The result card is off. Turn it back on in Settings → Output."
            Log.app.notice("Result card turned off from its menu")
        }
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
            let accent = Appearance.accentNS(settings)
            switch event.result {
            case let .success(r):
                tutorial?.jobFinished(r)
                if event.interactive, !r.outputs.isEmpty, settings.value(SettingsKeys.afterShelf) {
                    // Undo puts the result in the Trash and brings back an original that went there.
                    let oneToOne = r.outputs.count == r.outcomes.filter { !$0.outputs.isEmpty }.count
                    shelf.show(r.outputs, accent: accent, bytesIn: oneToOne ? r.outcomes.filter { !$0.outputs.isEmpty }.reduce(0) { $0 + $1.bytesIn } : nil,
                               undoable: true)
                } else if event.interactive, r.outputs.isEmpty, let note = r.notes.first {
                    // Nothing written (already small, say): say so where the user is looking.
                    let detail = note.hasPrefix("Kept the original: ") ? String(note.dropFirst("Kept the original: ".count)) : note
                    shelf.showMessage("Kept the original", detail.prefix(1).uppercased() + detail.dropFirst(),
                                      original: r.outcomes.first?.inputs.first, accent: accent)
                }
            case let .failure(error) where !(error is CancellationError):
                if event.interactive { shelf.showMessage("Couldn't do that", error.localizedDescription, original: nil, accent: accent) }
            default:
                break
            }
        }.store(in: &bag)
        jobs.milestones.receive(on: RunLoop.main).sink { [weak self] ids in
            guard let self, let id = ids.last else { return }
            let title = ids.map(Milestone.title).joined(separator: "! ✦ ")
            panelModel.notice = "✦ \(title)! \(Self.milestoneLine(stats: jobs.stats))"
            statusItem?.set(.done)
            if settings.value(SettingsKeys.notifyEnabled) {
                Notifier.shared.post(title: "✦ \(title)", body: Self.milestoneLine(stats: jobs.stats), outputs: [],
                                     sound: settings.value(SettingsKeys.notifySound))
            }
            Log.app.notice("Milestone: \(id, privacy: .public)")
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
        updates.onAvailable = { [weak self] feed, automatic in
            guard let self else { return }
            panelModel.notice = UpdateInstaller.canInstall(feed)
                ? "Version \(feed.version) is available. Settings → General → Install and relaunch."
                : "Version \(feed.version) is available. Settings → General → Updates."
            #if DEBUG
            // Testing only: install straight away from a local feed.
            if ProcessInfo.processInfo.environment["CIRCULARITY_AUTO_INSTALL"] == "1" {
                updates.installer.install(feed, allowInsecureURL: true)
                return
            }
            #endif
            if automatic, settings.value(SettingsKeys.notifyEnabled) {
                Notifier.shared.post(title: "\(AppIdentity.name) \(feed.version) is available", body: feed.notes ?? "Open Settings → General to download it.",
                                     outputs: [], sound: false)
            }
        }
        updates.checkIfDue()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CIRCULARITY_UPDATE_FEED"] != nil { updates.check() }
        #endif
        // Text from pictures: macOS prepares its accurate reader once (about a
        // minute, in the background); until then Text uses the instant fast reader.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { TextReader.prepare() }
        if !settings.value(SettingsKeys.onboardingCompleted) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.settingsShowOnboarding() }
        } else if WhatsNew.shouldShow(lastSeen: settings.value(SettingsKeys.lastSeenVersion), current: UpdateChecker.currentVersion) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showWhatsNew() }
        } else {
            settings.set(WhatsNew.minor(UpdateChecker.currentVersion), for: SettingsKeys.lastSeenVersion)
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

    static func milestoneLine(stats: StatsStore) -> String {
        "\(stats.allTimeFiles) files converted, \(ByteCountFormatter.string(fromByteCount: stats.allTimeSaved, countStyle: .file)) saved in all."
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
        tutorial?.chose(action, files: choice.files)
        if !choice.files.isEmpty { recentFiles = choice.files }
        switch action {
        case .compress, .resize, .crop, .trim, .fit, .password, .editPages, .speed, .social, .file(.rename):
            openDialog(action, files: choice.files)
        case .copyText:
            copyText(choice.files)
        case .stripLocation:
            jobs.run(Command.stripGPS, files: choice.files)
        case let .file(fileAction):
            fileActions.perform(fileAction, files: choice.files)
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
        item.onDragEnded = { [weak self] in self?.refreshIcon() }
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
        let types = files.map(DraggedFiles.type(of:))
        let kinds = Set(types.map(SlotProvider.kind(of:)))
        let media: Bool? = kinds == [.video] ? true : (kinds == [.audio] ? false : nil)
        switch action {
        case .fit:
            dialogs.present(FitDialog(files: files, accent: accent, onRun: run, onCancel: cancel), title: "Make it fit")
        case .password:
            let pdfs = files.filter { DraggedFiles.type(of: $0).conforms(to: .pdf) }
            guard !pdfs.isEmpty else { return }
            let locked = pdfs.filter(PDFTools.isEncrypted)
            if !locked.isEmpty, locked.count < pdfs.count {
                shelf.showMessage("Some have a password", "\(locked.count) of \(pdfs.count) PDFs are locked. Lock or unlock them in two goes.",
                                  original: locked.first, accent: Appearance.accentNS(settings))
                return
            }
            let unlock = !locked.isEmpty
            dialogs.present(PasswordDialog(files: pdfs, unlock: unlock, accent: accent, onRun: run, onCancel: cancel),
                            title: unlock ? "Unlock" : "Lock")
        case .editPages:
            guard let file = files.first, isPDF else { return }
            if PDFTools.isEncrypted(file) {
                shelf.showMessage("It has a password", "Unlock it first: Tools → Lock.", original: file, accent: Appearance.accentNS(settings))
                return
            }
            dialogs.present(PagesDialog(file: file, accent: accent, onRun: run, onCancel: cancel), title: "Pages")
        case .speed:
            dialogs.present(SpeedDialog(files: files, accent: accent, onRun: run, onCancel: cancel), title: "Speed")
        case .social:
            let pictures = files.filter { DraggedFiles.type(of: $0).conforms(to: .image) }
            guard !pictures.isEmpty else { return }
            dialogs.present(SocialCropDialog(files: pictures, accent: accent, onRun: { [weak self] shapes in
                guard let self else { return }
                dialogs.close()
                for shape in shapes { jobs.run(.smartCrop(shape), files: pictures, label: "social.\(shape.rawValue)") }
            }, onCancel: cancel), title: "Crop for social")
        case .file(.rename):
            dialogs.present(RenameDialog(files: files, accent: accent, onRename: { [weak self] pairs in
                self?.dialogs.close()
                self?.fileActions.rename(pairs)
            }, onCancel: cancel), title: "Rename")
        case .trim:
            guard let file = files.first, let media else { return }
            trimWindow.show(file, isVideo: media) { [weak self] start, end in
                self?.jobs.run(.trimMedia(start: start, end: end), files: [file], label: action.usageKey)
            }
        case .compress:
            let isOffice = files.allSatisfy(OfficeCompressor.canCompress)
            dialogs.present(CompressDialog(files: files, isPDF: isPDF, isOffice: isOffice, media: media, accent: accent,
                                           onRun: run, onCancel: cancel),
                            title: "Compress")
        case .resize:
            dialogs.present(ResizeDialog(files: files, isPDF: isPDF, accent: accent, onRun: run, onCancel: cancel), title: "Resize")
        case .crop:
            dialogs.present(CropDialog(files: files, isPDF: isPDF, accent: accent, onRun: run, onCancel: cancel), title: "Crop")
        default:
            break
        }
    }

    #if DEBUG
    /// Testing only: chooses a wheel button as if it were dropped on.
    func debugChoose(_ token: String, files: [URL]) {
        let action: WheelAction? = switch token {
        case "password": .password
        case "editPages": .editPages
        case "fit": .fit
        case "speed": .speed
        case "copyText": .copyText
        case "searchable": .searchable
        case "trim": .trim
        case "social": .social
        case "rename": .file(.rename)
        default: nil
        }
        guard let action else { return }
        handle(WheelChoice(action: action, label: token, files: files, count: files.count))
    }
    #endif

    // MARK: Copy text

    /// The words from pictures and scans, straight to the clipboard: the .txt
    /// is written to a private temporary folder, read, and thrown away.
    private func copyText(_ files: [URL]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-Text-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var policy = OutputPolicy(destination: .folder(folder))
        policy.fallbackFolder = folder
        jobs.run(.recognizeText, files: files, label: "copyText", policy: policy, interactive: false, record: false) { [weak self] result in
            defer { try? FileManager.default.removeItem(at: folder) }
            guard let self else { return }
            let accent = Appearance.accentNS(settings)
            switch result {
            case let .success(r):
                let texts = zip(r.outcomes, r.outcomes.map { $0.outputs.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } })
                    .compactMap { outcome, text in text.map { (outcome.inputs.first?.lastPathComponent ?? "", $0) } }
                guard !texts.isEmpty else {
                    shelf.showMessage("No text found", r.notes.first ?? "There are no words to read in that.", original: files.first, accent: accent)
                    return
                }
                let joined = texts.count == 1 ? texts[0].1 : texts.map { "\($0.0)\n\n\($0.1)" }.joined(separator: "\n\n———\n\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(joined, forType: .string)
                let lines = joined.split(whereSeparator: \.isNewline).count
                let first = joined.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                shelf.showMessage("Text copied", "\(lines) line\(lines == 1 ? "" : "s") · “\(first.prefix(48))”", original: files.first, accent: accent)
            case let .failure(error) where !(error is CancellationError):
                shelf.showMessage("No text found", error.localizedDescription, original: files.first, accent: accent)
            default:
                break
            }
        }
    }

    // MARK: Names

    private var triggerName: String { WheelKeyMap.displayName(settings.value(SettingsKeys.triggerKey)) }

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
        windows.show("welcome", title: "Welcome", size: CGSize(width: 560, height: 520)) { OnboardingView(model: model) }
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
    var settingsUpdates: UpdateChecker { updates }
    var settingsJobs: JobCenter { jobs }
}

// MARK: - Welcome and tutorial host

extension AppCoordinator: OnboardingHost {
    func onboardingFinished(launchAtLogin: Bool, finderShortcutTurnedOn: Bool, startTutorial: Bool) {
        settings.set(true, for: SettingsKeys.onboardingCompleted)
        settings.set(WhatsNew.minor(UpdateChecker.currentVersion), for: SettingsKeys.lastSeenVersion)
        settings.set(launchAtLogin, for: SettingsKeys.launchAtLogin)
        if launchAtLogin != (LoginItem.isEnabled || LoginItem.needsApproval) { LoginItem.set(launchAtLogin) }
        if finderShortcutTurnedOn { ServiceShortcut.offerFinderRelaunch() }
        windows.close("welcome")
        if startTutorial { settingsShowTutorial() }
    }

    func onboardingPracticeWheel() { settingsPracticeWheel() }

    /// Once per new version (0.4 → 0.5, not 0.5.0 → 0.5.1): what's new, with a way to try it.
    func showWhatsNew() {
        settings.set(WhatsNew.minor(UpdateChecker.currentVersion), for: SettingsKeys.lastSeenVersion)
        let accent = Color(nsColor: Appearance.accentNS(settings))
        windows.show("whatsnew", title: "What's new", size: CGSize(width: 560, height: 520)) {
            WhatsNewView(version: UpdateChecker.currentVersion, accent: accent, onTry: { [weak self] in
                self?.windows.close("whatsnew")
                self?.settingsShowTutorial()
                self?.tutorial?.step = .wheels
            }, onClose: { [weak self] in self?.windows.close("whatsnew") })
        }
    }

    func tutorialClose() {
        windows.close("tutorial")
        tutorial = nil
    }
}
