import AppKit
import CircularityEngine
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// What the user picked on the wheel. Milestone (d) turns this into engine jobs.
struct WheelChoice {
    var action: WheelAction?   // nil = cancelled
    var label: String
    var files: [URL]
    var count: Int
}

/// Shows the wheel, tracks hover, and turns drops/clicks into choices
/// (PLAN.md §3.3). The panel and renderer are built once and reused.
final class WheelController {
    enum Mode { case drag, click }

    /// The drag left the wheel: it hid itself and the drag goes on.
    var onDragDismissed: (() -> Void)?
    /// A drop or click finished (including Cancel).
    var onFinished: ((WheelChoice) -> Void)?
    /// The wheel appeared (the tutorial follows along).
    var onShown: (() -> Void)?

    private let settings: SettingsStore
    private var panel: WheelPanel?
    private var host: WheelHostView?
    private var glass: NSVisualEffectView?
    private var layerView: NSView?
    private var renderer: WheelRenderer?
    private var rendererKey = ""

    private var geometry = WheelGeometry.ring()
    private var menu = WheelMenu(ring: Array(repeating: nil, count: 6), fan: [], notice: nil)
    private var files = DraggedFiles()
    private var mode = Mode.drag
    private(set) var kind = WheelKind.convert
    /// Click mode: wheel keys already down, so only a new press switches.
    private var clickKeysDown: Set<WheelKind> = []
    private var state = WheelVisualState()
    private var moreTimer: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var finishing = false
    private var lastDragPoint: CGPoint?
    private(set) var isVisible = false
    private let loupe = BeforeAfterLoupe()
    /// ⇧ CONVERT ⌘ TOOLS ⌃ ACTIONS above the wheel.
    private let keyGuide = KeyGuideLayer()
    /// Breathing, the orbiting dots, the twirl and sparks (Wheel Studio looks).
    private let effects = WheelEffects()
    private var contentsScale: CGFloat = 2
    /// The GIF preview's frames for the video on the wheel (made on first hover).
    private var previewFrames: [CGImage]?
    private var previewTask: Task<Void, Never>?
    /// Bumped by every show(), so a delayed hide meant for an earlier wheel
    /// never closes a newer one.
    private var generation = 0

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Creates the (hidden, empty) panel at launch so it is a known drop target
    /// before the first drag. The renderer is still built lazily.
    func prepare() {
        if panel == nil { buildPanel() }
    }

    // MARK: Show / hide

