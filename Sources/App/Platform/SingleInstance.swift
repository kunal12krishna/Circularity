import AppKit
import Darwin

/// Keeps one running copy (PLAN.md §3.8).
///
/// - Which copy stays: the one whose process started first (kernel start
///   time, then pid), so two copies launched at the same moment can never
///   both decide to quit.
/// - How files move: the later copy waits until the running copy reports
///   `isFinishedLaunching` (it starts listening before that point), then posts
///   the file paths in a distributed notification and quits. An empty list
///   means "show yourself" (BRIEF.md: opening the app again shows the icon).
final class SingleInstance {
    nonisolated private static let openFiles = Notification.Name(AppIdentity.scoped("open-files"))
    nonisolated private static let pathsKey = "paths"
    nonisolated private static let handOffTimeout: TimeInterval = 5

    private var observer: NSObjectProtocol?
    private var launchObservation: NSKeyValueObservation?

    /// The copy that should keep running, if it is not this process.
    func primaryInstance() -> NSRunningApplication? {
        let me = getpid()
        let myStart = Self.startTime(of: me)
        return NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
            .first { other in
                guard let mine = myStart, let theirs = Self.startTime(of: other.processIdentifier) else {
                    return true // cannot tell: yield, never run two copies
                }
                return Self.startedFirst((theirs, other.processIdentifier), than: (mine, me))
            }
    }

    // MARK: Running copy

    /// Call as early as possible (applicationWillFinishLaunching) so no hand-off is missed.
    func listen(_ handler: @escaping @MainActor ([URL]) -> Void) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.openFiles, object: AppIdentity.bundleID, queue: .main
        ) { note in
            let paths = note.userInfo?[Self.pathsKey] as? [String] ?? []
            let urls = paths.map { URL(fileURLWithPath: $0) }
            MainActor.assumeIsolated { handler(urls) }
        }
    }

    func stopListening() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    // MARK: Later copy

    /// Sends `urls` to `primary` once it has finished launching, then calls `completion`.
    func handOff(_ urls: [URL], to primary: NSRunningApplication, completion: @escaping @MainActor () -> Void) {
        let paths = urls.map(\.path)
        var finished = false
        let send: @MainActor () -> Void = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.launchObservation = nil
            DistributedNotificationCenter.default().postNotificationName(
                Self.openFiles, object: AppIdentity.bundleID,
                userInfo: [Self.pathsKey: paths], deliverImmediately: true)
            completion()
        }
        if primary.isFinishedLaunching {
            send()
            return
        }
        launchObservation = primary.observe(\.isFinishedLaunching, options: [.new]) { app, _ in
            guard app.isFinishedLaunching else { return }
            Task { @MainActor in send() }
        }
        // Never hang: after the timeout, send anyway and quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handOffTimeout) {
            MainActor.assumeIsolated { send() }
        }
    }

    // MARK: Ordering

    /// Ordering used by `primaryInstance()`.
    nonisolated static func startedFirst(_ a: (timeval, pid_t), than b: (timeval, pid_t)) -> Bool {
        let (ta, pa) = a, (tb, pb) = b
        if ta.tv_sec != tb.tv_sec { return ta.tv_sec < tb.tv_sec }
        if ta.tv_usec != tb.tv_usec { return ta.tv_usec < tb.tv_usec }
        return pa < pb
    }

    /// Process start time from the kernel (no permission needed for own-user processes).
    nonisolated static func startTime(of pid: pid_t) -> timeval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_proc.p_starttime
    }
}
