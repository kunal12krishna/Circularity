import AppKit

/// Opt-in update checks (Settings → General): fetches the small
/// `appcast.json` named by the build's `CircularityUpdateFeedURL` and offers
/// to open the download. The only network use in the app; nothing about the
/// user or their files is sent. Off by default.
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle, checking, upToDate, available(UpdateFeed), failed(String), noFeed
    }

    @Published private(set) var status = Status.idle
    /// Installs a signed update in place (UpdateInstaller).
    let installer = UpdateInstaller()
    private let settings: SettingsStore
    var onAvailable: ((UpdateFeed, _ automatic: Bool) -> Void)?

    init(settings: SettingsStore) { self.settings = settings }

    static var feedURL: URL? {
        #if DEBUG
        // Testing only: a local feed (http://127.0.0.1…) for the in-place install.
        if let s = ProcessInfo.processInfo.environment["CIRCULARITY_UPDATE_FEED"], let url = URL(string: s) { return url }
        #endif
        guard let s = Bundle.main.object(forInfoDictionaryKey: "CircularityUpdateFeedURL") as? String,
              !s.trimmingCharacters(in: .whitespaces).isEmpty, let url = URL(string: s), url.scheme == "https" else { return nil }
        return url
    }

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// At launch or when the panel opens: checks only if switched on and a day has passed.
    func checkIfDue() {
        guard settings.value(SettingsKeys.updatesAutomatic), Self.feedURL != nil else { return }
        let last = settings.value(SettingsKeys.updatesLastCheck)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check(automatic: true)
    }

    func check(automatic: Bool = false) {
        guard let url = Self.feedURL else { status = .noFeed; return }
        guard status != .checking else { return }
        status = .checking
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("\(AppIdentity.name)/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        Task {
            let status: Status
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
                status = VersionCompare.isNewer(feed.version, than: Self.currentVersion) ? .available(feed) : .upToDate
            } catch {
                status = .failed(error.localizedDescription)
            }
            self.status = status
            // Success waits a day; a failure (offline at login, a timeout) retries in about an hour.
            let now = Date().timeIntervalSince1970
            if case .failed = status { settings.set(now - 23 * 3600, for: SettingsKeys.updatesLastCheck) }
            else { settings.set(now, for: SettingsKeys.updatesLastCheck) }
            Log.app.notice("Update check: \(String(describing: status), privacy: .public)")
            if case let .available(feed) = status { onAvailable?(feed, automatic) }
        }
    }

    /// Opens the download in the browser (the DMG installs like the first time).
    static func download(_ feed: UpdateFeed) {
        guard let url = URL(string: feed.url), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
}
