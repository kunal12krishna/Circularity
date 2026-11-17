import Foundation

/// The app's name and bundle ID. Both come from `Config/Identity.xcconfig`
/// (the single source) through the `CircularityAppName` / `CircularityAppBundleID`
/// Info.plist keys, so renaming the app never touches Swift code.
nonisolated enum AppIdentity {
    static let name: String = infoValue("CircularityAppName")
    static let bundleID: String = infoValue("CircularityAppBundleID")

    /// Name used for distributed notifications and other per-app identifiers.
    static func scoped(_ suffix: String) -> String { "\(bundleID).\(suffix)" }

    private static func infoValue(_ key: String) -> String {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty {
            return value
        }
        // Only reachable in a bundle that was built without Identity.xcconfig
        // (for example the host-less unit-test runner). Never shown to users.
        return "Circularity.unconfigured"
    }
}
