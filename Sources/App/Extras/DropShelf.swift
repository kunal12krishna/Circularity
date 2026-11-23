import AppKit
import CircularityEngine

/// The result card and the Stash.
///
/// Result card: after a conversion the result floats by the pointer. Drag it
/// into Mail, Slack or a chat, Copy it, Show it, or Undo it (the result goes to
/// the Trash). It says how much smaller the file got, a ring around ✕ shows
/// when it will leave (hovering pauses it), and **Esc closes it**: while the
/// card is on screen it holds Esc as a Carbon hotkey, which needs no permission,
/// and lets go the moment the card goes. Settings → Output turns it off, and so
/// does its right-click menu.
///
/// Stash (the Actions wheel): a card that collects. Stash more files, or drop
/// them on it, and they pile up; drag them all out together. It stays until it's
/// emptied; Esc clears it while the pointer is over it.
final class DropShelf {
    enum Mode { case results, stash }

    let mode: Mode
    /// The card's "Don't show after converting".
    var onTurnOff: (() -> Void)?
    /// Undo for these results; returns what happened ("…and the original is back"), or nil.
    var onUndo: (([URL]) -> String?)? {
        didSet { view?.onUndo = onUndo }
    }
    private var panel: NSPanel?
    private var view: ShelfView?
    private var hideWork: DispatchWorkItem?
    /// Bumped by show(), so a fade-out that started earlier never hides new results.
    private var generation = 0
    private var escapeHeld = false
    /// On screen or fading in (a fade-out in progress doesn't count).
    private var shown = false
    private var escapeID: UInt32 { mode == .results ? 40 : 41 }
    static let lifetime: TimeInterval = 8

    init(mode: Mode = .results) {
        self.mode = mode
    }

    /// Files on the Stash right now.
    var stashed: [URL] { mode == .stash && isShowing ? (view?.files ?? []) : [] }

    /// Results: replaces the card. Stash: adds to the pile.
    func show(_ urls: [URL], accent: NSColor, bytesIn: Int64? = nil, undoable: Bool = false) {
        var files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        let adding = mode == .stash && isShowing
        if adding {
            let current = (view?.files ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
            files = current + files.filter { new in !current.contains { $0.standardizedFileURL == new.standardizedFileURL } }
        }
        guard !files.isEmpty else { return }
        present(repositioning: !adding) {
            $0.configure(files, accent: accent, bytesIn: bytesIn, undoable: undoable)
        }
    }

    /// A job that wrote nothing still answers by the pointer: why the original
    /// was kept, or what went wrong. Show reveals the original.
    func showMessage(_ title: String, _ detail: String, original: URL?, accent: NSColor) {
        present(repositioning: true) { $0.configureMessage(title, detail, original: original, accent: accent) }
    }

    private func present(repositioning: Bool, _ configure: (ShelfView) -> Void) {
        let panel = self.panel ?? makePanel()
        generation += 1
        if let view { configure(view) }
        view?.resetPointerState() // the pointer may have left while it was hidden
        let size = ShelfView.size
        if repositioning {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            var origin = mode == .stash ? CGPoint(x: mouse.x + 150, y: mouse.y + 40) : CGPoint(x: mouse.x + 28, y: mouse.y - size.height - 28)
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        }
        if !shown {
            shown = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.reduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(element: view as Any, notification: .layoutChanged)
        if mode == .results {
            holdEscape(true)
            scheduleHide(after: Self.lifetime)
        }
    }

    /// For --drag-test: whether it's on screen, and a picture of it.
    var isShowing: Bool { shown && (panel?.isVisible ?? false) }
    var holdsEscape: Bool { escapeHeld }
    func snapshot() -> NSBitmapImageRep? {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func hide() {
        hideWork?.cancel()
        holdEscape(false)
        shown = false
        guard let panel, panel.isVisible else {
            if mode == .stash { view?.files = [] }
            return
        }
        let shown = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                panel.orderOut(nil)
                self.view?.resetPointerState()
                if self.mode == .stash { self.view?.files = [] }
            }
        })
    }

    // MARK: Esc

    /// Esc as a hotkey only while it's useful: the result card for its few
    /// seconds, the Stash while the pointer is over it.
    private func holdEscape(_ on: Bool) {
        guard on != escapeHeld else { return }
        if on {
            escapeHeld = HotkeyCenter.shared.register(id: escapeID, keyCode: 53, modifiers: 0) { [weak self] in
                Log.app.notice("Esc closed the \(self?.mode == .stash ? "Stash" : "result card", privacy: .public)")
                self?.hide()
            }
        } else {
            HotkeyCenter.shared.unregister(id: escapeID)
            escapeHeld = false
        }
    }

