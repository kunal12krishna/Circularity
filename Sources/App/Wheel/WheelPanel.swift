import AppKit

/// The wheel window (PLAN.md §3.3): borderless, non-activating, above menus,
/// on every Space including full-screen ones. Built once, then reused.
final class WheelPanel: NSPanel {
    /// Only click mode takes keyboard focus; drag mode never does.
    var allowsKey = false

    init() {
        // Created up front (not deferred) so the window server knows it accepts drags.
        super.init(contentRect: CGRect(x: 0, y: 0, width: 720, height: 720),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Status-bar level: above normal windows and the Dock, and a level the
        // drag system delivers to (menu bar items accept drops there).
        level = .statusBar
        // A transparent window lets clicks and drags fall through to whatever is
        // underneath unless this is set explicitly.
        ignoresMouseEvents = false
        registerForDraggedTypes(WheelHostView.dragTypes)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Receives drags, pointer and keys for the wheel and forwards them to the
/// controller. All subviews are purely visual.
final class WheelHostView: NSView {
    weak var controller: WheelController?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        registerForDraggedTypes(Self.dragTypes)
    }

    static let dragTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Drag destination — always answer with Copy (never Move).

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragPointer(at: convert(sender.draggingLocation, from: nil))
        return Self.copyOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragPointer(at: convert(sender.draggingLocation, from: nil))
        return Self.copyOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.performDrop(sender, at: convert(sender.draggingLocation, from: nil)) ?? false
    }

    private static func copyOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        info.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    // MARK: Click mode

    override func mouseMoved(with event: NSEvent) {
        controller?.clickPointer(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        controller?.click(at: convert(event.locationInWindow, from: nil))
    }

    /// Click mode: a wheel key switches wheels, as it does mid-drag.
    override func flagsChanged(with event: NSEvent) {
        controller?.modifiersChanged(event.modifierFlags)
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.key(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.cancelFromKeyboard()
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "\(AppIdentity.name) wheel" }
    override func accessibilityChildren() -> [Any]? { controller?.accessibilityElements() }
}

/// One wheel button for VoiceOver. Accessibility calls arrive on the main thread.
nonisolated final class WheelAccessibilityElement: NSAccessibilityElement {
    private let onPress: @MainActor @Sendable () -> Void

    init(label: String, frame: CGRect, parent: Any, onPress: @escaping @MainActor @Sendable () -> Void) {
        self.onPress = onPress
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityFrame(frame)
        setAccessibilityParent(parent)
    }

    override func accessibilityPerformPress() -> Bool {
        let press = onPress
        MainActor.assumeIsolated { press() }
        return true
    }
}
