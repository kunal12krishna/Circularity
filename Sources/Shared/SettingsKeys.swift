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

/// Every settings key, declared once. `all` drives defaults, export/import
/// and reset; SettingsKeysTests checks that every key is listed.
nonisolated enum SettingsKeys {
    /// Bumped when a key is renamed or its meaning changes; drives migrations.
    /// v2: one accent for every surface (Halo's neon moved into `accentHex`).
    static let schemaVersion = 2
    static let schemaVersionKey = "settings.schemaVersion"

    // MARK: General
    static let paused = SettingsKey("general.paused", false)
    static let showInMenuBar = SettingsKey("general.showInMenuBar", true)
    static let launchAtLogin = SettingsKey("general.launchAtLogin", true)
    static let onboardingCompleted = SettingsKey("general.onboardingCompleted", false)
    static let hotkeyPanel = SettingsKey("general.hotkey.panel", "49:6144")         // keyCode:carbonModifiers (⌃⌥Space); "" = off
    static let hotkeyClipboard = SettingsKey("general.hotkey.clipboard", "9:6144")  // ⌃⌥V

    // MARK: Gesture (all three triggers on by default, PLAN.md A3)
    static let triggerKey = SettingsKey("gesture.triggerKey", "shift")          // shift | option | control
    static let triggerMode = SettingsKey("gesture.triggerMode", "tap")          // tap | hold
    static let triggerDelayMs = SettingsKey("gesture.triggerDelayMs", 0)
    static let shakeEnabled = SettingsKey("gesture.shake.enabled", true)
    static let shakeSensitivity = SettingsKey("gesture.shake.sensitivity", "medium") // low | medium | high
    static let skipFullScreen = SettingsKey("gesture.skipFullScreen", true)
    static let serviceShortcutInstalled = SettingsKey("gesture.serviceShortcutInstalled", false)
    static let excludedApps = SettingsKey("gesture.excludedApps", [String]())     // bundle IDs

    // MARK: Wheel
    static let wheelLayout = SettingsKey("wheel.layout", "halo")                // ring | orbit | halo (Halo: the user's favourite)
    static let moreHoverDelayMs = SettingsKey("wheel.moreHoverDelayMs", 150)
    static let smartOrdering = SettingsKey("wheel.smartOrdering", true)
    static let haptics = SettingsKey("wheel.haptics", true)
    static let beforeAfter = SettingsKey("wheel.beforeAfter", true)             // close-up loupe for JPG/HEIC/Compress
    static let soundPack = SettingsKey("wheel.soundPack", "off")                // off | soft | click | glass
    static let animationStyle = SettingsKey("wheel.animation", "bloom")         // bloom | pop | fade | instant
    static let animationSpeed = SettingsKey("wheel.animationSpeed", 1.0)        // 0.5 … 2
    static let imageFormatOrder = SettingsKey("wheel.imageFormatOrder", "")     // comma-separated extensions; "" = default
    static let imageSlots = SettingsKey("wheel.imageSlots", "")                 // six buttons for images, e.g. "png,jpg,cutout,more,compress,resize"; "" = built-in
    static let milestones = SettingsKey("stats.milestones", [String]())          // milestones already celebrated
    static let updatesLastCheck = SettingsKey("updates.lastCheck", 0.0)          // seconds since 1970
    static let wheelUsage = SettingsKey("wheel.usage", [String: Int]())          // smart-ordering counts

    // MARK: Output
    static let destination = SettingsKey("output.destination", "original")      // original | folder
    static let outputFolder = SettingsKey("output.folder", "")
    static let folderImages = SettingsKey("output.folder.images", "")
    static let folderPDFs = SettingsKey("output.folder.pdfs", "")
    static let folderDocuments = SettingsKey("output.folder.documents", "")
    static let namingTemplate = SettingsKey("output.template", "{name}")
    static let collisionStyle = SettingsKey("output.collision", "number")       // number | time
    static let afterOpen = SettingsKey("output.after.open", false)
    static let afterReveal = SettingsKey("output.after.reveal", false)
    static let afterCopy = SettingsKey("output.after.copy", false)
    static let afterShelf = SettingsKey("output.after.shelf", true)            // results float by the pointer to drag onward
    static let metadata = SettingsKey("output.metadata", "keep")                // keep | stripGPS | stripAll
    static let qualityJPG = SettingsKey("output.quality.jpg", 0.85)
    static let qualityHEIC = SettingsKey("output.quality.heic", 0.8)
    static let qualityAVIF = SettingsKey("output.quality.avif", 0.75)
    static let qualityWebP = SettingsKey("output.quality.webp", 0.8)
    static let replaceOriginal = SettingsKey("output.replaceOriginal", false)

    // MARK: Appearance
    static let theme = SettingsKey("appearance.theme", "riso")                  // riso | neon | tangerine | glass | graphite | midnight | mono | custom
    static let accentHex = SettingsKey("appearance.accentHex", "#FF4FA0")
    static let glassStrength = SettingsKey("appearance.glassStrength", 0.55)    // 0 … 1: tint of the Ring's glass
    static let wheelScheme = SettingsKey("appearance.wheelScheme", "auto")      // auto (each layout's board look) | system | light | dark; Halo is always dark
    static let panelScheme = SettingsKey("menubar.colorScheme", "auto")         // auto (Stack+/Mini dark, Tabs light) | system | light | dark
    static let tintImages = SettingsKey("appearance.tint.images", "")           // "" = none
    static let tintDocuments = SettingsKey("appearance.tint.documents", "")
    static let tintTools = SettingsKey("appearance.tint.tools", "")
    static let wheelScale = SettingsKey("wheel.scale", 1.0)                      // 0.7 … 1.4
    static let ringThickness = SettingsKey("appearance.ringThickness", 1.0)      // 0.8 … 1.2
    static let segmentGap = SettingsKey("appearance.segmentGap", 3.0)            // degrees, 1 … 8
    static let orbScale = SettingsKey("appearance.orbScale", 1.0)                // 0.85 … 1.15
    static let labelScale = SettingsKey("appearance.labelScale", 1.0)            // 0.85 … 1.3
    static let fontStyle = SettingsKey("appearance.font", "rounded")            // rounded | default | mono
    static let labelCase = SettingsKey("appearance.labelCase", "title")         // title | upper
    // Looks designed in the website's Wheel Studio (0.3): fills, colours, shape and motion.
    static let fillStyle = SettingsKey("appearance.fillStyle", "flat")          // flat | duo | shades | stickers | rainbow | outline
    static let accent2Hex = SettingsKey("appearance.accent2Hex", "#2F5BFF")      // Duotone's second colour, and a glow colour
    static let restOpacity = SettingsKey("appearance.restOpacity", 1.0)          // 0.15 … 1: the resting buttons' fill
    static let discHex = SettingsKey("appearance.discHex", "")                   // "" = the layout's own
    static let textHex = SettingsKey("appearance.textHex", "")                   // resting labels; "" = the layout's own
    static let hotTextHex = SettingsKey("appearance.hotTextHex", "")             // text on the lit button; "" = readable on the accent
    static let rimHex = SettingsKey("appearance.rimHex", "")                     // disc outline / Orbit's guide; "" = the layout's own
    static let rimWidth = SettingsKey("appearance.rimWidth", 1.0)                // 0 … 6 × the board's line
    static let glow = SettingsKey("appearance.glow", -1.0)                       // -1 = the layout's own (Halo glows), else 0 … 1.5
    static let glowColor = SettingsKey("appearance.glowColor", "accent")         // accent | second | white
    static let corners = SettingsKey("appearance.corners", 0.0)                  // 0 … 1: rounded segment corners
    static let hoverPop = SettingsKey("appearance.hoverPop", 1.0)                // 0 … 2.5 × the board's bulge
    static let discShadow = SettingsKey("appearance.discShadow", 1.0)            // 0 … 1
    static let captions = SettingsKey("appearance.captions", true)               // Halo captions, Ring icons, Orbit icon discs
    static let dimOthers = SettingsKey("appearance.dimOthers", true)             // Ring and Orbit fade the other buttons
    static let labelWeight = SettingsKey("appearance.labelWeight", "bold")       // regular | semibold | bold | heavy
    static let tracking = SettingsKey("appearance.tracking", 0.0)                // -0.05 … 0.3 em
    static let breathe = SettingsKey("appearance.breathe", 0.0)                  // 0 … 1: the wheel slowly swells and settles
    static let ringDots = SettingsKey("appearance.ringDots", 0)                  // 0 … 36 dots orbiting the wheel
    static let ringSpin = SettingsKey("appearance.ringSpin", 0.0)                // rpm, 0 … 20: how fast they orbit
    static let twirl = SettingsKey("appearance.twirl", false)                    // the wheel spins into place as it opens
    static let sparks = SettingsKey("appearance.sparks", false)                  // a small burst when a button lights up

    // MARK: Menu bar
    static let panelLayout = SettingsKey("menubar.layout", "stackPlus")         // stackPlus | tabs | mini
    static let panelWidth = SettingsKey("menubar.width", "m")                   // s | m | l
    static let panelDensity = SettingsKey("menubar.density", "comfortable")     // comfortable | compact
    static let panelSections = SettingsKey("menubar.sections", "command,stats,progress,presets,drop,recent") // order; missing = hidden
    static let iconStyle = SettingsKey("menubar.iconStyle", "monochrome")       // monochrome | colour | minimal
    static let showPercent = SettingsKey("menubar.showPercent", false)
    static let openOnHover = SettingsKey("menubar.openOnHover", false)
    static let openOnDragOver = SettingsKey("menubar.openOnDragOver", true)
    static let presetsJSON = SettingsKey("presets.list", "[]")                   // [Preset] as JSON
    static let watchRulesJSON = SettingsKey("watch.rules", "[]")                 // [WatchRule] as JSON
    static let panelTiles = SettingsKey("menubar.tiles", "")                     // tile ids in order ("" = default)
    static let panelTileColors = SettingsKey("menubar.tileColors", [String: Int]())
    static let recentsCount = SettingsKey("menubar.recentsCount", 5)             // 5 | 10 | 25
    static let presetGrid = SettingsKey("menubar.grid", "3x2")                   // 3x1 | 3x2 | 4x2
    static let pinned = SettingsKey("menubar.pinned", false)
    static let pinnedSize = SettingsKey("menubar.pinnedSize", "m")
    static let pinnedClickThrough = SettingsKey("menubar.pinnedClickThrough", false)
    static let pinnedCorners = SettingsKey("menubar.pinnedCorners", [String: String]()) // display id → corner

    // MARK: Notifications and advanced
    static let notifyEnabled = SettingsKey("notify.enabled", false)
    static let notifySound = SettingsKey("notify.sound", false)
    static let devHUD = SettingsKey("advanced.devHUD", false)

    // MARK: Legacy (kept so old values can be migrated)
    static let haloAccentHex = SettingsKey("wheel.halo.accentHex", "#C6FF3D", reserved: true)

    // MARK: Reserved for v1.1 (no UI, no behaviour)
    static let mediaPackEnabled = SettingsKey("media.packEnabled", false, reserved: true)
    static let mediaBundleMode = SettingsKey("media.bundleMode", "download", reserved: true)
    static let updatesChannel = SettingsKey("updates.channel", "stable", reserved: true)
    static let updatesAutomatic = SettingsKey("updates.automatic", false)          // opt-in: the only network use
    static let cliInstalled = SettingsKey("cli.installed", false, reserved: true)
    static let urlSchemeEnabled = SettingsKey("urlScheme.enabled", false, reserved: true)
    static let shortcutsEnabled = SettingsKey("shortcuts.enabled", false, reserved: true)
    static let officeAutomation = SettingsKey("office.automation", false, reserved: true)
    static let advancedEventTap = SettingsKey("gesture.advancedEventTap", false, reserved: true)
    static let finderSelectionViaAutomation = SettingsKey("gesture.finderSelectionViaAutomation", false, reserved: true)

    static let all: [AnySettingsKey] = [
        paused.erased, showInMenuBar.erased, launchAtLogin.erased, onboardingCompleted.erased, hotkeyPanel.erased, hotkeyClipboard.erased,
        triggerKey.erased, triggerMode.erased, triggerDelayMs.erased, shakeEnabled.erased, shakeSensitivity.erased,
        skipFullScreen.erased, serviceShortcutInstalled.erased, excludedApps.erased,
        wheelLayout.erased, moreHoverDelayMs.erased, smartOrdering.erased, haptics.erased, beforeAfter.erased, soundPack.erased,
        animationStyle.erased, animationSpeed.erased, imageFormatOrder.erased, imageSlots.erased, milestones.erased,
        updatesLastCheck.erased, wheelUsage.erased,
        destination.erased, outputFolder.erased, folderImages.erased, folderPDFs.erased, folderDocuments.erased,
        namingTemplate.erased, collisionStyle.erased, afterOpen.erased, afterReveal.erased, afterCopy.erased, afterShelf.erased, metadata.erased,
        qualityJPG.erased, qualityHEIC.erased, qualityAVIF.erased, qualityWebP.erased, replaceOriginal.erased,
        theme.erased, accentHex.erased, glassStrength.erased, wheelScheme.erased, panelScheme.erased,
        tintImages.erased, tintDocuments.erased, tintTools.erased, wheelScale.erased, ringThickness.erased, segmentGap.erased,
        orbScale.erased, labelScale.erased, fontStyle.erased, labelCase.erased,
        fillStyle.erased, accent2Hex.erased, restOpacity.erased, discHex.erased, textHex.erased, hotTextHex.erased, rimHex.erased,
        rimWidth.erased, glow.erased, glowColor.erased, corners.erased, hoverPop.erased, discShadow.erased, captions.erased,
        dimOthers.erased, labelWeight.erased, tracking.erased, breathe.erased, ringDots.erased, ringSpin.erased, twirl.erased, sparks.erased,
        panelLayout.erased, panelWidth.erased, panelDensity.erased, panelSections.erased, iconStyle.erased, showPercent.erased,
        openOnHover.erased, openOnDragOver.erased, presetsJSON.erased, watchRulesJSON.erased, panelTiles.erased,
        panelTileColors.erased, recentsCount.erased, presetGrid.erased, pinned.erased, pinnedSize.erased,
        pinnedClickThrough.erased, pinnedCorners.erased,
        notifyEnabled.erased, notifySound.erased, devHUD.erased, haloAccentHex.erased,
        mediaPackEnabled.erased, mediaBundleMode.erased, updatesChannel.erased, updatesAutomatic.erased,
        cliInstalled.erased, urlSchemeEnabled.erased, shortcutsEnabled.erased, officeAutomation.erased,
        advancedEventTap.erased, finderSelectionViaAutomation.erased,
    ]

}
