import AppKit
import CircularityEngine
import SwiftUI

// MARK: - Presets

struct PresetsPage: View {
    @ObservedObject var model: SettingsModel
    @State private var kind = "width"
    @State private var value = "1920"
    @State private var applies = "images"
    @State private var level = "balanced"

    var body: some View {
        let a = model.accent
        let presets = Preset.decodeList(model.store.value(SettingsKeys.presetsJSON))
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Presets", subtitle: "One-click buttons in the wheel's More fan (up to three per file type) and in the panel.", accent: a)
            SettingsCard(title: "Saved buttons") {
                if presets.isEmpty {
                    Text("None yet. Make one below, or tick “Also add this as a button” in Resize or Compress.")
                        .font(Halo.rounded(12)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                    HStack(spacing: 10) {
                        Text(preset.name).font(Halo.mono(13, .bold)).foregroundStyle(Halo.text).frame(minWidth: 90, alignment: .leading)
                        Text(preset.applies == .pdfs ? "PDFs" : "Images").font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
                        if index >= 3 {
                            Text("not on the wheel (only the first three)").font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
                        }
                        Spacer()
                        Button { move(presets, index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.plain).foregroundStyle(index == 0 ? Halo.secondary.opacity(0.4) : Halo.text).disabled(index == 0)
                            .accessibilityLabel("Move \(preset.name) up")
                        Button { move(presets, index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.plain).foregroundStyle(index == presets.count - 1 ? Halo.secondary.opacity(0.4) : Halo.text)
                            .disabled(index == presets.count - 1).accessibilityLabel("Move \(preset.name) down")
                        Button { model.settingsJobsRemove(preset.id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Halo.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Delete \(preset.name)")
                    }
                }
            }
            SettingsCard(title: "New button") {
                ChipRow(title: "For", options: [("images", "Images"), ("pdfs", "PDFs")], selection: $applies, accent: a)
                if applies == "images" {
                    ChipRow(title: "Does", options: [("width", "Resize to width"), ("quality", "Compress to quality"), ("target", "Compress under size")],
                            selection: $kind, accent: a)
                    NumberField(label: kind == "width" ? "Width" : (kind == "quality" ? "Quality" : "Size"), text: $value,
                                unit: kind == "width" ? "px" : (kind == "quality" ? "%" : "KB"))
                        .frame(width: 200)
                } else {
                    ChipRow(title: "Does", options: [("light", "Compress light"), ("balanced", "Balanced"), ("strong", "Strong"),
                                                     ("a4", "Fit A4"), ("letter", "Fit Letter")], selection: $level, accent: a)
                }
                HStack {
                    if let preset = draft { Text("Button: \(preset.name)").font(Halo.mono(12, .bold)).foregroundStyle(a) }
                    else { Text("Enter a number").font(Halo.rounded(12)).foregroundStyle(Halo.secondary) }
                    Spacer()
                    HaloButton(title: "Add button", primary: true, accent: a) {
                        if let draft { model.host?.settingsJobs.addPreset(draft); model.objectWillChange.send() }
                    }
                    .disabled(draft == nil)
                }
            }
        }
        .onChange(of: kind) { k in value = k == "width" ? "1920" : (k == "quality" ? "70" : "500") }
    }

    private var draft: Preset? {
        if applies == "pdfs" {
            switch level {
            case "a4": return Preset(applies: .pdfs, action: .resizePDFPaper(.a4))
            case "letter": return Preset(applies: .pdfs, action: .resizePDFPaper(.letter))
            default: return PDFCompression(rawValue: level).map { Preset(applies: .pdfs, action: .compressPDF($0)) }
            }
        }
        guard let n = Int(value.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        switch kind {
        case "width": return n <= 20000 ? Preset(applies: .images, action: .resize(width: n, height: nil, stretch: false)) : nil
        case "quality": return n <= 100 ? Preset(applies: .images, action: .compressQuality(Double(n) / 100)) : nil
        default: return n <= 2_000_000 ? Preset(applies: .images, action: .compressTarget(Int64(n) * 1000)) : nil
        }
    }

    private func move(_ presets: [Preset], _ index: Int, by delta: Int) {
        var list = presets
        let target = index + delta
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        model.store.set(Preset.encodeList(list), for: SettingsKeys.presetsJSON)
    }
}

extension SettingsModel {
    func settingsJobsRemove(_ id: String) {
        host?.settingsJobs.removePreset(id: id)
        objectWillChange.send()
    }
}

// MARK: - Menu bar

struct MenuBarPage: View {
    @ObservedObject var model: SettingsModel

    static let sectionNames: [(id: String, name: String)] = [
        ("command", "⌘K command bar"), ("stats", "Today · saved · watching"), ("progress", "In progress"),
        ("presets", "Preset tiles"), ("drop", "Drop zone"), ("recent", "Recent"),
    ]

    var body: some View {
        let a = model.accent
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Menu bar", subtitle: "The icon and the panel it opens.", accent: a)
            SettingsCard(title: "Panel") {
                ChipRow(title: "Layout", options: [("stackPlus", "Stack+"), ("tabs", "Tabs"), ("mini", "Mini")],
                        selection: model.binding(SettingsKeys.panelLayout), accent: a)
                ChipRow(title: "Width", options: [("s", "Small"), ("m", "Medium"), ("l", "Large")],
                        selection: model.binding(SettingsKeys.panelWidth), accent: a)
                ChipRow(title: "Density", options: [("comfortable", "Comfortable"), ("compact", "Compact")],
                        selection: model.binding(SettingsKeys.panelDensity), accent: a)
                ChipRow(title: "Colours", options: [("auto", "Automatic"), ("dark", "Dark"), ("light", "Light"), ("system", "Match macOS")],
                        selection: model.binding(SettingsKeys.panelScheme), accent: a)
            }
            SettingsCard(title: "Sections (Stack+)", footer: "Header and footer always show. In progress appears only while something converts.") {
                SectionsEditor(model: model)
            }
            SettingsCard(title: "Content") {
                ChipRow(title: "Recent items", options: [("5", "5"), ("10", "10"), ("25", "25")],
                        selection: Binding(get: { "\(model.store.value(SettingsKeys.recentsCount))" },
                                           set: { model.store.set(Int($0) ?? 5, for: SettingsKeys.recentsCount) }), accent: a)
                ChipRow(title: "Preset grid", options: [("3x1", "3 × 1"), ("3x2", "3 × 2"), ("4x2", "4 × 2")],
                        selection: model.binding(SettingsKeys.presetGrid), accent: a)
            }
            SettingsCard(title: "Icon") {
                ChipRow(title: "Style", options: [("monochrome", "Monochrome"), ("colour", "Colour"), ("minimal", "Minimal")],
                        selection: model.binding(SettingsKeys.iconStyle), accent: a)
                ToggleRow(title: "Show the percentage while converting", isOn: model.binding(SettingsKeys.showPercent), accent: a)
                ToggleRow(title: "Open the panel when the pointer rests on the icon", isOn: model.binding(SettingsKeys.openOnHover), accent: a)
                ToggleRow(title: "Open the panel when files are dragged over the icon", isOn: model.binding(SettingsKeys.openOnDragOver), accent: a)
            }
            SettingsCard(title: "Pinned panel") {
                ChipRow(title: "Size", options: [("s", "Small"), ("m", "Medium"), ("l", "Large")],
                        selection: model.binding(SettingsKeys.pinnedSize), accent: a)
                ToggleRow(title: "Clicks pass through it", detail: "Drops still land on it.", isOn: model.binding(SettingsKeys.pinnedClickThrough), accent: a)
            }
        }
    }
}

struct SectionsEditor: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let shown = PanelSections.parse(model.store.value(SettingsKeys.panelSections))
        let hidden = MenuBarPage.sectionNames.map(\.id).filter { !shown.contains($0) }
        VStack(spacing: 6) {
            ForEach(Array((shown + hidden).enumerated()), id: \.element) { index, id in
                let on = shown.contains(id)
                HStack(spacing: 10) {
                    Toggle(name(id), isOn: Binding(get: { on }, set: { value in
                        save(value ? shown + [id] : shown.filter { $0 != id })
                    })).labelsHidden().toggleStyle(.switch).tint(model.accent).controlSize(.small)
                    Text(name(id)).font(Halo.rounded(13)).foregroundStyle(on ? Halo.text : Halo.secondary)
                    Spacer()
                    if on {
                        Button { reorder(shown, index, -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.plain).disabled(index == 0).foregroundStyle(index == 0 ? Halo.secondary.opacity(0.4) : Halo.text)
                            .accessibilityLabel("Move \(name(id)) up")
                        Button { reorder(shown, index, 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.plain).disabled(index == shown.count - 1)
                            .foregroundStyle(index == shown.count - 1 ? Halo.secondary.opacity(0.4) : Halo.text)
                            .accessibilityLabel("Move \(name(id)) down")
                    }
                }
            }
        }
    }

    private func name(_ id: String) -> String { MenuBarPage.sectionNames.first { $0.id == id }?.name ?? id }
    private func save(_ list: [String]) { model.store.set(list.isEmpty ? "-" : list.joined(separator: ","), for: SettingsKeys.panelSections) }
    private func reorder(_ list: [String], _ index: Int, _ delta: Int) {
        var l = list
        guard l.indices.contains(index + delta) else { return }
        l.swapAt(index, index + delta)
        save(l)
    }
}

// MARK: - Appearance

struct AppearancePage: View {
    @ObservedObject var model: SettingsModel
    let preview: WheelPreviewRenderer

    var body: some View {
        let a = model.accent
        let s = model.store
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "Appearance", subtitle: "Themes, colours and sizes for the wheel, panel and dialogs.", accent: a)
            SettingsCard {
                WheelPreview(model: model, renderer: preview, height: 260)
            }
            SettingsCard(title: "Theme") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(ThemeCatalog.all) { theme in
                        ThemeCard(name: theme.name, color: Color(rgb: theme.accent), selected: s.value(SettingsKeys.theme) == theme.id) {
                            model.applyTheme(theme.id)
                        }
                    }
                    ThemeCard(name: "Custom", color: a, selected: s.value(SettingsKeys.theme) == "custom") {
                        s.set("custom", for: SettingsKeys.theme)
                    }
                }
                SettingRow(title: "Accent") {
                    HStack(spacing: 6) {
                        ForEach(ThemeCatalog.swatches, id: \.self) { hex in
                            let selected = RGB(hexString: hex)?.hexString == RGB(hexString: s.value(SettingsKeys.accentHex))?.hexString
                            Button { model.setAccent(hex) } label: {
                                Circle().fill(RGB(hexString: hex).map { Color(rgb: $0) } ?? .gray).frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.white, lineWidth: selected ? 2 : 0))
                            }
                            .buttonStyle(.plain).accessibilityLabel("Accent \(hex)")
                        }
                        ColorPicker("Custom accent", selection: Binding(get: { a }, set: { model.setAccent(RGB(nsColor: NSColor($0)).hexString) }),
                                    supportsOpacity: false).labelsHidden()
                    }
                }
                SliderRow(title: "Glass", detail: "How tinted Ring's frosted disc is.", value: model.clamped(SettingsKeys.glassStrength, 0...1),
                          range: 0...1, step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" }, accent: a)
            }
            SettingsCard(title: "Colours") {
                ChipRow(title: "Wheel", detail: "Halo is always dark. Automatic: Ring dark, Orbit light, as designed.",
                        options: [("auto", "Automatic"), ("dark", "Dark"), ("light", "Light"), ("system", "Match macOS")],
                        selection: model.binding(SettingsKeys.wheelScheme), accent: a)
                ChipRow(title: "Panel", options: [("auto", "Automatic"), ("dark", "Dark"), ("light", "Light"), ("system", "Match macOS")],
                        selection: model.binding(SettingsKeys.panelScheme), accent: a)
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(title: "Tint by kind", detail: "A soft colour on resting buttons, so kinds are easy to tell apart.") { EmptyView() }
                    tintRow("Image formats", SettingsKeys.tintImages)
                    tintRow("PDF and document formats", SettingsKeys.tintDocuments)
                    tintRow("Tools (compress, resize, crop)", SettingsKeys.tintTools)
                }
            }
            SettingsCard(title: "Size") {
                SliderRow(title: "Wheel size", value: model.clamped(SettingsKeys.wheelScale, 0.7...1.4), range: 0.7...1.4, step: 0.05,
                          format: { "\(Int(($0 * 100).rounded())) %" }, accent: a)
                SliderRow(title: "Ring thickness", value: model.clamped(SettingsKeys.ringThickness, 0.8...1.2), range: 0.8...1.2, step: 0.05,
                          format: { "\(Int(($0 * 100).rounded())) %" }, accent: a)
                SliderRow(title: "Gap between buttons", value: model.clamped(SettingsKeys.segmentGap, 1...8), range: 1...8, step: 1,
                          format: { "\(Int($0))°" }, accent: a)
                SliderRow(title: "Centre size", value: model.clamped(SettingsKeys.orbScale, 0.85...1.15), range: 0.85...1.15, step: 0.05,
                          format: { "\(Int(($0 * 100).rounded())) %" }, accent: a)
                SliderRow(title: "Label size", value: model.clamped(SettingsKeys.labelScale, 0.85...1.3), range: 0.85...1.3, step: 0.05,
                          format: { "\(Int(($0 * 100).rounded())) %" }, accent: a)
            }
            SettingsCard(title: "Type", footer: "Halo keeps its monospace labels.") {
                ChipRow(title: "Font", options: [("rounded", "Rounded"), ("default", "System"), ("mono", "Mono")],
                        selection: model.binding(SettingsKeys.fontStyle), accent: a)
                ChipRow(title: "Labels", options: [("title", "Title case"), ("upper", "UPPER CASE")],
                        selection: model.binding(SettingsKeys.labelCase), accent: a)
            }
            SettingsCard(title: "Fill and colour", footer: "These come from the Wheel Studio on the website: paste a Studio theme to set them all at once.") {
                ChipRow(title: "Fill", options: [("flat", "Board"), ("duo", "Duotone"), ("shades", "Shades"), ("stickers", "Stickers"),
                                                 ("rainbow", "Rainbow"), ("outline", "Outline")],
                        selection: model.binding(SettingsKeys.fillStyle), accent: a)
                colourRow("Second colour (Duotone, glow)", SettingsKeys.accent2Hex, allowsNone: false)
                SliderRow(title: "Resting buttons", detail: "How solid the buttons you're not on are.",
                          value: model.clamped(SettingsKeys.restOpacity, 0.15...1), range: 0.15...1, step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" }, accent: a)
                colourRow("Disc", SettingsKeys.discHex)
                colourRow("Labels", SettingsKeys.textHex)
                colourRow("Text on the lit button", SettingsKeys.hotTextHex)
                colourRow("Rim", SettingsKeys.rimHex)
                SliderRow(title: "Rim width", value: model.clamped(SettingsKeys.rimWidth, 0...6), range: 0...6, step: 0.5,
                          format: { $0 == 0 ? "none" : String(format: "%.1f×", $0) }, accent: a)
            }
            SettingsCard(title: "Shape") {
                SliderRow(title: "Corner rounding", detail: "Ring and Halo.", value: model.clamped(SettingsKeys.corners, 0...1), range: 0...1, step: 0.05,
                          format: { "\(Int(($0 * 100).rounded())) %" }, accent: a)
                SliderRow(title: "Hover pop", detail: "How far the button under the pointer grows.",
                          value: model.clamped(SettingsKeys.hoverPop, 0...2.5), range: 0...2.5, step: 0.1,
                          format: { String(format: "%.1f×", $0) }, accent: a)
                SliderRow(title: "Shadow", value: model.clamped(SettingsKeys.discShadow, 0...1), range: 0...1, step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" }, accent: a)
                ToggleRow(title: "Captions and icons", detail: "Halo's small captions, Ring's icons, Orbit's icon discs.",
                          isOn: model.binding(SettingsKeys.captions), accent: a)
                ToggleRow(title: "Dim the other buttons", detail: "Ring and Orbit, while one is lit.", isOn: model.binding(SettingsKeys.dimOthers), accent: a)
                ChipRow(title: "Label weight", options: [("regular", "Regular"), ("semibold", "Semibold"), ("bold", "Bold"), ("heavy", "Heavy")],
                        selection: model.binding(SettingsKeys.labelWeight), accent: a)
                SliderRow(title: "Letter spacing", value: model.clamped(SettingsKeys.tracking, -0.05...0.3), range: -0.05...0.3, step: 0.01,
                          format: { String(format: "%.2f em", $0) }, accent: a)
            }
            SettingsCard(title: "Glow and motion",
                         footer: "Motion plays on the real wheel (drag a file and tap Shift), not in the picture above, and stays off with Reduce Motion. The six buttons never move, so you can always aim.") {
                ToggleRow(title: "Glow like the layout", detail: "Halo glows under the lit button; Ring and Orbit don't.",
                          isOn: Binding(get: { model.store.value(SettingsKeys.glow) < 0 },
                                        set: { model.store.set($0 ? -1 : 0.6, for: SettingsKeys.glow) }), accent: a)
                if model.store.value(SettingsKeys.glow) >= 0 {
                    SliderRow(title: "Glow", value: model.clamped(SettingsKeys.glow, 0...1.5), range: 0...1.5, step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" }, accent: a)
                }
                ChipRow(title: "Glow colour", options: [("accent", "Accent"), ("second", "Second colour"), ("white", "White")],
                        selection: model.binding(SettingsKeys.glowColor), accent: a)
                SliderRow(title: "Breathe", detail: "The wheel slowly swells and settles.", value: model.clamped(SettingsKeys.breathe, 0...1),
                          range: 0...1, step: 0.05, format: { $0 == 0 ? "off" : "\(Int(($0 * 100).rounded())) %" }, accent: a)
                SliderRow(title: "Orbiting dots", value: model.double(SettingsKeys.ringDots), range: 0...36, step: 1,
                          format: { $0 == 0 ? "none" : "\(Int($0))" }, accent: a)
                SliderRow(title: "Orbit speed", value: model.clamped(SettingsKeys.ringSpin, 0...20), range: 0...20, step: 1,
                          format: { $0 == 0 ? "still" : "\(Int($0)) rpm" }, accent: a)
                ToggleRow(title: "Twirl in", detail: "The wheel spins into place as it opens.", isOn: model.binding(SettingsKeys.twirl), accent: a)
                ToggleRow(title: "Sparks", detail: "A small burst when a button lights up.", isOn: model.binding(SettingsKeys.sparks), accent: a)
            }
            SettingsCard(title: "Accessibility", footer: "These follow System Settings → Accessibility → Display.") {
                accessibilityLine("Reduce Motion", Motion.reduceMotion, on: "the wheel fades in, no springs")
                accessibilityLine("Reduce Transparency", Motion.reduceTransparency, on: "Ring uses Halo's solid disc")
                accessibilityLine("Differentiate Without Colour", Motion.differentiateWithoutColor, on: "the hovered button gets a dashed outline")
                Text("Text keeps at least 4.5:1 contrast in every theme, and the wheel works with VoiceOver and the keyboard (arrows, Return, Esc).")
                    .font(Halo.rounded(11)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                HaloButton(title: "Paste theme", primary: true, accent: a) { model.pasteTheme() }
                    .help("Apply a theme copied from the Circularity website")
                HaloButton(title: "Copy theme", accent: a) { model.copyTheme() }
                HaloButton(title: "Export…", accent: a) { model.exportSettings(appearanceOnly: true) }
                HaloButton(title: "Import…", accent: a) { model.importSettings() }
                Spacer()
                HaloButton(title: "Reset appearance", accent: a) { model.resetAppearance() }
            }
        }
    }

    private func tintRow(_ title: String, _ key: SettingsKey<String>) -> some View {
        let value = model.store.value(key)
        return HStack(spacing: 8) {
            Text(title).font(Halo.rounded(12)).foregroundStyle(Halo.text)
            Spacer()
            if !value.isEmpty {
                Button("None") { model.store.set("", for: key) }.buttonStyle(.plain).font(Halo.rounded(11, .semibold)).foregroundStyle(model.accent)
            }
            ColorPicker(title, selection: colorBinding(model.binding(key), fallback: Color(hex: 0x3A3D45)), supportsOpacity: false).labelsHidden()
        }
    }

    /// A colour setting; `allowsNone` offers "Auto" (the layout's own colour).
    private func colourRow(_ title: String, _ key: SettingsKey<String>, allowsNone: Bool = true) -> some View {
        let value = model.store.value(key)
        return HStack(spacing: 8) {
            Text(title).font(Halo.rounded(12)).foregroundStyle(Halo.text)
            Spacer()
            if allowsNone {
                if value.isEmpty {
                    Text("Auto").font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
                } else {
                    Button("Auto") { model.store.set("", for: key) }.buttonStyle(.plain).font(Halo.rounded(11, .semibold)).foregroundStyle(model.accent)
                }
            }
            ColorPicker(title, selection: colorBinding(model.binding(key), fallback: Color(hex: 0x3A3D45)), supportsOpacity: false).labelsHidden()
        }
    }

    private func accessibilityLine(_ name: String, _ on: Bool, on effect: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? model.accent : Halo.secondary)
            Text("\(name): \(on ? "on — \(effect)" : "off")").font(Halo.rounded(12)).foregroundStyle(Halo.text)
        }
    }
}

struct ThemeCard: View {
    let name: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 16, height: 16).shadow(color: color.opacity(0.6), radius: 6)
                    Capsule().fill(color.opacity(0.35)).frame(width: 26, height: 6)
                }
                Text(name.uppercased()).font(Halo.mono(11, .bold)).tracking(0.6).foregroundStyle(selected ? color : Halo.text)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Halo.control))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? color : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
