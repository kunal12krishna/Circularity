import AppKit

/// A menu item that runs a closure (stored in `representedObject`).
func ActionMenuItem(_ title: String, key: String = "", checked: Bool = false,
                    handler: @escaping () -> Void) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(MenuActions.fire(_:)), keyEquivalent: key)
    item.target = MenuActions.shared
    item.representedObject = MenuActions.Handler(handler)
    item.state = checked ? .on : .off
    return item
}

final class MenuActions: NSObject {
    static let shared = MenuActions()

    final class Handler: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc func fire(_ sender: NSMenuItem) {
        (sender.representedObject as? Handler)?.run()
    }
}

extension NSMenuItem {
    static func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// The menu bar item (PLAN.md §3.4): board-H icon states, left click opens the
/// panel, right click shows the settings menu, and files dropped on the icon
/// open the wheel.
final class StatusItemController: NSObject {
    var onClick: (() -> Void)?
    var menuBuilder: (() -> [NSMenuItem])?
    var onDragEntered: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?

    private let item: NSStatusItem
    private let catcher = StatusDropView()
    private var revertWork: DispatchWorkItem?

    var style = StatusIconStyle.monochrome { didSet { render() } }
    var accent = NSColor.orange { didSet { render() } }
    var showPercent = false { didSet { render() } }
    private(set) var state = StatusIconState.idle

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.setAccessibilityLabel(AppIdentity.name)
            button.toolTip = AppIdentity.name
            catcher.frame = button.bounds
            catcher.autoresizingMask = [.width, .height]
            button.addSubview(catcher)
        }
        catcher.owner = self
        render()
        Log.menubar.notice("Status item installed")
    }

    /// The icon's frame on screen, for placing the panel under it.
    var screenFrame: CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func setHighlighted(_ on: Bool) { item.button?.highlight(on) }

    func set(_ new: StatusIconState) {
        guard new != state else { return }
        revertWork?.cancel()
        state = new
        render()
        if new == .done {
            pulse()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { if self?.state == .done { self?.set(.idle) } }
            }
            revertWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func render() {
        guard let button = item.button else { return }
        button.image = StatusIcon.image(state, style: style, accent: accent)
        if showPercent, case let .converting(p) = state {
            item.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeft
            button.title = "\(Int(p * 100))%"
        } else {
            button.title = ""
            item.length = NSStatusItem.squareLength
        }
        button.setAccessibilityValue(StatusIcon.description(state))
    }

    /// One gentle pulse for "done" (none with Reduce Motion).
    private func pulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let button = item.button else { return }
        button.wantsLayer = true
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 0.35, 1]
        a.duration = 0.5
        button.layer?.add(a, forKey: "pulse")
    }

    fileprivate func clicked() { onClick?() }

    fileprivate func rightClicked() {
        guard let items = menuBuilder?(), let button = item.button else { return }
        let menu = NSMenu()
        for entry in items { menu.addItem(entry) }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    fileprivate func dragEntered() { onDragEntered?() }
    fileprivate func dropped(_ urls: [URL]) { onFilesDropped?(urls) }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
}

/// Sits over the status button: takes clicks and file drops.
final class StatusDropView: NSView {
    weak var owner: StatusItemController?
    private var previous: StatusIconState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(WheelHostView.dragTypes)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { owner?.rightClicked() } else { owner?.clicked() }
    }

    override func rightMouseDown(with event: NSEvent) { owner?.rightClicked() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        previous = owner?.state
        owner?.set(.dragOver)
        owner?.dragEntered()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if owner?.state == .dragOver { owner?.set(previous ?? .idle) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if owner?.state == .dragOver { owner?.set(previous ?? .idle) }
        let urls = DraggedFiles.read(sender.draggingPasteboard).urls
        guard !urls.isEmpty else { return false }
        owner?.dropped(urls)
        return true
    }
}
