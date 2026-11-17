import AppKit
import CircularityEngine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Colour helpers

extension Color {
    /// Text that reads on this colour used as a fill (≥ 4.5:1, ThemeContrastTests).
    var readableText: Color {
        let rgb = RGB(nsColor: NSColor(self))
        let on = ThemeCatalog.onAccent(rgb)
        return Color(.sRGB, red: on.r, green: on.g, blue: on.b)
    }

    init(rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

extension RGB {
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? .white
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}

/// A hex-string setting as a SwiftUI colour ("" = none, shown as `fallback`).
func colorBinding(_ binding: Binding<String>, fallback: Color = .gray) -> Binding<Color> {
    Binding(get: { RGB(hexString: binding.wrappedValue).map { Color(rgb: $0) } ?? fallback },
            set: { binding.wrappedValue = RGB(nsColor: NSColor($0)).hexString })
}

// MARK: - Layout pieces (Halo look: graphite cards, mono headers)

struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionLabel(text: title).padding(.leading, 2) }
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Halo.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Halo.hairline))
            if let footer {
                Text(footer).font(Halo.rounded(11)).foregroundStyle(Halo.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Halo.rounded(13, .semibold)).foregroundStyle(Halo.text)
                if let detail {
                    Text(detail).font(Halo.rounded(11)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .accessibilityElement(children: .contain)
    }
}

struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    let accent: Color

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(accent)
        }
    }
}

/// A row of chips acting as a segmented control.
struct ChipPicker: View {
    let options: [(id: String, name: String)]
    @Binding var selection: String
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.id) { option in
                Chip(title: option.name, selected: selection == option.id, accent: accent) { selection = option.id }
            }
        }
    }
}

struct ChipRow: View {
    let title: String
    var detail: String?
    let options: [(id: String, name: String)]
    @Binding var selection: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: title, detail: detail) { EmptyView() }
            ChipPicker(options: options, selection: $selection, accent: accent)
        }
    }
}

struct SliderRow: View {
    let title: String
    var detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let format: (Double) -> String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Halo.rounded(13, .semibold)).foregroundStyle(Halo.text)
                Spacer()
                Text(format(value)).font(Halo.mono(12, .semibold)).foregroundStyle(accent).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step).tint(accent).accessibilityLabel(title)
                .accessibilityValue(format(value))
            if let detail {
                Text(detail).font(Halo.rounded(11)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HaloButton: View {
    let title: String
    var primary = false
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Halo.rounded(12, .semibold))
                .foregroundStyle(primary ? accent.readableText : Halo.text)
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(primary ? accent : Halo.control))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(primary ? 0 : 0.10)))
        }
        .buttonStyle(.plain)
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(Halo.mono(24, .heavy)).tracking(1.2).foregroundStyle(accent)
            Text(subtitle).font(Halo.rounded(12, .semibold)).foregroundStyle(Halo.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Hotkey recorder

struct HotkeyRecorder: View {
    @ObservedObject var model: SettingsModel
    let key: SettingsKey<String>
    let other: SettingsKey<String>
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Type a shortcut…" : (HotkeySpec(model.store.value(key))?.display ?? "Off"))
                    .font(Halo.mono(12, .bold))
                    .foregroundStyle(recording ? model.accent : Halo.text)
                    .frame(minWidth: 110).frame(height: 28).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Halo.control))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(recording ? model.accent : Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recording ? "Recording a shortcut" : "Shortcut \(HotkeySpec(model.store.value(key))?.display ?? "off"), click to change")
            if !model.store.value(key).isEmpty && !recording {
                Button { model.store.set("", for: key); model.applyHotkeys() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Halo.secondary)
                }
                .buttonStyle(.plain).help("Turn this shortcut off").accessibilityLabel("Turn this shortcut off")
            }
            if model.store.value(key) != key.defaultValue && !recording {
                Button("Default") { model.store.set(key.defaultValue, for: key); model.applyHotkeys() }
                    .buttonStyle(.plain).font(Halo.rounded(11, .semibold)).foregroundStyle(model.accent)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        recording = true
        model.host?.settingsSuspendHotkeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isDisjoint(with: [.command, .control, .option, .shift]) {
                stop()
                return nil
            }
            var mods = 0
            if flags.contains(.command) { mods |= HotkeySpec.command }
            if flags.contains(.shift) { mods |= HotkeySpec.shift }
            if flags.contains(.option) { mods |= HotkeySpec.option }
            if flags.contains(.control) { mods |= HotkeySpec.control }
            let spec = HotkeySpec(keyCode: Int(event.keyCode), modifiers: mods)
            guard spec.isAllowed else {
                NSSound.beep()
                model.flash("Hold ⌘, ⌃ or ⌥ with the key, so it doesn't get in the way of typing.")
                return nil
            }
            if HotkeySpec(model.store.value(other)) == spec {
                NSSound.beep()
                model.flash("\(spec.display) is already the other shortcut.")
                return nil
            }
            model.store.set(spec.stored, for: key)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        model.applyHotkeys()
    }
}

