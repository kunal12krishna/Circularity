import AppKit
import CircularityEngine
import SwiftUI

// MARK: - Watch folders

struct WatchPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let watch = model.host?.settingsWatch {
            WatchFoldersView(watch: watch, accent: model.accent).frame(minHeight: 460)
        }
    }
}

// MARK: - Notifications

struct NotificationsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let a = model.accent
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Notifications", subtitle: "Off unless you turn them on. macOS asks once.", accent: a)
            SettingsCard(footer: model.notificationStatus == "denied"
                         ? "macOS has notifications for \(AppIdentity.name) turned off. Turn them on in System Settings → Notifications."
                         : nil) {
                ToggleRow(title: "Tell me when a conversion finishes", detail: "With Open and Show in Finder buttons. Failures are reported too.",
                          isOn: Binding(get: { model.store.value(SettingsKeys.notifyEnabled) }, set: { model.setNotifications($0) }), accent: a)
                ToggleRow(title: "Play a sound", isOn: model.binding(SettingsKeys.notifySound), accent: a)
                    .disabled(!model.store.value(SettingsKeys.notifyEnabled))
                HStack {
                    Text("macOS permission: \(model.notificationStatus)").font(Halo.rounded(12)).foregroundStyle(Halo.secondary)
                    Spacer()
                    if model.notificationStatus == "denied" {
                        HaloButton(title: "Open System Settings", accent: a) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                    HaloButton(title: "Send a test", accent: a) {
                        Notifier.shared.post(title: "\(AppIdentity.name) test", body: "Notifications work.", outputs: [],
                                             sound: model.store.value(SettingsKeys.notifySound))
                    }
                    .disabled(!model.store.value(SettingsKeys.notifyEnabled))
                }
            }
        }
        .onAppear { model.refreshNotificationStatus() }
    }
}

// MARK: - Advanced

struct AdvancedPage: View {
    @ObservedObject var model: SettingsModel
    @State private var memory = MemoryFootprint.megabytes

