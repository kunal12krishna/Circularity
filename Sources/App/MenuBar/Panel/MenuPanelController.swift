import AppKit
import Combine
import SwiftUI

/// A borderless panel that can take keyboard focus without activating the app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The menu bar panel (PLAN.md §3.4): a non-activating, key-capable glass
/// panel 8 pt under the menu bar. Its SwiftUI content is created on open and
/// released on close (perf budget). Closes on an outside click and Esc.
final class MenuPanelController {
    private let model: PanelModel
    private let settings: SettingsStore
    private var panel: KeyPanel?
    private var hosting: NSHostingView<PanelRoot>?
    private var monitors: [Any] = []
    private var resize: AnyCancellable?
    var anchor: () -> CGRect? = { nil }
    var onOpenChange: ((Bool) -> Void)?

    init(model: PanelModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
    }

    var isOpen: Bool { panel?.isVisible == true }
    /// For tests: where the panel is (nil when closed).
    var frameForTesting: CGRect? { panel?.frame }

    private var width: CGFloat {
        switch settings.value(SettingsKeys.panelWidth) {
        case "s": 340
        case "l": 440
        default: model.layout == .mini ? 340 : 380
        }
    }

    func toggle() { isOpen ? close() : open() }

    func open(focusCommand: Bool = false, dropMode: Bool = false) {
        model.focusCommand = focusCommand
        model.dropMode = dropMode
        model.query = ""
        if isOpen { panel?.makeKey(); return }
        let panel = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: 400),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = model.layout == .tabs ? .popover : .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: model.layout == .tabs ? .aqua : .darkAqua)
        effect.maskImage = Self.roundedMask(radius: 16)
        let hosting = NSHostingView(rootView: PanelRoot(model: model, width: width))
        effect.addSubview(hosting)
        panel.contentView = effect
        self.panel = panel
        self.hosting = hosting
        fit(animated: false)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        animateIn(effect)
        installMonitors()
        resize = model.objectWillChange
            .debounce(for: .milliseconds(20), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.fit(animated: true) }
        onOpenChange?(true)
    }

    func close(animated: Bool = true) {
        guard let panel else { return }
        removeMonitors()
        resize = nil
        model.dropMode = false
        model.dropTargeted = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? 0.12 : 0
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.contentView = nil
                guard let self, self.panel === panel else { return }
                self.panel = nil
                self.hosting = nil // the SwiftUI tree is released on close
                MemoryFootprint.relieve()
            }
        })
        onOpenChange?(false)
    }

    /// Height fits the content up to 80 % of the screen; past that the content scrolls.
    private func fit(animated: Bool) {
        guard let panel, let hosting else { return }
        let screen = anchorScreen
        let maxHeight = (screen?.visibleFrame.height ?? 900) * 0.8
        hosting.rootView = PanelRoot(model: model, width: width)
        var size = hosting.fittingSize
        if size.height > maxHeight {
            hosting.rootView = PanelRoot(model: model, width: width, maxHeight: maxHeight)
            size.height = maxHeight
        }
        size.width = width
        var frame = CGRect(origin: .zero, size: size)
        if let icon = anchor(), let visible = screen?.visibleFrame {
            // 8 pt below the menu bar (board I), under the icon, kept on screen.
            frame.origin.y = (screen?.frame.maxY ?? visible.maxY) - (screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24) - 8 - size.height
            frame.origin.x = min(max(icon.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        } else if let visible = screen?.visibleFrame {
            frame.origin = CGPoint(x: visible.maxX - size.width - 12, y: visible.maxY - 8 - size.height)
        }
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.setFrame(frame, display: true, animate: false)
        panel.invalidateShadow()
    }

    private var anchorScreen: NSScreen? {
        if let icon = anchor() { return NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main }
        return NSScreen.main
    }

    /// Spring from the icon: scale 0.96 → 1 and fade in, 220 ms (none with Reduce Motion).
    private func animateIn(_ view: NSView) {
        guard let panel else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
            return
        }
        panel.alphaValue = 1
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let b = layer.bounds
        let anchor = CGPoint(x: layer.anchorPoint.x * b.width, y: layer.anchorPoint.y * b.height)
        let pivot = CGPoint(x: b.midX, y: b.maxY) // top centre, near the icon
        var t = CATransform3DMakeTranslation(pivot.x - anchor.x, pivot.y - anchor.y, 0)
        t = CATransform3DScale(t, 0.96, 0.96, 1)
        t = CATransform3DTranslate(t, anchor.x - pivot.x, anchor.y - pivot.y, 0)
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: t)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.stiffness = 400; grow.damping = 30
        grow.duration = 0.22
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.16
        layer.add(grow, forKey: "open")
        layer.add(fade, forKey: "fade")
    }

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !panel.frame.contains(point) else { return }
                if let icon = self.anchor(), icon.contains(point) { return } // the icon toggles by itself
                self.close()
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            let consumed: Bool = MainActor.assumeIsolated {
                guard let self, self.isOpen else { return false }
                if !self.model.query.isEmpty { self.model.query = "" } else { self.close() }
                return true
            }
            return consumed ? nil : event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let size = CGSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// "Pin": the panel detached into a floating window that stays on top,
