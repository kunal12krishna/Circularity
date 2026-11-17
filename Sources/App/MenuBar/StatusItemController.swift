import AppKit

/// Menu items that run a closure (stored in `representedObject`).
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

/// The menu bar item. Milestones (a–c): the idle glyph and a developer menu
/// (built fresh each time it opens). Milestone (h) replaces the menu with the
/// custom glass panel, the animated icon states and drop-on-icon.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menuBuilder: () -> [NSMenuItem]

    init(menuBuilder: @escaping () -> [NSMenuItem]) {
        self.menuBuilder = menuBuilder
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.image = StatusGlyph.image()
            button.setAccessibilityLabel(AppIdentity.name)
            button.toolTip = AppIdentity.name
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        Log.menubar.notice("Status item installed")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in menuBuilder() { menu.addItem(entry) }
    }

    /// Removes the icon from the menu bar ("Show in menu bar" off).
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }
}

extension NSMenuItem {
    static func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