// MARK: - Live wheel preview

/// Draws the wheel with the current settings into an image, using the real
/// renderers (Settings → Wheel and Appearance).
final class WheelPreviewRenderer {
    private var renderers: [WheelLayoutKind: WheelRenderer] = [:]
    private var thumbnail: CGImage? = samplePicture(size: 240, scale: 1)
    private var cache: (key: String, image: NSImage?)?

    /// Everything the preview depends on; other settings changes reuse the last image.
    private static let keys: [AnySettingsKey] = SettingsModel.appearanceKeys + [
        SettingsKeys.wheelLayout.erased, SettingsKeys.imageFormatOrder.erased, SettingsKeys.presetsJSON.erased,
    ]

    func image(store: SettingsStore, hover: WheelTarget, fanOpen: Bool) -> NSImage? {
        let key = Self.keys.map { "\(store.raw($0.name) ?? "-")" }.joined(separator: "|") + "|\(hover)|\(fanOpen)|\(Appearance.systemIsDark)"
        if let cache, cache.key == key { return cache.image }
        let image = draw(store: store, hover: hover, fanOpen: fanOpen)
        cache = (key, image)
        return image
    }

    private func draw(store: SettingsStore, hover: WheelTarget, fanOpen: Bool) -> NSImage? {
        let layout = WheelLayoutKind(rawValue: store.value(SettingsKeys.wheelLayout)) ?? .halo
        let renderer = renderers[layout] ?? {
            let made: WheelRenderer = switch layout {
            case .ring: SectorRenderer(style: .ring)
            case .halo: SectorRenderer(style: .halo)
            case .orbit: OrbitRenderer()
            }
            made.allowsTilt = false
            renderers[layout] = made
            return made
        }()
        let geometry = Appearance.geometry(store, layout: layout)
        let style = Appearance.wheelStyle(store, layout: layout)
        let menu = SlotProvider.menu(for: [.heic], canWrite: { FormatSupport.current.canWrite($0) },
                                     presets: Preset.decodeList(store.value(SettingsKeys.presetsJSON)),
                                     formatOrder: SlotProvider.imageFormatOrder(store.value(SettingsKeys.imageFormatOrder)))
        let content = OrbContent(fileLine: "IMG_2041.HEIC · 3.2 MB", title: "IMG_2041.HEIC", detail: "3.2 MB", count: 1,
                                 thumbnail: thumbnail, clickMode: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.configure(menu: menu, orb: content, style: style, geometry: geometry, contentsScale: 1)
        var state = WheelVisualState(hover: hover, fanOpen: fanOpen)
        if case let .segment(i) = hover {
            let o = WheelGeometry.offset(radius: geometry.contentRadius(hovered: true), angle: WheelGeometry.midAngle(ofSlot: i))
            state.cursor = CGPoint(x: o.x + 20, y: o.y + 20)
        }
        renderer.apply(state, animated: false)
        CATransaction.commit()
        let size = CGSize(width: geometry.size, height: geometry.size)
        let light = style.light
        guard let image = renderImage(size: size, scale: 1, { ctx in
            // A desktop-like backdrop, so glass and shadows read as they would.
            let colors = light ? [CGColor.hex(0xDCD6CC), .hex(0xB9C4D0)] : [CGColor.hex(0x2B3242), .hex(0x14171E)]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
            }
            renderer.layer.layoutIfNeeded()
            renderer.layer.render(in: ctx)
        }) else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

struct WheelPreview: View {
    @ObservedObject var model: SettingsModel
    let renderer: WheelPreviewRenderer
    var height: CGFloat = 300

    var body: some View {
        let fan = model.previewHover == .fanChip(0)
        VStack(spacing: 8) {
            if let image = renderer.image(store: model.store, hover: model.previewHover, fanOpen: fan) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(1, contentMode: .fit)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Preview of the wheel with these settings")
            }
            ChipPicker(options: [("rest", "Resting"), ("hover", "Hover"), ("more", "More fan"), ("cancel", "Cancel")],
                       selection: Binding(get: {
                           switch model.previewHover {
                           case .segment: "hover"
                           case .fanChip: "more"
                           case .centre: "cancel"
                           default: "rest"
                           }
                       }, set: { id in
                           model.previewHover = switch id {
                           case "hover": .segment(1)
                           case "more": .fanChip(0)
                           case "cancel": .centre
                           default: .none
                           }
                       }), accent: model.accent)
        }
        .frame(maxWidth: .infinity)
    }
}