    var body: some View {
        let a = model.accent
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Advanced", subtitle: "Diagnostics, settings files and developer tools.", accent: a)
            SettingsCard(title: "Diagnostics", footer: "Reports never leave your Mac unless you send them. They hold no file contents, only names of formats, settings and recent log lines.") {
                SettingRow(title: "Copy diagnostics", detail: "Version, macOS, formats and settings, ready to paste.") {
                    HaloButton(title: "Copy", accent: a) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.host?.settingsDiagnostics() ?? "", forType: .string)
                        model.flash("Diagnostics copied.")
                    }
                }
                SettingRow(title: "Report a bug", detail: "Saves diagnostics and the last hour of \(AppIdentity.name)'s log to a file you can attach.") {
                    HaloButton(title: "Save report…", accent: a) { saveReport() }
                }
                SettingRow(title: "Logs", detail: "Open Console and filter by \(AppIdentity.bundleID).") {
                    HaloButton(title: "Open Console", accent: a) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("subsystem:\(AppIdentity.bundleID)", forType: .string)
                        model.flash("Console opened. The search filter is on the clipboard.")
                    }
                }
            }
            SettingsCard(title: "Performance") {
                SettingRow(title: "Memory in use", detail: "Idle with no window open, \(AppIdentity.name) uses about 12–20 MB.") {
                    HStack(spacing: 8) {
                        Text(memory).font(Halo.mono(13, .bold)).foregroundStyle(a)
                        HaloButton(title: "Refresh", accent: a) {
                            MemoryFootprint.relieve()
                            memory = MemoryFootprint.megabytes
                        }
                    }
                }
                ToggleRow(title: "Developer HUD", detail: "A small readout in the corner: memory, jobs and the last drag.",
                          isOn: Binding(get: { model.store.value(SettingsKeys.devHUD) }, set: { on in
                              model.store.set(on, for: SettingsKeys.devHUD)
                              model.host?.settingsSetDevHUD(on)
                          }), accent: a)
            }
            SettingsCard(title: "Settings file") {
                HStack(spacing: 8) {
                    HaloButton(title: "Export all settings…", accent: a) { model.exportSettings(appearanceOnly: false) }
                    HaloButton(title: "Import…", accent: a) { model.importSettings() }
                }
            }
        }
    }

    private func saveReport() {
        let save = NSSavePanel()
        save.allowedContentTypes = [.plainText]
        save.nameFieldStringValue = "\(AppIdentity.name) report.txt"
        guard save.runModal() == .OK, let url = save.url else { return }
        let diagnostics = model.host?.settingsDiagnostics() ?? ""
        model.flash("Collecting the log…")
        let bundleID = AppIdentity.bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            let log = Self.recentLog(subsystem: bundleID)
            let text = diagnostics + "\n\n--- Log (last hour) ---\n" + log
            let ok = (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
            DispatchQueue.main.async {
                if ok { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                model.flash(ok ? "Report saved." : "Couldn't save the report.")
            }
        }
    }

    nonisolated static func recentLog(subsystem: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "1h", "--style", "compact", "--predicate", "subsystem == \"\(subsystem)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "(couldn't read the log: \(error.localizedDescription))" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        // Keep the report small: the last 2,000 lines.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(2000).joined(separator: "\n")
    }
}

// MARK: - About

struct AboutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let a = model.accent
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppIdentity.name.uppercased()).font(Halo.mono(24, .heavy)).tracking(1.2).foregroundStyle(a)
                    Text("Version \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                        .font(Halo.rounded(12)).foregroundStyle(Halo.secondary)
                    Text("Drag files, tap Shift, convert.").font(Halo.rounded(12, .semibold)).foregroundStyle(Halo.text)
                }
            }
            SettingsCard(title: "What this Mac can do", footer: "Everything runs on your Mac with Apple's own frameworks. Nothing is uploaded.") {
                toolLine("Images", "ImageIO — writes \(writable)")
                toolLine("PDFs", "PDFKit and Quartz")
                toolLine("Documents", FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil")
                         ? "WebKit for PDF, textutil for Word, RTF and HTML" : "WebKit for PDF (textutil missing: Word and RTF are off)")
                toolLine("Video and audio", "coming in the next update")
            }
            SettingsCard(title: "Thanks") {
                Text("Inspired by Circularity for Windows by Atharv Gogia (MIT licence). The Tangerine look is after the Tangerine design by LEAP STUDIO.")
                    .font(Halo.rounded(12)).foregroundStyle(Halo.text).fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard(title: "Licences") {
                Text("\(AppIdentity.name) is released under the MIT licence. It bundles no third-party code; it uses only frameworks that come with macOS. See LICENSE and THIRD-PARTY-NOTICES in the download.")
                    .font(Halo.rounded(12)).foregroundStyle(Halo.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var writable: String {
        SlotProvider.ringImageCandidates.filter { FormatSupport.current.canWrite($0) }.map(\.displayName).joined(separator: ", ")
    }

    private func toolLine(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title.uppercased()).font(Halo.mono(11, .bold)).foregroundStyle(Halo.secondary).frame(width: 120, alignment: .leading)
            Text(detail).font(Halo.rounded(12)).foregroundStyle(Halo.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Window

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var preview = WheelPreviewRenderer()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Halo.hairline).frame(width: 1)
            ScrollView {
                SettingsPageView(model: model, preview: preview)
                    .padding(24)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(model.page)
        }
        .background(Halo.background)
        .overlay(alignment: .bottom) {
            if let message = model.message {
                Text(message).font(Halo.rounded(12, .semibold)).foregroundStyle(Halo.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Halo.card)).overlay(Capsule().stroke(model.accent.opacity(0.6)))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.message)
        .frame(minWidth: 760, minHeight: 520)
        .tint(model.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS").font(Halo.mono(11, .bold)).tracking(1).foregroundStyle(Halo.secondary)
                .padding(.horizontal, 12).padding(.top, 36).padding(.bottom, 8)
            ForEach(SettingsPage.allCases) { page in
                let selected = model.page == page
                Button { model.page = page } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.symbol).frame(width: 18)
                        Text(page.title).font(Halo.rounded(13, selected ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(selected ? model.accent : Halo.text)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Halo.control : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 200)
        .background(Color(hex: 0x111318))
    }

}

/// The current page's content (also rendered by --render-previews).
struct SettingsPageView: View {
    @ObservedObject var model: SettingsModel
    let preview: WheelPreviewRenderer

    var body: some View {
        switch model.page {
        case .general: GeneralPage(model: model)
        case .gesture: GesturePage(model: model)
        case .wheel: WheelPage(model: model, preview: preview)
        case .output: OutputPage(model: model)
        case .presets: PresetsPage(model: model)
        case .watch: WatchPage(model: model)
        case .menuBar: MenuBarPage(model: model)
        case .appearance: AppearancePage(model: model, preview: preview)
        case .notifications: NotificationsPage(model: model)
        case .advanced: AdvancedPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}
