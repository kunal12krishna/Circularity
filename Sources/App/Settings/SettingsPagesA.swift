import AppKit
import CircularityEngine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmReset = false
    @State private var serviceInstalled = ServiceShortcut.isInstalled

    var body: some View {
        let a = model.accent
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "General", subtitle: "Startup, shortcuts and help.", accent: a)
            SettingsCard(title: "Startup") {
                ToggleRow(title: "Launch at login", detail: model.loginError ?? (LoginItem.needsApproval ? "Waiting for your approval in System Settings → Login Items." : nil),
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }), accent: a)
                if LoginItem.needsApproval {
                    HaloButton(title: "Open Login Items", accent: a) { LoginItem.openSystemSettings() }
                }
                ToggleRow(title: "Show in the menu bar",
                          detail: "Hidden: open \(AppIdentity.name) again from Finder or Spotlight to bring the icon back. The wheel keeps working.",
                          isOn: Binding(get: { model.store.value(SettingsKeys.showInMenuBar) }, set: { on in
                              model.store.set(on, for: SettingsKeys.showInMenuBar)
                              model.host?.settingsShowMenuBarIcon(on)
                          }), accent: a)
                ToggleRow(title: "Pause", detail: "The wheel won't appear until you turn this off.",
                          isOn: model.binding(SettingsKeys.paused), accent: a)
            }
            SettingsCard(title: "Shortcuts", footer: "Shortcuts work from any app and need no permission.") {
                SettingRow(title: "Open the panel", detail: "with ⌘K ready for typing") {
                    HotkeyRecorder(model: model, key: SettingsKeys.hotkeyPanel, other: SettingsKeys.hotkeyClipboard)
                }
                if model.hotkeyFailures.contains(1) { taken }
                SettingRow(title: "Convert the clipboard", detail: "image or PDF on the clipboard, result back on it") {
                    HotkeyRecorder(model: model, key: SettingsKeys.hotkeyClipboard, other: SettingsKeys.hotkeyPanel)
                }
                if model.hotkeyFailures.contains(2) { taken }
                ToggleRow(title: "⌃⌥C converts the Finder selection",
                          detail: "Adds a keyboard shortcut to the “Convert with \(AppIdentity.name)” service. Finder picks it up after a relaunch.",
                          isOn: Binding(get: { serviceInstalled }, set: { on in
                              if on {
                                  if ServiceShortcut.install() { ServiceShortcut.offerFinderRelaunch() } else { ServiceShortcut.openKeyboardSettings() }
                              } else {
                                  ServiceShortcut.uninstall()
                                  ServiceShortcut.offerFinderRelaunch(turnedOn: false)
                              }
                              serviceInstalled = ServiceShortcut.isInstalled
                          }), accent: a)
            }
            SettingsCard(title: "Help") {
                HStack(spacing: 8) {
                    HaloButton(title: "Interactive tutorial", primary: true, accent: a) { model.host?.settingsShowTutorial() }
                    HaloButton(title: "Practice wheel", accent: a) { model.host?.settingsPracticeWheel() }
                    HaloButton(title: "Show the welcome again", accent: a) { model.host?.settingsShowOnboarding() }
                }
            }
            SettingsCard(title: "Reset", footer: "Watch folders, history and stats are kept.") {
                SettingRow(title: "Reset all settings", detail: "Back to the defaults, including the wheel, panel and appearance.") {
                    HaloButton(title: "Reset…", accent: a) { confirmReset = true }
                }
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetAll() }
        } message: {
            Text("Everything in Settings goes back to the default. Watch folders, history and stats are kept.")
        }
    }

    private var taken: some View {
        Text("Another app already uses this shortcut. Pick a different one.")
            .font(Halo.rounded(11, .semibold)).foregroundStyle(Color(hex: 0xFF8A80))
    }
}

// MARK: - Gesture

