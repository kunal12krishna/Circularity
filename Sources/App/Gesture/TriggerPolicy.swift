import AppKit

/// Decides, once per file drag, whether the wheel may appear (PLAN.md §3.2).
struct TriggerPolicy {
    enum Verdict: Equatable {
        case allowed
        case paused
        case excludedApp(String)
        case fullScreen(String)

        var isAllowed: Bool { self == .allowed }
        var reason: String {
            switch self {
            case .allowed: "allowed"
            case .paused: "paused"
            case let .excludedApp(id): "excluded app \(id)"
            case let .fullScreen(id): "full-screen app \(id)"
            }
        }
    }

    let settings: SettingsStore

    func evaluate() -> Verdict {
        if settings.value(SettingsKeys.paused) { return .paused }
        let front = NSWorkspace.shared.frontmostApplication
        let id = front?.bundleIdentifier ?? "unknown"
        if settings.value(SettingsKeys.excludedApps).contains(id) { return .excludedApp(id) }
        if settings.value(SettingsKeys.skipFullScreen), let front, Self.isFullScreen(front) { return .fullScreen(id) }
        return .allowed
    }

    /// A window of the frontmost app that exactly covers a screen. Uses only
    /// window bounds and owner PIDs, which need no Screen Recording permission
    /// (window titles are never read).
    static func isFullScreen(_ app: NSRunningApplication) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return false }
            return screens.contains { $0 == bounds.size }
        }
    }
}
