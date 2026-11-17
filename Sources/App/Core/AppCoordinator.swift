import AppKit

/// Where files handed to the app came from.
enum FileSource: String {
    case launch, openEvent, handOff
}

/// The composition root (PLAN.md §1): owns every long-lived controller and
/// builds the heavy ones lazily. Milestone (a) has only the status item.
final class AppCoordinator {
    let settings: SettingsStore
    private var statusItem: StatusItemController?
    /// The most recent files handed to the app. Later milestones use this as the
    /// target for ⌃⌥C, ⌘K and preset tiles (PLAN.md A3).
    private(set) var recentFiles: [URL] = []

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
    }

    func start() {
        if settings.value(SettingsKeys.showInMenuBar) {
            statusItem = StatusItemController()
        }
        Log.app.notice("\(AppIdentity.name, privacy: .public) started (pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public))")
    }

    func receive(_ urls: [URL], from source: FileSource) {
        guard !urls.isEmpty else { return }
        recentFiles = urls
        statusItem?.showReceived(urls)
        Log.app.notice("Received \(urls.count, privacy: .public) file(s) via \(source.rawValue, privacy: .public): \(urls.map(\.lastPathComponent).joined(separator: ", "), privacy: .private)")
    }

    /// Opening the app again shows the menu bar icon even if it was hidden
    /// (BRIEF.md: "opening the app again shows it").
    func handleReopen() {
        Log.app.notice("Reopen requested")
        if statusItem == nil {
            settings.set(true, for: SettingsKeys.showInMenuBar)
            statusItem = StatusItemController()
        }
    }
}