struct GesturePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let a = model.accent
        let key = model.store.value(SettingsKeys.triggerKey).capitalized
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Gesture", subtitle: "How the wheel opens while you drag files. No permissions are used.", accent: a)
            SettingsCard(title: "Trigger") {
                ChipRow(title: "Key", detail: "Tap it while dragging files.", options: [("shift", "Shift"), ("option", "Option"), ("control", "Control")],
                        selection: model.binding(SettingsKeys.triggerKey), accent: a)
                ChipRow(title: "Style", detail: model.store.value(SettingsKeys.triggerMode) == "hold"
                        ? "Hold \(key): the wheel stays while the key is down."
                        : "Tap \(key) once: the wheel stays until you drop or move away.",
                        options: [("tap", "Tap"), ("hold", "Hold")], selection: model.binding(SettingsKeys.triggerMode), accent: a)
                SliderRow(title: "Delay before it opens", detail: "Useful if you also use \(key) for something else while dragging.",
                          value: model.double(SettingsKeys.triggerDelayMs), range: 0...600, step: 50,
                          format: { $0 == 0 ? "None" : "\(Int($0)) ms" }, accent: a)
            }
            SettingsCard(title: "Shake") {
                ToggleRow(title: "Shake to open", detail: "Shake the pointer quickly left and right while dragging.",
                          isOn: model.binding(SettingsKeys.shakeEnabled), accent: a)
                if model.store.value(SettingsKeys.shakeEnabled) {
                    ChipPicker(options: [("low", "Firm shake"), ("medium", "Medium"), ("high", "Light shake")],
                               selection: model.binding(SettingsKeys.shakeSensitivity), accent: a)
                }
            }
            SettingsCard(title: "Where it works") {
                ToggleRow(title: "Not in full-screen apps", detail: "Games and full-screen video stay undisturbed.",
                          isOn: model.binding(SettingsKeys.skipFullScreen), accent: a)
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(title: "Excluded apps", detail: "The wheel never opens while one of these is in front.") {
                        HaloButton(title: "Add…", accent: a) { model.addExcludedApp() }
                    }
                    let apps = model.store.value(SettingsKeys.excludedApps)
                    if apps.isEmpty {
                        Text("None").font(Halo.rounded(12)).foregroundStyle(Halo.secondary)
                    }
                    ForEach(apps, id: \.self) { id in
                        HStack(spacing: 8) {
                            if let icon = SettingsModel.appIcon(for: id) { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                            Text(SettingsModel.appName(for: id)).font(Halo.rounded(13)).foregroundStyle(Halo.text)
                            Spacer()
                            Button { model.removeExcludedApp(id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Halo.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(SettingsModel.appName(for: id))")
                        }
                    }
                }
            }
            SettingsCard(title: "Try it", footer: "Drag the picture a little, tap \(key), then let go on a format. The result is saved next to a temporary copy, so nothing of yours changes.") {
                HStack(spacing: 16) {
                    PracticePicture()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Drag me").font(Halo.mono(16, .heavy)).foregroundStyle(a)
                        Text("Or open the wheel without dragging:").font(Halo.rounded(12)).foregroundStyle(Halo.secondary)
                        HaloButton(title: "Practice wheel", accent: a) { model.host?.settingsPracticeWheel() }
                    }
                }
            }
        }
    }
}

/// A picture you can drag out of Settings to try the gesture.
struct PracticePicture: View {
    static let url: URL? = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-Practice", isDirectory: true)
        let url = dir.appendingPathComponent("Practice photo.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let image = samplePicture(size: 512, scale: 1),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil ? url : nil
    }()

    var body: some View {
        Group {
            if let url = Self.url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2)))
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    .help("Drag this picture to try the wheel")
                    .accessibilityLabel("Practice photo, drag it to try the wheel")
            }
        }
    }
}

// MARK: - Wheel

struct WheelPage: View {
    @ObservedObject var model: SettingsModel
    let preview: WheelPreviewRenderer

