import AppKit

/// Watches for file drags and opens the wheel on the trigger key or a shake
/// (PLAN.md §3.2). Uses only permission-free APIs:
/// - global NSEvent *mouse* monitors (always installed, event-driven, no CPU at rest);
/// - while the button is down after a move: a 60 Hz sampler reading
///   NSEvent.mouseLocation / modifierFlags / pressedMouseButtons and the drag
///   pasteboard's changeCount. It is torn down on mouse up.
final class GestureController {
    struct DragReport {
        var draggedEvents = 0
        var samples = 0
        var fileDrag = false
        var verdict = "—"
        var opened: WheelOpenReason?
        var items = 0
    }

    /// Called at the end of every drag that carried files (for the status menu).
    var onDragReport: ((DragReport) -> Void)?

    private let settings: SettingsStore
    private let wheel: WheelController
    private let policy: TriggerPolicy
    private var machine = GestureStateMachine()
    private var monitors: [Any] = []
    private var sampler: DispatchSourceTimer?
    private var pressChangeCount = 0
    private var checkedChangeCount = -1
    private var report = DragReport()
    private var selfCheckLogged = false

    init(settings: SettingsStore, wheel: WheelController) {
        self.settings = settings
        self.wheel = wheel
        policy = TriggerPolicy(settings: settings)
        wheel.onDragDismissed = { [weak self] in self?.wheelDismissed() }
    }

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouse(type) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: handler) {
            monitors.append(m)
        }
        Log.gesture.notice("Gesture monitors installed (global mouse events only, no event tap)")
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        stopSampling()
    }

    /// The wheel finished (drop or cancel) during a drag.
    func wheelFinished() {
        send(.wheelFinished)
    }

    // MARK: Events

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var triggerFlag: NSEvent.ModifierFlags {
        switch settings.value(SettingsKeys.triggerKey) {
        case "option": .option
        case "control": .control
        default: .shift
        }
    }

    private var triggerIsDown: Bool { NSEvent.modifierFlags.contains(triggerFlag) }

    private func handleMouse(_ type: NSEvent.EventType) {
        let location = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            refreshConfig()
            pressChangeCount = NSPasteboard(name: .drag).changeCount
            checkedChangeCount = pressChangeCount
            report = DragReport()
            send(.mouseDown(location, triggerDown: triggerIsDown, time: now))
        case .leftMouseDragged:
            report.draggedEvents += 1
            send(.mouseMoved(location, time: now))
            checkPasteboard()
        case .leftMouseUp:
            send(.mouseUp(time: now))
        default:
            break
        }
    }

    private func refreshConfig() {
        var config = GestureConfig()
        config.triggerMode = TriggerMode(rawValue: settings.value(SettingsKeys.triggerMode)) ?? .tap
        config.triggerDelay = Double(settings.value(SettingsKeys.triggerDelayMs)) / 1000
        config.shakeEnabled = settings.value(SettingsKeys.shakeEnabled)
        config.shake = ShakeDetector.Thresholds.named(settings.value(SettingsKeys.shakeSensitivity))
        machine.config = config
    }

    /// A new drag session writes the drag pasteboard; files or promises make it a file drag.
    private func checkPasteboard() {
        guard machine.phase == .pressed || machine.phase == .dragging else { return }
        let pasteboard = NSPasteboard(name: .drag)
        let count = pasteboard.changeCount
        guard count != pressChangeCount, count != checkedChangeCount else { return }
        checkedChangeCount = count
        guard DraggedFiles.hasFiles(pasteboard) else { return }
        let verdict = policy.evaluate()
        report.fileDrag = true
        report.verdict = verdict.reason
        if !selfCheckLogged {
            selfCheckLogged = true
            Log.gesture.notice("Gesture self-check: file drag detected without Accessibility/Input Monitoring (\(self.report.draggedEvents, privacy: .public) global drag events, \(self.report.samples, privacy: .public) samples so far)")
        }
        Log.gesture.notice("File drag detected: \(verdict.reason, privacy: .public)")
        send(.fileDragDetected(allowed: verdict.isAllowed, time: now))
    }

    private func sample() {
        report.samples += 1
        let t = now
        if NSEvent.pressedMouseButtons & 1 == 0 {
            send(.mouseUp(time: t))
            return
        }
        let location = NSEvent.mouseLocation
        send(.mouseMoved(location, time: t))
        if wheel.isVisible { wheel.trackDrag(screenPoint: location) }
        checkPasteboard()
        send(.triggerChanged(isDown: triggerIsDown, time: t))
        send(.tick(time: t))
    }

    private func wheelDismissed() {
        send(.wheelDismissed(triggerDown: triggerIsDown, time: now))
    }

    // MARK: Effects

    private func send(_ event: GestureEvent) {
        for effect in machine.handle(event) { perform(effect) }
    }

    private func perform(_ effect: GestureEffect) {
        switch effect {
        case .startSampling:
            startSampling()
        case .stopSampling:
            stopSampling()
            if report.fileDrag {
                Log.gesture.notice("Drag ended: \(self.report.draggedEvents, privacy: .public) global drag events, \(self.report.samples, privacy: .public) samples, wheel \(self.report.opened?.rawValue ?? "not opened", privacy: .public)")
                onDragReport?(report)
            }
        case let .showWheel(point, reason):
            let files = DraggedFiles.read(NSPasteboard(name: .drag))
            report.opened = reason
            report.items = files.count
            Log.gesture.notice("Opening wheel by \(reason.rawValue, privacy: .public) with \(files.count, privacy: .public) item(s)")
            wheel.show(files, at: point, mode: .drag)
        case .hideWheel:
            // Mouse up: let a real drop arrive, else choose from the pointer.
            wheel.dragEnded(screenPoint: NSEvent.mouseLocation)
        }
    }

    private func startSampling() {
        guard sampler == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.resume()
        sampler = timer
    }

    private func stopSampling() {
        sampler?.cancel()
        sampler = nil
    }
}
