import ServiceManagement

/// Launch at login through SMAppService (macOS 13+, no helper app). The
/// system is the source of truth: the user can also switch it off in
/// System Settings → General → Login Items.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    /// Returns an error message, or nil on success.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                if status != .enabled { try SMAppService.mainApp.register() }
            } else if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            Log.app.notice("Launch at login \(on ? "on" : "off", privacy: .public) (status \(status.rawValue, privacy: .public))")
            return nil
        } catch {
            Log.app.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
