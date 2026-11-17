import AppKit

/// "Convert with Circularity" in Finder's Quick Actions/Services menu, and the
/// permission-free route to the Finder selection via its keyboard shortcut
/// (PLAN.md A3). macOS hands over the selected files; no Automation needed.
final class ServicesProvider: NSObject {
    static let menuTitle = "Convert with \(AppIdentity.name)"
    static let message = "convertFiles"

    var onFiles: (([URL]) -> Void)?

    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = DraggedFiles.read(pasteboard).urls
        Log.platform.notice("Service invoked with \(urls.count, privacy: .public) file(s)")
        guard !urls.isEmpty else {
            error.pointee = "No files were selected." as NSString
            return
        }
        onFiles?(urls)
    }
}

/// Sets the Service's keyboard shortcut to ⌃⌥C in the user's own Services
/// preferences — the same setting as System Settings → Keyboard → Keyboard
/// Shortcuts → Services. Service shortcuts declared in Info.plist must use ⌘,
/// so this is the only way to get ⌃⌥C without asking the user to set it.
enum ServiceShortcut {
    static let keyEquivalent = "^~c" // ⌃⌥C
    private static let domain = "pbs" as CFString
    private static let statusKey = "NSServicesStatus" as CFString
    private static var entryKey: String { "\(AppIdentity.bundleID) - \(ServicesProvider.menuTitle) - \(ServicesProvider.message)" }

    static var isInstalled: Bool {
        guard let status = CFPreferencesCopyAppValue(statusKey, domain) as? [String: Any],
              let entry = status[entryKey] as? [String: Any] else { return false }
        return entry["key_equivalent"] as? String == keyEquivalent
    }

    /// Writes the shortcut and asks the services daemon to reload. Returns
    /// whether the value reads back; the shortcut itself is verified by use.
    @discardableResult
    static func install() -> Bool {
        var status = (CFPreferencesCopyAppValue(statusKey, domain) as? [String: Any]) ?? [:]
        var entry = (status[entryKey] as? [String: Any]) ?? [:]
        entry["key_equivalent"] = keyEquivalent
        entry["enabled_context_menu"] = true
        entry["enabled_services_menu"] = true
        entry["presentation_modes"] = ["ContextMenu": true, "ServicesMenu": true]
        status[entryKey] = entry
        CFPreferencesSetAppValue(statusKey, status as CFDictionary, domain)
        let synced = CFPreferencesAppSynchronize(domain)
        refreshServices()
        let ok = synced && isInstalled
        Log.platform.notice("Service shortcut ⌃⌥C \(ok ? "written" : "could not be written", privacy: .public)")
        return ok
    }

    /// Removes the shortcut again (the Service stays in the right-click menu).
    @discardableResult
    static func uninstall() -> Bool {
        var status = (CFPreferencesCopyAppValue(statusKey, domain) as? [String: Any]) ?? [:]
        guard var entry = status[entryKey] as? [String: Any] else { return true }
        entry["key_equivalent"] = ""
        status[entryKey] = entry
        CFPreferencesSetAppValue(statusKey, status as CFDictionary, domain)
        let synced = CFPreferencesAppSynchronize(domain)
        refreshServices()
        Log.platform.notice("Service shortcut ⌃⌥C removed")
        return synced && !isInstalled
    }

    static func refreshServices() {
        NSUpdateDynamicServices()
        let pbs = Process()
        pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        pbs.arguments = ["-update"]
        try? pbs.run()
    }

    /// Finder reads Services shortcuts when it starts, so a new shortcut only
    /// works after Finder relaunches. Offers to do that (it reopens by itself).
    static func offerFinderRelaunch(turnedOn: Bool = true) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = turnedOn ? "⌃⌥C is ready" : "⌃⌥C is turned off"
        alert.informativeText = "Finder picks up keyboard shortcut changes when it restarts. Relaunch Finder now? Its windows reopen by themselves."
        alert.addButton(withTitle: "Relaunch Finder")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Finder"]
        try? killall.run()
        Log.platform.notice("Relaunched Finder so it picks up the ⌃⌥C Service shortcut")
    }

    /// Fallback: the Keyboard Shortcuts pane where the user can set it by hand.
    static func openKeyboardSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts",
                    "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
