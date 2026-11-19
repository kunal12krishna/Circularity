import AppKit
import CircularityEngine
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What the Settings window asks of the rest of the app.
protocol SettingsHost: AnyObject {
    /// Re-registers both global shortcuts; returns ids that could not be registered.
    func settingsApplyHotkeys() -> Set<UInt32>
    /// After an import or reset: applies settings that need an action (icon,
    /// HUD, pinned panel, shortcuts; the login item only for an import).
    /// Returns the shortcut ids that could not be registered.
    func settingsApplyStored(includingLoginItem: Bool) -> Set<UInt32>
    func settingsSuspendHotkeys()
    func settingsShowMenuBarIcon(_ visible: Bool)
    func settingsPracticeWheel()
    func settingsShowOnboarding()
    func settingsShowTutorial()
    func settingsSetDevHUD(_ on: Bool)
    func settingsDiagnostics() -> String
    var settingsWatch: WatchFolderService { get }
    var settingsUpdates: UpdateChecker { get }
    var settingsJobs: JobCenter { get }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, gesture, wheel, output, presets, watch, menuBar, appearance, notifications, advanced, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .gesture: "Gesture"
        case .wheel: "Wheel"
        case .output: "Output"
        case .presets: "Presets"
        case .watch: "Watch Folders"
        case .menuBar: "Menu Bar"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .gesture: "hand.draw"
        case .wheel: "circle.dashed"
        case .output: "tray.and.arrow.down"
        case .presets: "bolt"
        case .watch: "eye"
        case .menuBar: "menubar.rectangle"
        case .appearance: "paintpalette"
        case .notifications: "bell"
        case .advanced: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }
}

/// The Settings window's state. Every control writes straight to
/// `SettingsStore`, which publishes the change; the wheel, panel and icon
/// read settings when they draw, so changes apply instantly.
final class SettingsModel: ObservableObject {
    let store: SettingsStore
    weak var host: SettingsHost?
    @Published var page: SettingsPage = .general
    @Published var message: String?
    @Published var hotkeyFailures: Set<UInt32> = []
    @Published var loginError: String?
    @Published var notificationStatus = "not asked"
    @Published var previewHover: WheelTarget = .segment(1)
    private var bag: Set<AnyCancellable> = []

    init(store: SettingsStore) {
        self.store = store
        store.changes.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    func binding<V>(_ key: SettingsKey<V>) -> Binding<V> {
        Binding(get: { [store] in store.value(key) }, set: { [store] in store.set($0, for: key) })
    }

    /// A Double setting clamped to a range (sliders).
    func clamped(_ key: SettingsKey<Double>, _ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { [store] in min(range.upperBound, max(range.lowerBound, store.value(key))) },
                set: { [store] in store.set(min(range.upperBound, max(range.lowerBound, $0)), for: key) })
    }

    /// An Int setting as a Double (sliders).
    func double(_ key: SettingsKey<Int>) -> Binding<Double> {
        Binding(get: { [store] in Double(store.value(key)) }, set: { [store] in store.set(Int($0.rounded()), for: key) })
    }

    var accent: Color { Color(nsColor: Appearance.accentNS(store)) }
    var onAccent: Color { Color(cgColor: Appearance.onAccent(store)) }