    // MARK: Leaving by itself

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        view?.startCountdown(delay)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.view?.isHovered == true || self.view?.isDragging == true { return } // leaving the card reschedules
                self.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hoverChanged(_ hovered: Bool) {
        switch mode {
        case .results:
            guard isShowing, view?.isUndone != true else { return }
            if hovered {
                hideWork?.cancel()
                view?.pauseCountdown()
            } else {
                scheduleHide(after: Self.lifetime / 2)
            }
        case .stash:
            holdEscape(hovered && isShowing)
        }
    }

    private func makePanel() -> NSPanel {
        let size = ShelfView.size
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
        let view = ShelfView(frame: CGRect(origin: .zero, size: size), stash: mode == .stash)
        view.onDone = { [weak self] in self?.hide() }
        view.onUndo = onUndo
        view.onHover = { [weak self] in self?.hoverChanged($0) }
        view.onTurnOff = { [weak self] in
            self?.onTurnOff?()
            self?.hide()
        }
        view.onDropped = { [weak self] urls in
            guard let self, let accent = self.view?.accent else { return }
            self.show(urls, accent: accent)
        }
        view.onUndone = { [weak self] in
            guard let self else { return }
            self.hideWork?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        }
        panel.contentView = view
        self.panel = panel
        self.view = view
        return panel
    }
}

private final class ShelfView: NSView, NSDraggingSource {
    static let size = CGSize(width: 300, height: 112)