    var body: some View {
        let a = model.accent
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Wheel", subtitle: "Layout, order and feel. Changes show in the preview and on the next drag.", accent: a)
            SettingsCard {
                WheelPreview(model: model, renderer: preview, height: 280)
                ChipRow(title: "Layout", options: [("halo", "Halo"), ("ring", "Ring"), ("orbit", "Orbit")],
                        selection: model.binding(SettingsKeys.wheelLayout), accent: a)
            }
            SettingsCard(title: "Image formats", footer: "The first formats sit on the wheel; the rest are under More. Drag to reorder.") {
                FormatOrderList(model: model)
                HStack {
                    ToggleRow(title: "Smart ordering", detail: "Formats you use most move to the front.",
                              isOn: model.binding(SettingsKeys.smartOrdering), accent: a)
                }
            }
            SettingsCard(title: "Feel") {
                SliderRow(title: "More opens after", value: model.double(SettingsKeys.moreHoverDelayMs), range: 0...600, step: 50,
                          format: { $0 == 0 ? "At once" : "\(Int($0)) ms" }, accent: a)
                ToggleRow(title: "Haptic tick", detail: "On a Force Touch trackpad, as you move between buttons.",
                          isOn: model.binding(SettingsKeys.haptics), accent: a)
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(title: "Sounds", detail: "Quiet system sounds. Off by default.") {
                        if model.store.value(SettingsKeys.soundPack) != "off" {
                            HaloButton(title: "Play", accent: a) {
                                let pack = model.store.value(SettingsKeys.soundPack)
                                WheelSounds.play(.open, pack: pack)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { WheelSounds.play(.hover, pack: pack) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { WheelSounds.play(.choose, pack: pack) }
                            }
                        }
                    }
                    ChipPicker(options: WheelSounds.packs.map { ($0.id, $0.name) }, selection: model.binding(SettingsKeys.soundPack), accent: a)
                }
                ChipRow(title: "Opening animation", detail: Motion.reduceMotion ? "Reduce Motion is on in System Settings, so the wheel fades in." : nil,
                        options: [("bloom", "Bloom"), ("pop", "Pop"), ("fade", "Fade"), ("instant", "Instant")],
                        selection: model.binding(SettingsKeys.animationStyle), accent: a)
                SliderRow(title: "Animation speed", value: model.clamped(SettingsKeys.animationSpeed, 0.5...2), range: 0.5...2, step: 0.25,
                          format: { String(format: "%.2g×", $0) }, accent: a)
                HaloButton(title: "Try it on the practice wheel", accent: a) { model.host?.settingsPracticeWheel() }
            }
        }
    }
}

struct FormatOrderList: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let order = SlotProvider.imageFormatOrder(model.store.value(SettingsKeys.imageFormatOrder))
        // The wheel shows the first three formats this Mac can write.
        let onWheel = Set(order.filter { FormatSupport.current.canWrite($0) }.prefix(3))
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(order, id: \.self) { format in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(Halo.secondary)
                        Text(format.displayName).font(Halo.mono(13, .bold)).foregroundStyle(Halo.text)
                        if !FormatSupport.current.canWrite(format) {
                            Text("not available on this Mac").font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
                        }
                        Spacer()
                        if FormatSupport.current.canWrite(format) {
                            Text(onWheel.contains(format) ? "on the wheel" : "under More").font(Halo.rounded(11))
                                .foregroundStyle(onWheel.contains(format) ? model.accent : Halo.secondary)
                        }
                    }
                    .listRowBackground(Halo.control)
                }
                .onMove { from, to in
                    var list = order
                    list.move(fromOffsets: from, toOffset: to)
                    model.store.set(list.map(\.fileExtension).joined(separator: ","), for: SettingsKeys.imageFormatOrder)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(order.count) * 26 + 8)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if !model.store.value(SettingsKeys.imageFormatOrder).isEmpty {
                Button("Restore the default order") { model.store.set("", for: SettingsKeys.imageFormatOrder) }
                    .buttonStyle(.plain).font(Halo.rounded(12, .semibold)).foregroundStyle(model.accent)
            }
        }
    }
}

// MARK: - Output