    func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }

    // MARK: General

    var launchAtLogin: Bool {
        get { LoginItem.isEnabled || LoginItem.needsApproval }
        set {
            loginError = LoginItem.set(newValue)
            store.set(newValue, for: SettingsKeys.launchAtLogin)
            objectWillChange.send()
        }
    }

    func applyHotkeys() { hotkeyFailures = host?.settingsApplyHotkeys() ?? [] }

    func resetAll() {
        store.resetAll()
        hotkeyFailures = host?.settingsApplyStored(includingLoginItem: false) ?? []
        flash("Settings reset to the defaults.")
    }

    // MARK: Gesture: excluded apps

    func addExcludedApp() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.application]
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.prompt = "Exclude"
        open.message = "The wheel won't open while dragging from these apps."
        guard open.runModal() == .OK else { return }
        var list = store.value(SettingsKeys.excludedApps)
        for url in open.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !list.contains(id) else { continue }
            list.append(id)
        }
        store.set(list, for: SettingsKeys.excludedApps)
    }

    func removeExcludedApp(_ id: String) {
        store.set(store.value(SettingsKeys.excludedApps).filter { $0 != id }, for: SettingsKeys.excludedApps)
    }

    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func appIcon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    // MARK: Output

    func chooseFolder(for key: SettingsKey<String>) {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = "Choose"
        guard open.runModal() == .OK, let url = open.url else { return }
        store.set(url.path, for: key)
        if key.name == SettingsKeys.outputFolder.name { store.set("folder", for: SettingsKeys.destination) }
    }

    /// "IMG_2041.jpg" for the current template (Settings → Output preview).
    var namingExample: String {
        let pattern = store.value(SettingsKeys.namingTemplate)
        let context = NamingContext(sourceURL: URL(fileURLWithPath: "/tmp/IMG_2041.HEIC"), format: .jpg, operation: .convert,
                                    pixelSize: PixelSize(width: 4032, height: 3024))
        let base = OutputNaming.baseName(template: pattern.trimmingCharacters(in: .whitespaces).isEmpty ? .default : NamingTemplate(pattern),
                                         context: context)
        return base + ".jpg"
    }

    // MARK: Appearance

    func applyTheme(_ id: String) {
        Appearance.apply(theme: id, to: store)
    }

    func setAccent(_ hex: String) {
        store.set(hex, for: SettingsKeys.accentHex)
        store.set(ThemeCatalog.theme(forAccent: hex)?.id ?? "custom", for: SettingsKeys.theme)
    }

    static let appearanceKeys: [AnySettingsKey] = [
        SettingsKeys.theme.erased, SettingsKeys.accentHex.erased, SettingsKeys.glassStrength.erased, SettingsKeys.wheelScheme.erased,
        SettingsKeys.panelScheme.erased, SettingsKeys.tintImages.erased, SettingsKeys.tintDocuments.erased, SettingsKeys.tintTools.erased,
        SettingsKeys.wheelScale.erased, SettingsKeys.ringThickness.erased, SettingsKeys.segmentGap.erased, SettingsKeys.orbScale.erased,
        SettingsKeys.labelScale.erased, SettingsKeys.fontStyle.erased, SettingsKeys.labelCase.erased,
        SettingsKeys.fillStyle.erased, SettingsKeys.accent2Hex.erased, SettingsKeys.restOpacity.erased, SettingsKeys.discHex.erased,
        SettingsKeys.textHex.erased, SettingsKeys.hotTextHex.erased, SettingsKeys.rimHex.erased, SettingsKeys.rimWidth.erased,
        SettingsKeys.glow.erased, SettingsKeys.glowColor.erased, SettingsKeys.corners.erased, SettingsKeys.hoverPop.erased,
        SettingsKeys.discShadow.erased, SettingsKeys.captions.erased, SettingsKeys.dimOthers.erased, SettingsKeys.labelWeight.erased,
        SettingsKeys.tracking.erased, SettingsKeys.breathe.erased, SettingsKeys.ringDots.erased, SettingsKeys.ringSpin.erased,
        SettingsKeys.twirl.erased, SettingsKeys.sparks.erased,
    ]

    /// What a theme carries (the website's theme builder writes these): the
    /// appearance settings plus the wheel layout.
    static let themeKeys: Set<String> = Set(appearanceKeys.map(\.name) + [SettingsKeys.wheelLayout.name])

    func resetAppearance() {
        for key in Self.appearanceKeys { store.remove(key.name) }
        flash("Appearance reset.")
    }

    // MARK: Export / import

    func exportSettings(appearanceOnly: Bool) {
        let save = NSSavePanel()
        save.allowedContentTypes = [.json]
        save.nameFieldStringValue = appearanceOnly ? "\(AppIdentity.name) Theme.json" : "\(AppIdentity.name) Settings.json"
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            let data = try store.exportJSON(only: appearanceOnly ? Set(Self.appearanceKeys.map(\.name)) : nil)
            try data.write(to: url, options: .atomic)
            flash("Saved \(url.lastPathComponent).")
        } catch {
            flash("Couldn't save: \(error.localizedDescription)")
        }
    }

    /// A theme copied from the website (or another Mac): JSON on the clipboard.
    func pasteTheme() {
        // The JSON from the Wheel Studio's "Copy for the app", or one of its share links.
        guard let text = NSPasteboard.general.string(forType: .string), let data = StudioThemes.themeJSON(from: text) else {
            flash("The clipboard has no theme. In the Wheel Studio, click Copy for the app (or copy a share link) first.")
            return
        }
        do {
            let result = try store.importJSON(data, only: Self.themeKeys)
            flash(StudioThemes.message(applied: result.applied, skipped: result.skipped, store: store))
        } catch {
            flash("The clipboard doesn't hold a \(AppIdentity.name) theme. In the Wheel Studio, click Copy for the app first.")
        }
    }

    /// Copies the current look as JSON, to paste on another Mac or share.
    func copyTheme() {
        guard let data = try? store.exportJSON(only: Self.themeKeys),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Theme copied. Paste it on another Mac with Paste theme.")
    }

    func importSettings() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            let result = try store.importJSON(Data(contentsOf: url))
            hotkeyFailures = host?.settingsApplyStored(includingLoginItem: true) ?? []
            loginError = nil
            flash("Imported \(result.applied) setting\(result.applied == 1 ? "" : "s")"
                  + (result.skipped.isEmpty ? "." : " (skipped \(result.skipped.count) unknown or invalid)."))
        } catch {
            flash("That file isn't a \(AppIdentity.name) settings file.")
        }
    }

    // MARK: Notifications

    func refreshNotificationStatus() {
        Notifier.shared.status { [weak self] status in self?.notificationStatus = status }
    }

    func setNotifications(_ on: Bool) {
        guard on else {
            store.set(false, for: SettingsKeys.notifyEnabled)
            return
        }
        Notifier.shared.requestPermission { [weak self] granted in
            guard let self else { return }
            store.set(granted, for: SettingsKeys.notifyEnabled)
            refreshNotificationStatus()
            if !granted { flash("macOS didn't allow notifications. Turn them on in System Settings → Notifications.") }
        }
    }
}