    var onDone: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onTurnOff: (() -> Void)?
    var onDropped: (([URL]) -> Void)?
    var onUndone: (() -> Void)?
    var onUndo: (([URL]) -> String?)?
    private(set) var isHovered = false
    private(set) var isDragging = false
    private(set) var isUndone = false
    var files: [URL] = []
    private(set) var accent = NSColor.systemPink
    private let isStash: Bool
    /// Message mode: the original, for Show (nothing to drag or copy).
    private var original: URL?
    private let stack = CALayer()
    private let ring = CAShapeLayer()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let escHint = NSTextField(labelWithString: "esc")
    private lazy var copyButton = button("Copy", #selector(copyFiles))
    private lazy var revealButton = button("Show", #selector(reveal))
    private lazy var thirdButton = button("Undo", #selector(third))
    private lazy var closeButton = button("✕", #selector(close))
    private var downPoint: CGPoint?
    private static let secondary = NSColor(srgbRed: 0.62, green: 0.65, blue: 0.72, alpha: 1)
    private static let saved = NSColor(srgbRed: 0.36, green: 0.86, blue: 0.6, alpha: 1)

    init(frame: NSRect, stash: Bool) {
        isStash = stash
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.97).cgColor
        layer?.borderWidth = 1
        layer?.addSublayer(stack)
        for field in [title, subtitle, escHint] {
            field.textColor = .white
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        title.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = Self.secondary
        escHint.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        escHint.textColor = Self.secondary
        escHint.alignment = .right
        title.frame = CGRect(x: 96, y: 74, width: 124, height: 18)
        subtitle.frame = CGRect(x: 96, y: 54, width: 192, height: 16)
        escHint.frame = CGRect(x: 224, y: 84, width: 32, height: 12)
        copyButton.frame = CGRect(x: 96, y: 14, width: 60, height: 26)
        revealButton.frame = CGRect(x: 160, y: 14, width: 60, height: 26)
        thirdButton.frame = CGRect(x: 224, y: 14, width: 62, height: 26)
        closeButton.frame = CGRect(x: 262, y: 78, width: 24, height: 24)
        closeButton.isBordered = false
        closeButton.contentTintColor = Self.secondary
        // The countdown ring around ✕: drains while the card waits to leave.
        ring.path = CGPath(ellipseIn: closeButton.frame.insetBy(dx: 1, dy: 1), transform: nil)
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeEnd = 1
        layer?.addSublayer(ring)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        if stash { registerForDraggedTypes([.fileURL]) }
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

    func resetPointerState() {
        isHovered = false
        isDragging = false
        downPoint = nil
    }

    // MARK: Countdown

    func startCountdown(_ seconds: TimeInterval) {
        guard !isStash else { return }
        ring.removeAllAnimations()
        ring.strokeEnd = 0
        guard !Motion.reduceMotion else { ring.strokeEnd = 1; return }
        let drain = CABasicAnimation(keyPath: "strokeEnd")
        drain.fromValue = 1
        drain.toValue = 0
        drain.duration = seconds
        ring.add(drain, forKey: "drain")
    }

    func pauseCountdown() {
        ring.removeAllAnimations()
        ring.strokeEnd = 1
    }

    // MARK: Content

    func configureMessage(_ heading: String, _ detail: String, original: URL?, accent: NSColor) {
        files = []
        isUndone = false
        self.original = original
        self.accent = accent
        styleChrome()
        title.stringValue = heading
        subtitle.attributedStringValue = Self.plain(detail)
        subtitle.maximumNumberOfLines = 3
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.frame = CGRect(x: 96, y: 40, width: 192, height: 32)
        copyButton.isHidden = true
        thirdButton.isHidden = true
        revealButton.isHidden = original == nil
        revealButton.frame = CGRect(x: 96, y: 10, width: 60, height: 26)
        setAccessibilityLabel("\(heading). \(detail) Press Escape to close.")
        stack.sublayers?.forEach { $0.removeFromSuperlayer() }
        stack.frame = CGRect(x: 12, y: 16, width: 76, height: 80)
        if let original { stack.addSublayer(card(original, index: 0)) }
        rebuildMenu()
    }

    func configure(_ files: [URL], accent: NSColor, bytesIn: Int64?, undoable: Bool) {
        self.files = files
        isUndone = false
        original = nil
        self.accent = accent
        styleChrome()
        subtitle.maximumNumberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = CGRect(x: 96, y: 54, width: 192, height: 16)
        copyButton.isHidden = false
        revealButton.isHidden = false
        revealButton.frame = CGRect(x: 160, y: 14, width: 60, height: 26)
        let bytes = files.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        let line = NSMutableAttributedString()
        if isStash {
            title.stringValue = files.count == 1 ? files[0].lastPathComponent : "Stash · \(files.count) items"
            line.append(Self.plain("drop more here · drag all out"))
            thirdButton.title = "Clear"
            thirdButton.isHidden = false
        } else {
            title.stringValue = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            if let change = Self.change(from: bytesIn, to: bytes) {
                line.append(NSAttributedString(string: change.text + "  ", attributes: [
                    .foregroundColor: change.smaller ? Self.saved : Self.secondary,
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                ]))
            }
            line.append(Self.plain("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · drag me anywhere"))
            thirdButton.title = "Undo"
            thirdButton.isHidden = !undoable
        }
        subtitle.attributedStringValue = line
        setAccessibilityLabel("\(isStash ? "Stash" : "Converted") \(title.stringValue). Drag to another app, or use Copy or Show. Press Escape to close.")
        copyButton.setAccessibilityLabel("Copy \(title.stringValue)")
        revealButton.setAccessibilityLabel("Show in Finder")
        thirdButton.setAccessibilityLabel(isStash ? "Clear the Stash" : "Undo: move the result to the Trash")
        closeButton.setAccessibilityLabel("Close")
        // Up to three fanned thumbnails; a count badge for more.
        stack.sublayers?.forEach { $0.removeFromSuperlayer() }
        stack.frame = CGRect(x: 12, y: 16, width: 76, height: 80)
        for (i, url) in files.prefix(3).enumerated().reversed() { stack.addSublayer(card(url, index: i)) }
        if files.count > 3 {
            let badge = CATextLayer()
            badge.string = "\(files.count)"
            badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            badge.fontSize = 10
            badge.alignmentMode = .center
            badge.foregroundColor = NSColor.black.cgColor
            badge.backgroundColor = accent.cgColor
            badge.cornerRadius = 8
            badge.frame = CGRect(x: 52, y: 62, width: 24, height: 16)
            badge.contentsScale = window?.backingScaleFactor ?? 2
            stack.addSublayer(badge)
        }
        rebuildMenu()
    }

    /// "−62%" (smaller) or "+12%"; nil when there's nothing to compare or it's within 1 %.
    static func change(from bytesIn: Int64?, to bytesOut: Int64) -> (text: String, smaller: Bool)? {
        guard let bytesIn, bytesIn > 0, bytesOut > 0 else { return nil }
        let pct = Double(bytesOut - bytesIn) / Double(bytesIn) * 100
        guard abs(pct) >= 1 else { return nil }
        return pct < 0 ? ("−\(Int((-pct).rounded()))%", true) : ("+\(Int(pct.rounded()))%", false)
    }

    private static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.foregroundColor: secondary, .font: NSFont.systemFont(ofSize: 11)])
    }

    private func styleChrome() {
        layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        ring.strokeColor = accent.cgColor
        // The Stash doesn't leave by itself: no countdown. Esc works while the pointer is on it.
        ring.isHidden = isStash
    }

    private func card(_ url: URL, index i: Int) -> CALayer {
        let card = CALayer()
        card.frame = CGRect(x: 6 + CGFloat(i) * 4, y: 8 + CGFloat(i) * 3, width: 62, height: 62)
        card.cornerRadius = 11
        card.masksToBounds = true
        card.borderWidth = 1
        card.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        card.contentsGravity = .resizeAspectFill
        card.contentsScale = window?.backingScaleFactor ?? 2
        card.transform = CATransform3DMakeRotation(CGFloat(i) * -0.08, 0, 0, 1)
        card.contents = Self.thumbnail(url)
        return card
    }

    static func thumbnail(_ url: URL) -> Any {
        if let image = Thumbnails.image(url, maxPixel: 160) { return image }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func size(of url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    private func rebuildMenu() {
        let menu = NSMenu()
        if !files.isEmpty { menu.addItem(withTitle: "Quick Look", action: #selector(previewFiles), keyEquivalent: "").target = self }
        if isStash {
            if !files.isEmpty { menu.addItem(withTitle: "Clear the Stash", action: #selector(close), keyEquivalent: "").target = self }
        } else {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "Don't Show After Converting", action: #selector(turnOff), keyEquivalent: "").target = self
        }
        self.menu = menu
    }

    // MARK: Dragging out (and clicking a thumbnail for Quick Look)

    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !isDragging, !files.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        isDragging = true
        // Pictures only for the first three items: a 200-file batch must not
        // make 200 thumbnails before the drag can start.
        let generic = NSWorkspace.shared.icon(for: .data)
        let items = files.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let frame = CGRect(x: 12 + CGFloat(min(i, 3)) * 4, y: 20, width: 56, height: 56)
            if i < 3, let thumb = Thumbnails.image(url, maxPixel: 128) {
                item.setDraggingFrame(frame, contents: NSImage(cgImage: thumb, size: .zero))
            } else {
                item.setDraggingFrame(frame, contents: i < 3 ? NSWorkspace.shared.icon(forFile: url.path) : generic)
            }
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard let start = downPoint, !isDragging, stack.frame.contains(start) else { return }
        previewFiles()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        downPoint = nil
        if operation != [] { onDone?() }
    }

    // MARK: Dropping in (the Stash only)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isStash, (sender.draggingSource as AnyObject?) !== self else { return [] }
        layer?.borderColor = accent.cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderColor = accent.withAlphaComponent(0.55).cgColor }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard isStash, !urls.isEmpty else { return false }
        onDropped?(urls)
        return true
    }

    // MARK: Pointer

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(false)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Buttons

    @objc private func copyFiles() {
        Clipboard.write(files)
        subtitle.attributedStringValue = Self.plain("Copied · paste anywhere")
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(files.isEmpty ? original.map { [$0] } ?? [] : files)
        onDone?()
    }

    @objc private func third() {
        if isStash {
            onDone?()
            return
        }
        // Undo: the result goes to the Trash (Finder's Put Back brings it back).
        let results = files
        var said: String?
        if let onUndo {
            said = onUndo(results)
        } else {
            NSWorkspace.shared.recycle(results) { _, error in
                if let error { Log.app.error("Undo: \(error.localizedDescription, privacy: .public)") }
            }
        }
        files = []
        isUndone = true
        title.stringValue = "Undone"
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.frame = CGRect(x: 96, y: 42, width: 192, height: 30)
        subtitle.attributedStringValue = Self.plain(said ?? (results.count == 1 ? "The result is in the Trash." : "The results are in the Trash."))
        copyButton.isHidden = true
        revealButton.isHidden = true
        thirdButton.isHidden = true
        ring.removeAllAnimations()
        ring.isHidden = true
        stack.sublayers?.forEach { $0.opacity = 0.35 }
        rebuildMenu()
        onUndone?()
    }

    @objc private func previewFiles() {
        guard !files.isEmpty else { return }
        QuickLook.shared.show(files)
    }

    @objc private func turnOff() { onTurnOff?() }

    @objc private func close() { onDone?() }
}

/// Copy that pastes well everywhere: Finder gets the file; for one picture,
/// chats and documents get the picture itself.
enum Clipboard {
    static func write(_ files: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if files.count == 1, let url = files.first,
           DraggedFiles.type(of: url).conforms(to: .image),
           (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 < 40_000_000 }) == true,
           let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation {
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
            item.setData(tiff, forType: .tiff)
            pasteboard.writeObjects([item])
            return
        }
        pasteboard.writeObjects(files as [NSURL])
    }
}
