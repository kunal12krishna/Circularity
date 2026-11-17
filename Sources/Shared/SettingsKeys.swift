import Foundation

/// A typed settings key. `Value` is always a property-list type so it can be
/// stored in UserDefaults and exported to JSON unchanged.
nonisolated struct SettingsKey<Value: Sendable & Equatable>: Sendable {
    let name: String
    let defaultValue: Value
    /// Reserved for v1.1: declared now so the schema is stable, but no UI or
    /// behaviour reads it yet (PLAN.md §3.7, §7).
    let reserved: Bool

    init(_ name: String, _ defaultValue: Value, reserved: Bool = false) {
        self.name = name
        self.defaultValue = defaultValue
        self.reserved = reserved
    }

    var erased: AnySettingsKey { AnySettingsKey(name: name, defaultValue: defaultValue, reserved: reserved) }
}

nonisolated struct AnySettingsKey: Sendable {
    let name: String
    let defaultValue: any Sendable
    let reserved: Bool
}

/// Every settings key, declared once. Milestones add keys here as features land.
nonisolated enum SettingsKeys {
    /// Bumped when a key is renamed or its meaning changes; drives migrations.
    static let schemaVersion = 1
    static let schemaVersionKey = "settings.schemaVersion"

    // MARK: General
    static let paused = SettingsKey("general.paused", false)
    static let showInMenuBar = SettingsKey("general.showInMenuBar", true)
    static let launchAtLogin = SettingsKey("general.launchAtLogin", true)
    static let onboardingCompleted = SettingsKey("general.onboardingCompleted", false)

    // MARK: Gesture (all three triggers on by default, PLAN.md A3)
    static let triggerKey = SettingsKey("gesture.triggerKey", "shift")          // shift | option | control
    static let triggerMode = SettingsKey("gesture.triggerMode", "tap")          // tap | hold
    static let triggerDelayMs = SettingsKey("gesture.triggerDelayMs", 0)
    static let shakeEnabled = SettingsKey("gesture.shake.enabled", true)
    static let shakeSensitivity = SettingsKey("gesture.shake.sensitivity", "medium") // low | medium | high
    static let skipFullScreen = SettingsKey("gesture.skipFullScreen", true)
    static let serviceShortcutInstalled = SettingsKey("gesture.serviceShortcutInstalled", false)

    // MARK: Looks
    static let wheelLayout = SettingsKey("wheel.layout", "ring")                // ring | orbit | halo
    static let theme = SettingsKey("appearance.theme", "tangerine")
    static let accentHex = SettingsKey("appearance.accentHex", "#FF8A00")

    // MARK: Menu bar
    static let panelLayout = SettingsKey("menubar.layout", "stackPlus")         // stackPlus | tabs | mini
    static let panelWidth = SettingsKey("menubar.width", "m")                   // s | m | l
    static let iconStyle = SettingsKey("menubar.iconStyle", "monochrome")       // monochrome | colour | minimal

    // MARK: Reserved for v1.1 (no UI, no behaviour)
    static let mediaPackEnabled = SettingsKey("media.packEnabled", false, reserved: true)
    static let mediaBundleMode = SettingsKey("media.bundleMode", "download", reserved: true)
    static let updatesChannel = SettingsKey("updates.channel", "stable", reserved: true)
    static let updatesAutomatic = SettingsKey("updates.automatic", true, reserved: true)
    static let cliInstalled = SettingsKey("cli.installed", false, reserved: true)
    static let urlSchemeEnabled = SettingsKey("urlScheme.enabled", false, reserved: true)
    static let shortcutsEnabled = SettingsKey("shortcuts.enabled", false, reserved: true)
    static let officeAutomation = SettingsKey("office.automation", false, reserved: true)
    static let advancedEventTap = SettingsKey("gesture.advancedEventTap", false, reserved: true)
    static let finderSelectionViaAutomation = SettingsKey("gesture.finderSelectionViaAutomation", false, reserved: true)

    static let all: [AnySettingsKey] = [
        paused.erased, showInMenuBar.erased, launchAtLogin.erased, onboardingCompleted.erased,
        triggerKey.erased, triggerMode.erased, triggerDelayMs.erased, shakeEnabled.erased,
        shakeSensitivity.erased, skipFullScreen.erased, serviceShortcutInstalled.erased,
        wheelLayout.erased, theme.erased, accentHex.erased,
        panelLayout.erased, panelWidth.erased, iconStyle.erased,
        mediaPackEnabled.erased, mediaBundleMode.erased, updatesChannel.erased, updatesAutomatic.erased,
        cliInstalled.erased, urlSchemeEnabled.erased, shortcutsEnabled.erased, officeAutomation.erased,
        advancedEventTap.erased, finderSelectionViaAutomation.erased,
    ]
}