/// sized S/M/L, docked to the nearest screen corner (remembered per display),
/// optionally click-through so it never steals focus.
final class PinnedPanelController: NSObject, NSWindowDelegate {
    private let model: PanelModel
    private let settings: SettingsStore
    private var window: KeyPanel?
    private var hosting: NSHostingView<PanelRoot>?
    private var resize: AnyCancellable?

    init(model: PanelModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
    }

    var isPinned: Bool { window != nil }

    private var width: CGFloat {
        switch settings.value(SettingsKeys.pinnedSize) {
        case "s": 340
        case "l": 440
        default: 380
        }
    }

    func pin() {
        guard window == nil else { return }
        let w = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: 400),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.delegate = self
        let effect = NSVisualEffectView()
        effect.material = model.layout == .tabs ? .popover : .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: model.layout == .tabs ? .aqua : .darkAqua)
        effect.maskImage = MenuPanelController.roundedMask(radius: 16)
        let hosting = NSHostingView(rootView: PanelRoot(model: model, width: width))
        effect.addSubview(hosting)
        w.contentView = effect
        window = w
        self.hosting = hosting
        model.pinned = true
        settings.set(true, for: SettingsKeys.pinned)
        applyClickThrough()
        fit()
        dock(to: savedCorner)
        w.orderFrontRegardless()
        resize = model.objectWillChange.debounce(for: .milliseconds(20), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.fit() }
    }

    func unpin() {
        resize = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        hosting = nil
        model.pinned = false
        settings.set(false, for: SettingsKeys.pinned)
        MemoryFootprint.relieve()
    }

    func setSize(_ size: String) {
        settings.set(size, for: SettingsKeys.pinnedSize)
        guard isPinned else { return }
        unpin()
        pin()
    }

    func toggleClickThrough() {
        settings.set(!settings.value(SettingsKeys.pinnedClickThrough), for: SettingsKeys.pinnedClickThrough)
        applyClickThrough()
    }

    private func applyClickThrough() {
        window?.ignoresMouseEvents = settings.value(SettingsKeys.pinnedClickThrough)
    }

    private func fit() {
        guard let window, let hosting else { return }
        let maxHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        hosting.rootView = PanelRoot(model: model, width: width)
        var size = hosting.fittingSize
        if size.height > maxHeight * 0.85 {
            hosting.rootView = PanelRoot(model: model, width: width, maxHeight: maxHeight * 0.85)
            size.height = maxHeight * 0.85
        }
        size.width = width
        let top = window.frame.maxY
        hosting.frame = CGRect(origin: .zero, size: size)
        window.setFrame(CGRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        window.invalidateShadow()
    }

    // MARK: Docking (per display)

    private var displayKey: String {
        let screen = window?.screen ?? NSScreen.main
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
        return id
    }

    private var savedCorner: String { settings.value(SettingsKeys.pinnedCorners)[displayKey] ?? "topRight" }

    private func dock(to corner: String) {
        guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = window.frame.size, m: CGFloat = 12
        let x = corner.hasSuffix("Left") ? visible.minX + m : visible.maxX - size.width - m
        let y = corner.hasPrefix("top") ? visible.maxY - size.height - m : visible.minY + m
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let c = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let corner = (c.y > visible.midY ? "top" : "bottom") + (c.x < visible.midX ? "Left" : "Right")
        var corners = settings.value(SettingsKeys.pinnedCorners)
        guard corners[displayKey] != corner else { return }
        corners[displayKey] = corner
        settings.set(corners, for: SettingsKeys.pinnedCorners)
        // Snap once the drag settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.dock(to: corner) }
        }
    }
}
