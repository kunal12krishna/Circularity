import AppKit
import SwiftUI

/// Halo-styled building blocks for the tool dialogs (the user's favourite look:
/// graphite surfaces, monospace labels, neon accent — board C).
enum Halo {
    static let background = Color(hex: 0x0D0F14)
    static let card = Color(hex: 0x1A1D24)
    static let control = Color(hex: 0x1B1D23)
    static let text = Color(hex: 0xECEEF2)
    static let secondary = Color(hex: 0x9097A6)
    static let hairline = Color.white.opacity(0.08)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Halo.mono(10, .semibold)).tracking(0.8).foregroundStyle(Halo.secondary)
    }
}

/// A selectable chip (also used as a segmented control).
struct Chip: View {
    let title: String
    var selected = false
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Halo.mono(12))
                .tracking(0.6)
                .padding(.horizontal, 11)
                .frame(minHeight: 30)
                .foregroundStyle(selected ? Halo.background : Halo.text)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent : Halo.control))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(selected ? 0 : 0.10)))
                .shadow(color: selected ? accent.opacity(0.45) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A number field with a unit, Halo-styled.
struct NumberField: View {
    let label: String
    @Binding var text: String
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Halo.mono(16))
                    .foregroundStyle(Halo.text)
                    .accessibilityLabel(label)
                if !unit.isEmpty { Text(unit).font(Halo.mono(12, .semibold)).foregroundStyle(Halo.secondary) }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Halo.control))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Halo.hairline))
        }
    }
}

/// Header, content, "Also add this as a button", Cancel / primary.
struct DialogFrame<Content: View>: View {
    let title: String
    let subtitle: String
    let accent: Color
    let primaryTitle: String
    var primaryEnabled = true
    var addButton: Binding<Bool>?
    let onPrimary: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(Halo.mono(26, .heavy)).tracking(1.2).foregroundStyle(accent)
                Text(subtitle).font(Halo.rounded(12, .semibold)).foregroundStyle(Halo.secondary).lineLimit(1)
            }
            content()
            if let addButton {
                Toggle(isOn: addButton) {
                    Text("Also add this as a button on the wheel").font(Halo.rounded(12, .semibold)).foregroundStyle(Halo.text)
                }
                .toggleStyle(.switch)
                .tint(accent)
            }
            HStack {
                Spacer()
                Button(action: onCancel) {
                    Text("CANCEL").font(Halo.mono(12)).tracking(0.8).foregroundStyle(Halo.text)
                        .padding(.horizontal, 16).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Halo.control))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: onPrimary) {
                    Text(primaryTitle.uppercased()).font(Halo.mono(12, .heavy)).tracking(0.8).foregroundStyle(Halo.background)
                        .padding(.horizontal, 18).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(accent.opacity(primaryEnabled ? 1 : 0.35)))
                        .shadow(color: accent.opacity(primaryEnabled ? 0.5 : 0), radius: 10)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!primaryEnabled)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Halo.background)
        .environment(\.colorScheme, .dark)
    }
}

/// Shows one dialog at a time in a floating, dark, borderless-looking panel.
/// The SwiftUI content is created on open and released on close (PLAN.md §5).
final class DialogPresenter: NSObject, NSWindowDelegate {
    private var window: NSPanel?

    func present<V: View>(_ view: V, title: String) {
        close()
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: hosting.view.fittingSize),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(srgbRed: 13 / 255, green: 15 / 255, blue: 20 / 255, alpha: 1)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = hosting
        panel.delegate = self
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 60))
        }
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        DispatchQueue.main.async { MemoryFootprint.relieve() }
    }
}

enum Bytes {
    static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func change(from before: Int64, to after: Int64) -> String {
        guard before > 0 else { return "" }
        let pct = Double(after - before) / Double(before) * 100
        return String(format: "%@%.0f%%", pct >= 0 ? "+" : "−", abs(pct))
    }
}
