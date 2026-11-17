import AppKit
import CircularityEngine
import UniformTypeIdentifiers

/// `--render-previews <dir>` (PLAN.md §3.9): renders UI to PNG offscreen.
/// Renders the status glyph on board H's bars and every wheel layout in the
/// board states; (h) and (i) add the panel and windows.
enum RenderPreviews {
    static func run(into directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try renderWheels(into: directory)
            let variants: [(name: String, bar: NSColor, glyph: NSColor)] = [
                ("light-mono", NSColor(hex: 0xE4E0DA), NSColor(hex: 0x1D1B18)),
                ("dark-mono", NSColor(hex: 0x26272C), NSColor(hex: 0xF2F2F2)),
            ]
            for variant in variants {
                for size in [16, 32] as [CGFloat] {
                    let url = directory.appendingPathComponent("status-idle-\(variant.name)-\(Int(size))pt@2x.png")
                    let data = try png(size: CGSize(width: size * 2, height: size * 2), scale: 2, background: variant.bar) {
                        let glyph = StatusGlyph.image(pointSize: size, color: variant.glyph, template: false)
                        glyph.draw(in: CGRect(x: size / 2, y: size / 2, width: size, height: size))
                    }
                    try data.write(to: url)
                    print(url.path)
                }
            }
            return true
        } catch {
            FileHandle.standardError.write(Data("render-previews failed: \(error)\n".utf8))
            return false
        }
    }

    private struct RenderError: Error {}

    /// Wheel states matching the board screenshots (D: hover JPG, More fan,
    /// Cancel, Compress), for each layout and a few file kinds.
    private static func renderWheels(into directory: URL) throws {
        let photo = [UTType.heic]
        let states: [(String, WheelVisualState)] = [
            ("rest", WheelVisualState()),
            ("hover-jpg", WheelVisualState(hover: .segment(1))),
            ("more-fan", WheelVisualState(hover: .fanChip(0), fanOpen: true)),
            ("more-fan-flipped", WheelVisualState(hover: .fanChip(4), fanOpen: true, fanFlipped: true)),
            ("cancel", WheelVisualState(hover: .centre)),
            ("compress", WheelVisualState(hover: .segment(4))),
        ]
        let cases: [(WheelLayoutKind, [UTType], Int, UInt32, UInt32)] = [
            (.ring, photo, 1, 0xFF8A00, 0x1F2228),
            (.orbit, [.png, .png, .png], 3, 0xFF8A00, 0xE9E5DF),
            (.halo, photo, 1, 0xC6FF3D, 0x0D0F14),
        ]
        for (kind, types, count, accent, backdrop) in cases {
            for (name, state) in states {
                try renderWheel(kind: kind, types: types, count: count, accent: accent, backdrop: backdrop,
                                state: state, to: directory.appendingPathComponent("wheel-\(kind.rawValue)-\(name)@2x.png"))
            }
        }
        // Other file kinds on the default Ring.
        let extra: [(String, [UTType], WheelVisualState)] = [
            ("pdf", [.pdf], WheelVisualState(hover: .segment(0))),
            ("markdown", [UTType("net.daringfireball.markdown") ?? .plainText], WheelVisualState(hover: .segment(1))),
            ("video", [.mpeg4Movie], WheelVisualState()),
            ("batch", [.jpeg, .png], WheelVisualState(hover: .segment(2))),
        ]
        for (name, types, state) in extra {
            try renderWheel(kind: .ring, types: types, count: types.count, accent: 0xFF8A00, backdrop: 0x1F2228,
                            state: state, to: directory.appendingPathComponent("wheel-ring-\(name)@2x.png"))
        }
    }

    private static func renderWheel(kind: WheelLayoutKind, types: [UTType], count: Int, accent: UInt32, backdrop: UInt32,
                                    state: WheelVisualState, to url: URL) throws {
        let renderer: WheelRenderer = switch kind {
        case .ring: SectorRenderer(style: .ring)
        case .halo: SectorRenderer(style: .halo)
        case .orbit: OrbitRenderer()
        }
        renderer.allowsTilt = false // render(in:) skips 3D transforms
        let menu = SlotProvider.menu(for: types, canWrite: { FormatSupport.current.canWrite($0) })
        let single = count == 1
        let content = OrbContent(fileLine: single ? "IMG_2041.HEIC · 3.2 MB" : "\(count) images · 8.7 MB",
                                 title: single ? "IMG_2041.HEIC" : "\(count) images",
                                 detail: single ? "3.2 MB" : "8.7 MB total", count: count,
                                 thumbnail: samplePicture(size: 240, scale: 2), clickMode: false)
        let geometry = WheelGeometry.make(kind)
        renderer.configure(menu: menu, orb: content, accent: .hex(accent), geometry: geometry, contentsScale: 2)
        var s = state
        if case .segment = s.hover {
            let o = WheelGeometry.offset(radius: geometry.contentRadius(hovered: true), angle: 60)
            s.cursor = CGPoint(x: o.x + 20, y: o.y + 20)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.apply(s, animated: false)
        CATransaction.commit()
        let size = CGSize(width: geometry.size, height: geometry.size)
        guard let image = renderImage(size: size, scale: 2, { ctx in
            ctx.setFillColor(.hex(backdrop))
            ctx.fill(CGRect(origin: .zero, size: size))
            renderer.layer.layoutIfNeeded()
            renderer.layer.render(in: ctx)
        }), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw RenderError()
        }
        try data.write(to: url)
        print(url.path)
    }

    private static func png(size: CGSize, scale: CGFloat, background: NSColor, draw: () -> Void) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw RenderError() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background.setFill()
        CGRect(origin: .zero, size: size).fill()
        draw()
        NSGraphicsContext.current?.flushGraphics()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError() }
        return data
    }
}

extension NSColor {
    /// sRGB colour from a 0xRRGGBB literal (design tokens, PLAN.md §9).
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
