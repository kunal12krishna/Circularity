import AppKit

/// The menu bar item. Milestone (a): the static idle glyph and a placeholder
/// menu. Milestone (h) replaces the menu with the custom glass panel, the
/// animated icon states and drop-on-icon.
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let receivedItem = NSMenuItem(title: "No files received yet", action: nil, keyEquivalent: "")

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = item.button {
            button.image = StatusGlyph.image()
            button.setAccessibilityLabel(AppIdentity.name)
            button.toolTip = AppIdentity.name
        }
        item.menu = makeMenu()
        Log.menubar.notice("Status item installed")
    }

    func showReceived(_ urls: [URL]) {
        let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
        let more = urls.count > 3 ? " +\(urls.count - 3) more" : ""
        let noun = urls.count == 1 ? "file" : "files"
        receivedItem.title = "Received \(urls.count) \(noun): \(names)\(more)"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let title = NSMenuItem(title: "\(AppIdentity.name) \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        receivedItem.isEnabled = false
        menu.addItem(receivedItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(AppIdentity.name)",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    /// Removes the icon from the menu bar ("Show in menu bar" off).
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }
}