struct OutputPage: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmReplace = false

    var body: some View {
        let a = model.accent
        let toFolder = model.store.value(SettingsKeys.destination) == "folder"
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Output", subtitle: "Where results go and what they're called. Originals are never changed.", accent: a)
            SettingsCard(title: "Where") {
                ChipPicker(options: [("original", "Next to the original"), ("folder", "In a folder")],
                           selection: Binding(get: { model.store.value(SettingsKeys.destination) }, set: { id in
                               if id == "folder", model.store.value(SettingsKeys.outputFolder).isEmpty {
                                   model.chooseFolder(for: SettingsKeys.outputFolder)
                               } else {
                                   model.store.set(id, for: SettingsKeys.destination)
                               }
                           }), accent: a)
                if toFolder {
                    folderRow("All results", SettingsKeys.outputFolder, allowClear: false)
                    Text("Optional: a different folder per kind of result.").font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
                    folderRow("Images", SettingsKeys.folderImages)
                    folderRow("PDFs", SettingsKeys.folderPDFs)
                    folderRow("Documents and text", SettingsKeys.folderDocuments)
                } else {
                    Text("If the original's folder can't be written, results go to Documents/Converted.")
                        .font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
                }
            }
            SettingsCard(title: "Name") {
                SettingRow(title: "Template", detail: "Example: \(model.namingExample)") {
                    TextField("{name}", text: model.binding(SettingsKeys.namingTemplate))
                        .textFieldStyle(.plain).font(Halo.mono(13)).foregroundStyle(Halo.text)
                        .padding(.horizontal, 8).frame(width: 200, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Halo.control))
                        .accessibilityLabel("Naming template")
                }
                HStack(spacing: 6) {
                    ForEach(NamingTemplate.tokens, id: \.self) { token in
                        Chip(title: token, accent: a) {
                            var t = model.store.value(SettingsKeys.namingTemplate)
                            t += t.isEmpty || t.hasSuffix(" ") ? token : " \(token)"
                            model.store.set(t, for: SettingsKeys.namingTemplate)
                        }
                    }
                    Spacer()
                    if model.store.value(SettingsKeys.namingTemplate) != "{name}" {
                        Button("Default") { model.store.set("{name}", for: SettingsKeys.namingTemplate) }
                            .buttonStyle(.plain).font(Halo.rounded(12, .semibold)).foregroundStyle(a)
                    }
                }
                ChipRow(title: "If the name is taken", options: [("number", "photo (1).jpg"), ("time", "photo 2026-11-18 at 09.41.jpg")],
                        selection: model.binding(SettingsKeys.collisionStyle), accent: a)
            }
            SettingsCard(title: "After converting") {
                ToggleRow(title: "Open the result", detail: "At most five files from a batch.", isOn: model.binding(SettingsKeys.afterOpen), accent: a)
                ToggleRow(title: "Show it in Finder", isOn: model.binding(SettingsKeys.afterReveal), accent: a)
                ToggleRow(title: "Copy it to the clipboard", isOn: model.binding(SettingsKeys.afterCopy), accent: a)
                ToggleRow(title: "Move the original to the Trash",
                          detail: "Only when one file becomes one new file. You can put it back from the Trash.",
                          isOn: Binding(get: { model.store.value(SettingsKeys.replaceOriginal) }, set: { on in
                              if on { confirmReplace = true } else { model.store.set(false, for: SettingsKeys.replaceOriginal) }
                          }), accent: a)
            }
            SettingsCard(title: "Photos") {
                ChipRow(title: "Metadata", detail: "Camera details, date and location stored in photos.",
                        options: [("keep", "Keep all"), ("stripGPS", "Remove location"), ("stripAll", "Remove all")],
                        selection: model.binding(SettingsKeys.metadata), accent: a)
                qualitySlider("JPG quality", SettingsKeys.qualityJPG, .jpg)
                qualitySlider("HEIC quality", SettingsKeys.qualityHEIC, .heic)
                qualitySlider("AVIF quality", SettingsKeys.qualityAVIF, .avif)
                qualitySlider("WebP quality", SettingsKeys.qualityWebP, .webp)
            }
        }
        .confirmationDialog("Move originals to the Trash after converting?", isPresented: $confirmReplace) {
            Button("Turn On", role: .destructive) { model.store.set(true, for: SettingsKeys.replaceOriginal) }
        } message: {
            Text("After a successful conversion the original file goes to the Trash. Combined PDFs never remove their pages' files.")
        }
    }

    @ViewBuilder
    private func qualitySlider(_ title: String, _ key: SettingsKey<Double>, _ format: OutputFormat) -> some View {
        if FormatSupport.current.canWrite(format) {
            SliderRow(title: title, value: model.clamped(key, 0.3...1), range: 0.3...1, step: 0.05,
                      format: { "\(Int(($0 * 100).rounded()))" }, accent: model.accent)
        } else {
            SettingRow(title: title, detail: "\(format.displayName) can't be written on this Mac.") { EmptyView() }
        }
    }

    private func folderRow(_ title: String, _ key: SettingsKey<String>, allowClear: Bool = true) -> some View {
        let path = model.store.value(key)
        return SettingRow(title: title, detail: path.isEmpty ? (allowClear ? "Same as all results" : "Not chosen") : (path as NSString).abbreviatingWithTildeInPath) {
            HStack(spacing: 6) {
                if allowClear && !path.isEmpty {
                    HaloButton(title: "Clear", accent: model.accent) { model.store.set("", for: key) }
                }
                HaloButton(title: "Choose…", accent: model.accent) { model.chooseFolder(for: key) }
            }
        }
    }
}
