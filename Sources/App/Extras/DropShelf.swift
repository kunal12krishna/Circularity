import AppKit
import CircularityEngine

/// After a conversion the results float near the pointer: drag them straight
/// into Mail, Slack or a chat, or use Copy / Show in Finder (keyboard and
/// VoiceOver friendly). AppKit only, built when first shown.
final class DropShelf {
    private var panel: NSPanel?
    private var view: ShelfView?
    private var hideWork: DispatchWorkItem?

    func show(_ urls: [URL], accent: NSColor) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        let panel = self.panel ?? makePanel()
        view?.configure(files, accent: accent)
        let size = CGSize(width: 252, height: 108)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = CGPoint(x: mouse.x + 28, y: mouse.y - size.height - 28)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(element: view as Any, notification: .layoutChanged)
        scheduleHide()
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }

    /// Stays while the pointer is over it; otherwise goes after 8 s.
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.view?.isHovered == true || self.view?.isDragging == true { self.scheduleHide() } else { self.hide() }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 252, height: 108), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
        let view = ShelfView(frame: CGRect(x: 0, y: 0, width: 252, height: 108))
        view.onDone = { [weak self] in self?.hide() }
        panel.contentView = view
        self.panel = panel
        self.view = view
        return panel
    }
}

private final class ShelfView: NSView, NSDraggingSource {
    var onDone: (() -> Void)?
    private(set) var isHovered = false
    private(set) var isDragging = false
    private var files: [URL] = []
    private var accent = NSColor.systemGreen
    private let stack = CALayer()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private lazy var copyButton = button("Copy", #selector(copyFiles))
    private lazy var revealButton = button("Show", #selector(reveal))
    private lazy var closeButton = button("✕", #selector(close))
    private var downPoint: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.96).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.addSublayer(stack)
        for field in [title, subtitle] {
            field.textColor = .white
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        title.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = NSColor(srgbRed: 0.66, green: 0.69, blue: 0.75, alpha: 1)
        title.frame = CGRect(x: 92, y: 70, width: 150, height: 18)
        subtitle.frame = CGRect(x: 92, y: 52, width: 150, height: 16)
        copyButton.frame = CGRect(x: 92, y: 14, width: 58, height: 26)
        revealButton.frame = CGRect(x: 156, y: 14, width: 58, height: 26)
        closeButton.frame = CGRect(x: 220, y: 76, width: 24, height: 24)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11, weight: .semibold)
        b.appearance = NSAppearance(named: .darkAqua)
        addSubview(b)
        return b
    }

    func configure(_ files: [URL], accent: NSColor) {
        self.files = files
        self.accent = accent
        layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        title.stringValue = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        subtitle.stringValue = "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · drag me anywhere"
        setAccessibilityLabel("Converted \(title.stringValue). Drag to another app, or use Copy or Show.")
        copyButton.setAccessibilityLabel("Copy \(title.stringValue)")
        revealButton.setAccessibilityLabel("Show in Finder")
        closeButton.setAccessibilityLabel("Close")
        // Up to three fanned thumbnails.
        stack.sublayers?.forEach { $0.removeFromSuperlayer() }
        stack.frame = CGRect(x: 12, y: 14, width: 72, height: 80)
        for (i, url) in files.prefix(3).enumerated().reversed() {
            let card = CALayer()
            card.frame = CGRect(x: 4 + CGFloat(i) * 4, y: 6 + CGFloat(i) * 3, width: 60, height: 60)
            card.cornerRadius = 10
            card.masksToBounds = true
            card.borderWidth = 1
            card.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            card.contentsGravity = .resizeAspectFill
            card.contentsScale = window?.backingScaleFactor ?? 2
            card.transform = CATransform3DMakeRotation(CGFloat(i) * -0.08, 0, 0, 1)
            card.contents = Self.thumbnail(url)
            stack.addSublayer(card)
        }
    }

    static func thumbnail(_ url: URL) -> Any {
        if let image = Thumbnails.image(url, maxPixel: 160) { return image }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // Dragging out
    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !isDragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        isDragging = true
        let items = files.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = NSWorkspace.shared.icon(forFile: url.path)
            if let thumb = Thumbnails.image(url, maxPixel: 128) { item.setDraggingFrame(CGRect(x: 12 + CGFloat(i) * 4, y: 20, width: 56, height: 56), contents: NSImage(cgImage: thumb, size: .zero)) }
            else { item.setDraggingFrame(CGRect(x: 12, y: 20, width: 56, height: 56), contents: image) }
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { downPoint = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        downPoint = nil
        if operation != [] { onDone?() }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override var acceptsFirstResponder: Bool { true }

    @objc private func copyFiles() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(files as [NSURL])
        subtitle.stringValue = "Copied · paste anywhere"
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(files)
        onDone?()
    }

    @objc private func close() { onDone?() }
}
