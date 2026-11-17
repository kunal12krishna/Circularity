import os

/// os.Logger categories (PLAN.md §3.8). Subsystem = bundle ID.
/// Watch live with: log stream --level info --predicate 'subsystem == "com.kunal.circularity"'
nonisolated enum Log {
    static let app = Logger(subsystem: AppIdentity.bundleID, category: "app")
    static let menubar = Logger(subsystem: AppIdentity.bundleID, category: "menubar")
    static let platform = Logger(subsystem: AppIdentity.bundleID, category: "platform")
    static let perf = Logger(subsystem: AppIdentity.bundleID, category: "perf")
    static let gesture = Logger(subsystem: AppIdentity.bundleID, category: "gesture")
    static let wheel = Logger(subsystem: AppIdentity.bundleID, category: "wheel")
}
