import AppKit

/// Settings → Advanced → developer HUD: a small click-through readout in the
/// top-right corner (memory, jobs, wheel, last drag), updated once a second.
final class DevHUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    var lines: () -> [String] = { [] }

    var isShown: Bool { panel != nil }

    func show() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 86), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = NSColor(srgbRed: 13 / 255, green: 15 / 255, blue: 20 / 255, alpha: 0.88)
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        label.textColor = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        label.maximumNumberOfLines = 6
        label.frame = CGRect(x: 10, y: 8, width: 260, height: 70)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.addSubview(label)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: screen.maxX - 292, y: screen.maxY - 98))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.label = label
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        label = nil
    }

    private func refresh() {
        label?.stringValue = (["\(AppIdentity.name) · \(MemoryFootprint.megabytes)"] + lines()).joined(separator: "\n")
    }
}
