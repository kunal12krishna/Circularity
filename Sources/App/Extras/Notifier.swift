import AppKit
import CircularityEngine
import UserNotifications

/// Opt-in notifications when a conversion finishes (Settings → Notifications),
/// with Open and Reveal actions. Nothing is requested until the user turns
/// them on.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private static let category = "result"
    private static let openAction = "open"
    private static let revealAction = "reveal"

    /// Sets the delegate (so action buttons work after a relaunch) without asking for anything.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open")
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [open, reveal],
                                                                 intentIdentifiers: [])])
    }

    /// Asks macOS for permission; `done(true)` if granted.
    func requestPermission(_ done: @escaping (Bool) -> Void) {
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            Log.app.notice("Notifications \(granted ? "allowed" : "not allowed", privacy: .public)")
            done(granted)
        }
    }

    /// "authorized", "denied" or "not asked".
    func status(_ done: @escaping (String) -> Void) {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let status: String = switch settings.authorizationStatus {
            case .authorized, .provisional: "allowed"
            case .denied: "denied"
            default: "not asked"
            }
            done(status)
        }
    }

    func post(title: String, body: String, outputs: [URL], sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if !outputs.isEmpty {
            content.categoryIdentifier = Self.category
            content.userInfo = ["paths": outputs.prefix(20).map(\.path)]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.app.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Posts a finished job, if notifications are on.
    func jobFinished(title: String, result: Result<JobResult, Error>, settings: SettingsStore) {
        guard settings.value(SettingsKeys.notifyEnabled) else { return }
        let sound = settings.value(SettingsKeys.notifySound)
        switch result {
        case let .success(r):
            post(title: r.outputs.isEmpty ? "Nothing to do" : "Converted", body: JobCenter.summary(r), outputs: r.outputs, sound: sound)
        case let .failure(error) where !(error is CancellationError):
            post(title: "Couldn't convert", body: "\(title): \(error.localizedDescription)", outputs: [], sound: sound)
        case .failure:
            break
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        let action = response.actionIdentifier
        await MainActor.run {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return }
            if action == Self.openAction {
                for url in urls.prefix(5) { NSWorkspace.shared.open(url) }
            } else {
                // The banner itself, or "Show in Finder".
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }
}