    func show(_ files: DraggedFiles, at screenPoint: CGPoint, mode: Mode, kind: WheelKind = .convert) {
        moreTimer?.cancel()
        generation += 1
        self.files = files
        self.mode = mode
        self.kind = kind
        previewTask?.cancel()
        previewFrames = nil
        clickKeysDown = GestureController.keyMap(settings).kinds(down: GestureController.names(NSEvent.modifierFlags))
        finishing = false
        lastDragPoint = nil
        state = WheelVisualState()

        let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) } ?? NSScreen.main
        let contentsScale = screen?.backingScaleFactor ?? 2
        self.contentsScale = contentsScale
        loupe.reset()
        let (renderer, kind) = prepareRenderer()
        geometry = Appearance.geometry(settings, layout: kind)
        let look = Appearance.wheelStyle(settings, layout: kind)
        Motion.speed = settings.value(SettingsKeys.animationSpeed)

        menu = buildMenu(self.kind)

        var center = screenPoint
        if mode == .click, let visible = screen?.visibleFrame {
            // Not a drag, so the wheel may move to stay fully on screen.
            let r = geometry.discDiameter / 2 * geometry.scale + 8
            center.x = min(max(center.x, visible.minX + r), visible.maxX - r)
            center.y = min(max(center.y, visible.minY + r), visible.maxY - r)
        }
        if let visible = screen?.visibleFrame {
            state.fanFlipped = geometry.fanNeedsFlip(center: center, visibleFrame: visible, count: menu.fan.count)
        }

        let content = orbContent(clickMode: mode == .click)
        renderer.configure(menu: menu, orb: content, style: look, geometry: geometry, contentsScale: contentsScale)
        renderer.apply(state, animated: false)
        requestThumbnail(size: geometry.orbDiameter * geometry.scale, scale: contentsScale)
        requestEstimates()

        configureKeyGuide(look: look, center: center, screen: screen?.visibleFrame)
        guard let panel, let host else { return }
        let size = geometry.size
        panel.setFrame(CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: false)
        host.frame = CGRect(x: 0, y: 0, width: size, height: size)
        layerView?.frame = host.bounds
        effects.configure(style: look, geometry: geometry, bounds: host.bounds, contentsScale: contentsScale)
        renderer.layer.frame = effects.root.bounds
        if let glass {
            let d = geometry.discDiameter * geometry.scale
            glass.frame = CGRect(x: (size - d) / 2, y: (size - d) / 2, width: d, height: d)
            glass.maskImage = Self.circleMask(diameter: d)
            glass.isHidden = !renderer.usesGlass
            glass.appearance = NSAppearance(named: look.light ? .aqua : .darkAqua)
        }

        panel.alphaValue = 0
        panel.allowsKey = mode == .click
        if mode == .click {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(host)
            installOutsideClickMonitor()
        } else {
            panel.orderFrontRegardless()
        }
        isVisible = true
        onShown?()
        bloom(renderer, style: settings.value(SettingsKeys.animationStyle))
        effects.opened(glass: renderer.usesGlass && glass?.isHidden == false ? glass?.layer : nil)
        WheelSounds.play(.open, pack: settings.value(SettingsKeys.soundPack))
        Log.wheel.notice("Wheel shown (\(kind.rawValue, privacy: .public), \(mode == .click ? "click" : "drag", privacy: .public) mode, \(files.count, privacy: .public) item(s), fan \(self.state.fanFlipped ? "flipped" : "down", privacy: .public))")
        NSAccessibility.post(element: host, notification: .layoutChanged)
    }

    /// The buttons for one wheel, with the centre's at-rest hint for reaching the others.
    private func buildMenu(_ kind: WheelKind) -> WheelMenu {
        var menu: WheelMenu = switch kind {
        case .convert:
            SlotProvider.menu(for: files.types, canWrite: { FormatSupport.current.canWrite($0) },
                              usage: settings.value(SettingsKeys.wheelUsage),
                              smartOrdering: settings.value(SettingsKeys.smartOrdering),
                              presets: Preset.decodeList(settings.value(SettingsKeys.presetsJSON)),
                              formatOrder: SlotProvider.imageFormatOrder(settings.value(SettingsKeys.imageFormatOrder)),
                              slots: SlotProvider.parseSlots(settings.value(SettingsKeys.imageSlots)))
        case .tools:
            SlotProvider.toolsMenu(for: files.types)
        case .actions:
            SlotProvider.actionsMenu(count: files.count)
        }
        menu.kind = kind
        let keys = GestureController.keyMap(settings)
        // With the key guide showing, the centre doesn't need to repeat it.
        menu.restHint = settings.value(SettingsKeys.keyGuide) ? nil : keys.restHint(for: kind)
        // Nothing to convert (a folder, say): point at the wheel that can help.
        if kind != .actions, menu.notice != nil, let key = keys.key(for: .actions) {
            menu.notice?.detail = "\(WheelKeyMap.symbol(key)) for actions: AirDrop, Copy…"
        }
        return menu
    }

    /// The keycaps above the wheel, in this wheel's look; below it when the
    /// fan opens upwards or the top of the screen is too close.
    private func configureKeyGuide(look: WheelStyle, center: CGPoint, screen: CGRect?) {
        guard settings.value(SettingsKeys.keyGuide) else {
            keyGuide.isHidden = true
            return
        }
        keyGuide.configure(keys: GestureController.keyMap(settings), current: kind, style: look, scale: geometry.scale,
                           contentsScale: contentsScale)
        // The wheel as drawn (a hovered button pops a little further: leave room for it).
        let radius = renderer.map { KeyGuideLayer.reach(of: effects.root, renderer: $0, geometry: geometry) } ?? geometry.outerExtent
        let room = screen.map { $0.maxY - (center.y + radius) } ?? .infinity
        let below = state.fanFlipped || room < 48 * geometry.scale
        let mid = geometry.size / 2
        keyGuide.place(center: CGPoint(x: mid, y: mid), radius: radius, below: below, canvas: geometry.size)
    }

    /// For tests: which wheel the key guide lights, or nil when it's hidden.
    var keyGuideLit: WheelKind? { keyGuide.isHidden ? nil : keyGuide.lit }

    /// Another wheel for the same files, in place: Tools, Actions or Convert.
    func switchTo(_ newKind: WheelKind) {
        guard isVisible, !finishing, newKind != kind, let renderer else { return }
        moreTimer?.cancel()
        moreTimer = nil
        loupe.hide()
        kind = newKind
        menu = buildMenu(newKind)
        let layout = WheelLayoutKind(rawValue: rendererKey) ?? .halo
        let look = Appearance.wheelStyle(settings, layout: layout)
        let keepCursor = state.cursor
        state = WheelVisualState()
        state.cursor = keepCursor
        if let panel, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            state.fanFlipped = geometry.fanNeedsFlip(center: center, visibleFrame: visible, count: menu.fan.count)
        }
        renderer.configure(menu: menu, orb: orbContent(clickMode: mode == .click), style: look, geometry: geometry,
                           contentsScale: contentsScale)
        renderer.apply(state, animated: false)
        keyGuide.select(newKind, animated: true)
        requestThumbnail(size: geometry.orbDiameter * geometry.scale, scale: contentsScale)
        requestEstimates()
        if !Motion.reduceMotion { renderer.popIn() }
        WheelSounds.play(.open, pack: settings.value(SettingsKeys.soundPack))
        if settings.value(SettingsKeys.haptics) { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        // In a drag, the pointer is already somewhere on the new wheel.
        if mode == .drag, let lastDragPoint { dragPointer(at: lastDragPoint) }
        Log.wheel.notice("Switched to the \(newKind.rawValue, privacy: .public) wheel")
        if let host { NSAccessibility.post(element: host, notification: .layoutChanged) }
    }

    /// Click mode: modifier keys from the wheel's own key window.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard isVisible, mode == .click else { return }
        let down = GestureController.keyMap(settings).kinds(down: GestureController.names(flags))
        let pressed = down.subtracting(clickKeysDown)
        clickKeysDown = down
        if let next = WheelKind.allCases.first(where: pressed.contains) { switchTo(next) }
    }

    /// Mouse up after a drag: hide unless a drop is already animating out.
    func hideUnlessFinishing() {
        guard !finishing else { return }
        hide(animated: true)
    }

    func hide(animated: Bool) {
        guard isVisible, let panel else { return }
        isVisible = false
        moreTimer?.cancel()
        loupe.reset()
        previewTask?.cancel()
        renderer?.playThumbnail(nil)
        removeOutsideClickMonitor()
        let duration = animated ? 0.12 : 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                panel.orderOut(nil)
                panel.allowsKey = false
                self.effects.stop(glass: self.glass?.layer)
                self.renderer?.setThumbnail(nil)
                self.files = DraggedFiles()
                MemoryFootprint.relieve()
            }
        })
    }

    /// Settings → Wheel → animation: bloom (board: spring from 0.6 plus the
    /// segment ripple), pop (spring only), fade, instant.
    private func bloom(_ renderer: WheelRenderer, style: String) {
        guard let panel, let bloomLayer = host?.layer else { return }
        if style == "instant" {
            panel.alphaValue = 1
            return
        }
        if Motion.reduceMotion || style == "fade" {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(Motion.reduceMotion ? 0.12 : 0.16)
                panel.animator().alphaValue = 1
            }
            return
        }
        panel.alphaValue = 1
        // Spring bloom from the cursor: scale 0.6 → 1, alpha 0 → 1, 180 ms.
        let b = bloomLayer.bounds
        let anchor = CGPoint(x: bloomLayer.anchorPoint.x * b.width, y: bloomLayer.anchorPoint.y * b.height)
        let c = CGPoint(x: b.midX, y: b.midY)
        func scaled(_ k: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(c.x - anchor.x, c.y - anchor.y, 0)
            t = CATransform3DScale(t, k, k, 1)
            return CATransform3DTranslate(t, anchor.x - c.x, anchor.y - c.y, 0)
        }
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: scaled(style == "pop" ? 0.85 : 0.6))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.stiffness = 380 * Motion.speed * Motion.speed; grow.damping = 26 * Motion.speed; grow.mass = 1
        grow.duration = min(grow.settlingDuration, Motion.duration(0.32))
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = Motion.duration(0.18)
        bloomLayer.add(grow, forKey: "bloom")
        bloomLayer.add(fade, forKey: "bloomFade")
        if style != "pop" { renderer.popIn() }
    }

    // MARK: Building

    private func prepareRenderer() -> (WheelRenderer, WheelLayoutKind) {
        var kind = WheelLayoutKind(rawValue: settings.value(SettingsKeys.wheelLayout)) ?? .halo
        // Reduce Transparency: Ring falls back to Halo's solid disc (BRIEF.md).
        if kind == .ring, Motion.reduceTransparency { kind = .halo }
        let key = kind.rawValue
        if panel == nil { buildPanel() }
        if let renderer, rendererKey == key { return (renderer, kind) }
        let made: WheelRenderer = switch kind {
        case .ring: SectorRenderer(style: .ring)
        case .halo: SectorRenderer(style: .halo)
        case .orbit: OrbitRenderer()
        }
        renderer?.layer.removeFromSuperlayer()
        effects.attach(made.layer)
        renderer = made
        rendererKey = key
        return (made, kind)
    }

    private func buildPanel() {
        let panel = WheelPanel()
        let host = WheelHostView(frame: CGRect(x: 0, y: 0, width: 720, height: 720))
        host.controller = self
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        let layerView = NSView(frame: host.bounds)
        layerView.layer = CALayer()
        layerView.wantsLayer = true
        layerView.layer?.addSublayer(effects.root)
        layerView.layer?.addSublayer(keyGuide.layer)
        host.addSubview(glass)
        host.addSubview(layerView)
        panel.contentView = host
        self.panel = panel
        self.host = host
        self.glass = glass
        self.layerView = layerView
        Log.wheel.notice("Wheel panel built")
    }

    private func orbContent(clickMode: Bool) -> OrbContent {
        let count = files.count
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let bytes = files.urls.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let size = bytes > 0 ? formatter.string(fromByteCount: bytes) : ""
        if count == 1, let url = files.urls.first {
            let name = url.lastPathComponent
            return OrbContent(fileLine: size.isEmpty ? name : "\(name) · \(size)", title: name, detail: size,
                              count: 1, thumbnail: nil, clickMode: clickMode)
        }
        let noun: String = {
            let kinds = Set(files.types.map { "\(SlotProvider.kind(of: $0))" })
            if kinds == ["image"] { return count == 1 ? "image" : "images" }
            return count == 1 ? "item" : "items"
        }()
        let summary = "\(count) \(noun)"
        return OrbContent(fileLine: size.isEmpty ? summary : "\(summary) · \(size)", title: summary,
                          detail: size.isEmpty ? "" : "\(size) total", count: count, thumbnail: nil, clickMode: clickMode)
    }

    private func requestThumbnail(size: CGFloat, scale: CGFloat) {
        guard let url = files.urls.first else { return }
        // Images: a tiny ImageIO decode. QuickLook (heavier) only for documents.
        if DraggedFiles.type(of: url).conforms(to: .image) {
            let maxPixel = Int(size * scale)
            Task.detached(priority: .userInitiated) {
                let image = UncheckedSendable(Thumbnails.image(url, maxPixel: maxPixel))
                await MainActor.run { [weak self] in
                    guard let self, self.isVisible, self.files.urls.first == url else { return }
                    self.renderer?.setThumbnail(image.value)
                }
            }
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = UncheckedSendable(rep?.cgImage)
            Task { @MainActor in
                guard let self, self.isVisible, self.files.urls.first == url else { return }
                self.renderer?.setThumbnail(image.value)
            }
        }
    }

    /// Video and audio: what each format and Compress would roughly come to.
    private func requestMediaEstimates(_ url: URL) {
        Task { [weak self] in
            guard let estimate = await MediaSupport.estimate(url) else { return }
            guard let self, self.isVisible, self.files.urls.first == url else { return }
            func hinted(_ slot: WheelSlot) -> WheelSlot {
                var slot = slot
                switch slot.action {
                case let .convert(f) where f.isVideo:
                    if let bytes = estimate.formats[f] { slot.hint = "\(SizeEstimator.describe(bytes)), in seconds" }
                case let .convert(f):
                    if let bytes = estimate.formats[f] { slot.hint = SizeEstimator.describe(bytes) }
                case .compress:
                    if let bytes = estimate.compress[.balanced] { slot.hint = "\(SizeEstimator.describe(bytes)) at Balanced" }
                default: break
                }
                return slot
            }
            self.menu.ring = self.menu.ring.map { $0.map(hinted) }
            self.menu.fan = self.menu.fan.map(hinted)
            self.renderer?.updateHints(self.menu)
        }
    }

    /// Hovering GIF on a video plays a little preview in the centre.
    private func updateGIFPreview() {
        let hoversGIF = menu.slot(for: state.hover)?.action == .convert(.gif)
        guard hoversGIF, files.urls.count == 1, let url = files.urls.first,
              SlotProvider.kind(of: DraggedFiles.type(of: url)) == .video else {
            renderer?.playThumbnail(nil)
            return
        }
        if let previewFrames {
            renderer?.playThumbnail(previewFrames)
            return
        }
        guard previewTask == nil else { return }
        let size = geometry.orbDiameter * geometry.scale * contentsScale
        previewTask = Task { [weak self] in
            let frames = await MediaSupport.previewFrames(url, count: 16, maxPixel: size)
            guard let self, self.isVisible, self.files.urls.first == url else { return }
            self.previewFrames = frames
            if self.menu.slot(for: self.state.hover)?.action == .convert(.gif) { self.renderer?.playThumbnail(frames) }
        }
    }

    /// "about 2.9 MB" for each format slot, computed off the main thread.
    private func requestEstimates() {
        if files.urls.count == 1, let url = files.urls.first,
           [.video, .audio].contains(SlotProvider.kind(of: DraggedFiles.type(of: url))) {
            requestMediaEstimates(url)
            return
        }
        guard files.urls.count == 1, let url = files.urls.first,
              DraggedFiles.type(of: url).conforms(to: .image) else { return }
        let formats = (menu.ring.compactMap { $0 } + menu.fan).compactMap { slot -> OutputFormat? in
            if case let .convert(f) = slot.action { return f }
            return nil
        }
        Task.detached(priority: .utility) {
            let estimates = SizeEstimator.estimate(url, formats: formats)
            await MainActor.run { [weak self] in
                guard let self, self.isVisible, self.files.urls.first == url, !estimates.isEmpty else { return }
                func hinted(_ slot: WheelSlot) -> WheelSlot {
                    var slot = slot
                    if case let .convert(f) = slot.action, let bytes = estimates[f] { slot.hint = SizeEstimator.describe(bytes) }
                    return slot
                }
                self.menu.ring = self.menu.ring.map { $0.map(hinted) }
                self.menu.fan = self.menu.fan.map(hinted)
                self.renderer?.updateHints(self.menu)
            }
        }
    }

    private static func circleMask(diameter d: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    // MARK: Pointer

    private func offset(of point: CGPoint) -> CGPoint {
        let size = geometry.size
        return CGPoint(x: point.x - size / 2, y: size / 2 - point.y) // host is y-up; geometry is y-down
    }

    private func target(at point: CGPoint) -> WheelTarget {
        var t = geometry.hitTest(offset(of: point), fanCount: menu.fan.count, fanOpen: state.fanOpen,
                                 fanFlipped: state.fanFlipped)
        if case let .segment(i) = t, menu.ring[i] == nil { t = .none } // empty segments are inert
        return t
    }

    func dragPointer(at point: CGPoint) {
        guard isVisible, !finishing, mode == .drag else { return }
        let o = offset(of: point)
        if geometry.isBeyondDismissDistance(o, fanCount: menu.fan.count, fanOpen: state.fanOpen, fanFlipped: state.fanFlipped) {
            dismissDuringDrag()
            return
        }
        updateHover(target(at: point), cursor: o)
    }

    /// The gesture sampler's view of the pointer during a drag. Works even if
    /// the window server never delivers drag events to the panel.
    func trackDrag(screenPoint: CGPoint) {
        guard isVisible, !finishing, mode == .drag, let point = hostPoint(fromScreen: screenPoint) else { return }
        lastDragPoint = point
        dragPointer(at: point)
    }

    /// The mouse button went up during a drag with the wheel showing. A normal
    /// drop arrives through performDrop; if it hasn't within a moment, choose
    /// from the pointer position with the files read when the wheel opened.
    func dragEnded(screenPoint: CGPoint) {
        guard isVisible, mode == .drag else { return }
        let point = hostPoint(fromScreen: screenPoint) ?? lastDragPoint
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown, self.isVisible, !self.finishing, self.mode == .drag else { return }
                guard let point else { self.hide(animated: true); return }
                let t = self.target(at: point)
                guard let slot = self.menu.slot(for: t), slot.action != .more, !self.files.urls.isEmpty else {
                    Log.wheel.notice("Released without a choice (target \(String(describing: t), privacy: .public))")
                    self.finish(WheelChoice(action: nil, label: "Cancel", files: [], count: self.files.count), target: t, cursor: nil)
                    return
                }
                Log.wheel.notice("Drop not delivered by the system; choosing from the pointer instead")
                self.finish(WheelChoice(action: slot.action, label: slot.verb, files: self.files.urls, count: self.files.urls.count),
                            target: t, cursor: self.offset(of: point))
            }
        }
    }

    private func hostPoint(fromScreen screenPoint: CGPoint) -> CGPoint? {
        guard let panel, let host else { return nil }
        let inWindow = panel.convertPoint(fromScreen: screenPoint)
        return host.convert(inWindow, from: nil)
    }

    func dragExited() {
        guard isVisible, !finishing, mode == .drag else { return }
        dismissDuringDrag()
    }

    private func dismissDuringDrag() {
        Log.wheel.notice("Drag left the wheel: hiding, drag continues")
        hide(animated: true)
        onDragDismissed?()
    }

    func clickPointer(at point: CGPoint) {
        guard isVisible, !finishing, mode == .click else { return }
        updateHover(target(at: point), cursor: offset(of: point))
    }

    private func updateHover(_ newTarget: WheelTarget, cursor: CGPoint?) {
        var next = state
        next.cursor = cursor
        next.hover = newTarget
        let moreIndex = menu.moreIndex
        switch newTarget {
        case let .segment(i) where i == moreIndex:
            // Start the rest-on-More timer once; pointer updates arrive ~60×/s
            // and must not keep restarting it.
            if !state.fanOpen, state.hover != newTarget || moreTimer == nil { scheduleFanOpen() }
        case .fanChip:
            break
        case .none:
            break // travelling between More and the fan: keep it as it is
        default:
            moreTimer?.cancel()
            moreTimer = nil
            next.fanOpen = false
        }
        guard next != state else { return }
        let changedTarget = next.hover != state.hover
        state = next
        renderer?.apply(state, animated: true)
        if changedTarget {
            updateLoupe()
            updateGIFPreview()
        }
        if changedTarget, newTarget != .none, settings.value(SettingsKeys.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if changedTarget, newTarget != .none { WheelSounds.play(.hover, pack: settings.value(SettingsKeys.soundPack)) }
        if changedTarget, case let .segment(i) = newTarget, menu.ring[i] != nil {
            let c = CGPoint(x: geometry.size / 2, y: geometry.size / 2)
            effects.spark(at: layerPoint(WheelGeometry.offset(radius: geometry.contentRadius(hovered: true),
                                                              angle: WheelGeometry.midAngle(ofSlot: i)), center: c))
        }
        if changedTarget, let host { NSAccessibility.post(element: host, notification: .layoutChanged) }
    }

    /// The before/after close-up beside a hovered JPG / HEIC / Compress segment.
    private func updateLoupe() {
        guard settings.value(SettingsKeys.beforeAfter), !state.fanOpen, files.urls.count == 1, let url = files.urls.first,
              case let .segment(i) = state.hover, let slot = menu.ring[i],
              let spec = BeforeAfterLoupe.spec(for: slot.action, url: url, settings: settings) else {
            loupe.hide()
            return
        }
        if loupe.layer.superlayer == nil || loupe.layer.superlayer?.sublayers?.last !== loupe.layer {
            layerView?.layer?.addSublayer(loupe.layer) // on top of the renderer
        }
        let s = geometry.scale, size = geometry.size, half = 68 * s + 6
        let o = WheelGeometry.offset(radius: geometry.outerExtent + 70 * s, angle: WheelGeometry.midAngle(ofSlot: i))
        let center = CGPoint(x: min(max(size / 2 + o.x, half), size - half), y: min(max(size / 2 - o.y, half), size - half))
        loupe.show(url: url, spec: spec, at: center, scale: s, accent: Appearance.accent(settings), contentsScale: contentsScale)
    }

    /// For tests: whether the before/after close-up is showing.
    var isLoupeVisible: Bool { loupe.layer.opacity > 0.5 && loupe.layer.superlayer != nil }

    /// For tests: whether the More fan is open.
    var isFanOpen: Bool { state.fanOpen }

    private func scheduleFanOpen() {
        moreTimer?.cancel()
        let delay = Double(settings.value(SettingsKeys.moreHoverDelayMs)) / 1000
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.moreTimer = nil
                guard let self, self.isVisible, self.state.hover == .segment(self.menu.moreIndex ?? -1) else { return }
                self.state.fanOpen = true
                self.renderer?.apply(self.state, animated: true)
            }
        }
        moreTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Choosing

    func performDrop(_ info: NSDraggingInfo, at point: CGPoint) -> Bool {
        guard isVisible, !finishing else { return false }
        let t = target(at: point)
        let dropped = DraggedFiles.read(info.draggingPasteboard)
        guard let slot = menu.slot(for: t), slot.action != .more else {
            finish(WheelChoice(action: nil, label: "Cancel", files: [], count: files.count), target: t, cursor: nil)
            return false // nothing happens; the source animates the drag back
        }
        if dropped.urls.isEmpty,
           let receivers = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            receivePromises(receivers, slot: slot, target: t, cursor: offset(of: point))
            return true
        }
        finish(WheelChoice(action: slot.action, label: slot.verb, files: dropped.urls, count: dropped.urls.count),
               target: t, cursor: offset(of: point))
        return true
    }

    /// Files promised by Photos, Mail or a browser are written into a private
    /// temporary inbox first (PLAN.md §3.3).
    private func receivePromises(_ receivers: [NSFilePromiseReceiver], slot: WheelSlot, target: WheelTarget, cursor: CGPoint) {
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.name)-Inbox", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let collector = PromiseCollector(expected: receivers.count)
        let label = slot.verb, action = slot.action
        usage(action)
        finish(nil, target: target, cursor: cursor) // animate now; report when files land
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: inbox, options: [:], operationQueue: queue) { [weak self] url, error in
                if let error { Log.wheel.error("Promise failed: \(error.localizedDescription, privacy: .public)") }
                let done = collector.add(error == nil ? url : nil)
                guard let urls = done else { return }
                Task { @MainActor in
                    Log.wheel.notice("Received \(urls.count, privacy: .public) promised file(s)")
                    self?.onFinished?(WheelChoice(action: action, label: label, files: urls, count: urls.count))
                }
            }
        }
    }

    func click(at point: CGPoint) {
        guard isVisible, !finishing, mode == .click else { return }
        let t = target(at: point)
        if t == .none {
            cancelFromKeyboard()
            return
        }
        choose(t)
    }

    private func choose(_ t: WheelTarget) {
        if case let .segment(i) = t, i == menu.moreIndex {
            state.hover = t
            state.fanOpen = true
            renderer?.apply(state, animated: true)
            return
        }
        guard let slot = menu.slot(for: t) else {
            finish(WheelChoice(action: nil, label: "Cancel", files: [], count: files.count), target: t, cursor: nil)
            return
        }
        finish(WheelChoice(action: slot.action, label: slot.verb, files: files.urls, count: files.count),
               target: t, cursor: state.cursor)
    }

    func cancelFromKeyboard() {
        guard isVisible, !finishing else { return }
        if state.fanOpen {
            state.fanOpen = false
            state.hover = menu.moreIndex.map { .segment($0) } ?? .none
            renderer?.apply(state, animated: true)
            return
        }
        finish(WheelChoice(action: nil, label: "Cancel", files: [], count: files.count), target: .centre, cursor: nil)
    }

    /// Arrow keys move around the ring (or along the open fan); Return chooses.
    func key(_ event: NSEvent) -> Bool {
        guard isVisible, mode == .click else { return false }
        switch event.keyCode {
        case 36, 76: // Return, Enter
            choose(state.hover == .none ? .centre : state.hover)
        case 123, 126: step(-1) // ← ↑
        case 124, 125: step(1)  // → ↓
        default:
            return false
        }
        return true
    }

    private func step(_ delta: Int) {
        if state.fanOpen, !menu.fan.isEmpty {
            let current: Int = { if case let .fanChip(k) = state.hover { return k }; return -1 }()
            let next = current < 0 ? 0 : (current + delta + menu.fan.count) % menu.fan.count
            updateHover(.fanChip(next), cursor: nil)
            return
        }
        let filled = menu.ring.indices.filter { menu.ring[$0] != nil }
        guard !filled.isEmpty else { return }
        let current: Int? = { if case let .segment(i) = state.hover { return filled.firstIndex(of: i) }; return nil }()
        let next = current.map { (($0 + delta) % filled.count + filled.count) % filled.count } ?? 0
        updateHover(.segment(filled[next]), cursor: nil)
    }

    private func finish(_ choice: WheelChoice?, target: WheelTarget, cursor: CGPoint?) {
        finishing = true
        moreTimer?.cancel()
        if let choice, !PracticeFiles.all(choice.files) { usage(choice.action) }
        if choice != nil || target != .centre, target != .none {
            WheelSounds.play(target == .centre ? .cancel : .choose, pack: settings.value(SettingsKeys.soundPack))
        }
        renderer?.release(to: target, from: cursor)
        if let choice {
            Log.wheel.notice("Wheel choice: \(choice.label, privacy: .public) for \(choice.count, privacy: .public) item(s)")
            onFinished?(choice)
        }
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduceMotion ? 0 : 0.18)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.hide(animated: true)
            }
        }
    }

    private func usage(_ action: WheelAction?) {
        guard let action else { return }
        var counts = settings.value(SettingsKeys.wheelUsage)
        counts[action.usageKey, default: 0] += 1
        settings.set(counts, for: SettingsKeys.wheelUsage)
    }

    // MARK: Outside clicks (click mode)

    /// Clicks and moves that reach other apps: outside the wheel they cancel;
    /// on the wheel (if the system ever lets one through) they act on it.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved]) { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handleGlobal(type, at: location) }
        }
    }

    private func handleGlobal(_ type: NSEvent.EventType, at screenPoint: CGPoint) {
        guard isVisible, mode == .click else { return }
        let point = hostPoint(fromScreen: screenPoint)
        let onWheel = point.map { target(at: $0) != .none } ?? false
        switch type {
        case .mouseMoved:
            if let point { clickPointer(at: point) }
        case .leftMouseDown where onWheel:
            if let point { click(at: point) }
        default:
            cancelFromKeyboard()
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: Accessibility

    func accessibilityElements() -> [Any] {
        guard isVisible, let host, let window = host.window else { return [] }
        var elements: [Any] = []
        let s = geometry.scale
        func screenRect(_ offset: CGPoint, _ size: CGFloat) -> CGRect {
            let p = CGPoint(x: geometry.size / 2 + offset.x, y: geometry.size / 2 - offset.y)
            return window.convertToScreen(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
        }
        for (i, slot) in menu.ring.enumerated() {
            guard let slot else { continue }
            let o = WheelGeometry.offset(radius: geometry.contentRadius(hovered: false), angle: WheelGeometry.midAngle(ofSlot: i))
            elements.append(WheelAccessibilityElement(label: slot.verb, frame: screenRect(o, 70 * s), parent: host) { [weak self] in
                self?.choose(.segment(i))
            })
        }
        if state.fanOpen {
            for (k, o) in geometry.fanOffsets(count: menu.fan.count, flipped: state.fanFlipped).enumerated() {
                elements.append(WheelAccessibilityElement(label: menu.fan[k].verb, frame: screenRect(o, 56 * s), parent: host) { [weak self] in
                    self?.choose(.fanChip(k))
                })
            }
        }
        elements.append(WheelAccessibilityElement(label: "Cancel", frame: screenRect(.zero, geometry.orbDiameter * s), parent: host) { [weak self] in
            self?.choose(.centre)
        })
        return elements
    }
}

/// Collects the results of several promise receptions (any thread).
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private var received: [URL] = []
    private var finished = 0

    init(expected: Int) { self.expected = expected }

    /// Returns all URLs once every promise has reported, otherwise nil.
    func add(_ url: URL?) -> [URL]? {
        lock.lock(); defer { lock.unlock() }
        if let url { received.append(url) }
        finished += 1
        return finished == expected ? received : nil
    }
}

/// Carries a non-Sendable value across a hop the caller knows is safe.
nonisolated struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
