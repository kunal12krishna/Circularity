import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launch = LaunchArguments(CommandLine.arguments)
    private let singleInstance = SingleInstance()
    private var coordinator: AppCoordinator?
    /// Set when another copy was already running; this copy hands off and quits.
    private var primary: NSRunningApplication?
    private var didFinishLaunching = false
    /// Files from `application(_:open:)` that arrive before launch finishes.
    private var filesOpenedBeforeLaunch: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard launch.renderPreviewsDirectory == nil else { return }
        primary = singleInstance.primaryInstance()
        if primary == nil {
            // Listen before launch finishes: a later copy waits for
            // isFinishedLaunching before it sends, so nothing is missed.
            singleInstance.listen { [weak self] urls in self?.handleHandOff(urls) }
        }
    }

    /// Files (or a bare "show yourself") from a later copy of the app.
    private func handleHandOff(_ urls: [URL]) {
        guard let coordinator else {
            filesOpenedBeforeLaunch += urls
            return
        }
        if urls.isEmpty { coordinator.handleReopen() } else { coordinator.receive(urls, from: .handOff) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true

        if let directory = launch.renderPreviewsDirectory {
            exit(RenderPreviews.run(into: directory) ? 0 : 1)
        }

        let files = filesOpenedBeforeLaunch + launch.files
        filesOpenedBeforeLaunch = []

        if let primary {
            Log.platform.notice("Already running (pid \(primary.processIdentifier, privacy: .public)): handing off \(files.count, privacy: .public) file(s) and quitting")
            singleInstance.handOff(files, to: primary) { NSApp.terminate(nil) }
            return
        }

        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
        coordinator.receive(files, from: .launch)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let primary {
            if didFinishLaunching {
                singleInstance.handOff(urls, to: primary) {}
            } else {
                filesOpenedBeforeLaunch += urls
            }
        } else if let coordinator {
            coordinator.receive(urls, from: .openEvent)
        } else {
            filesOpenedBeforeLaunch += urls
        }
    }

    /// Opening the app again (Finder, Spotlight, `open -a`) while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.handleReopen()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
