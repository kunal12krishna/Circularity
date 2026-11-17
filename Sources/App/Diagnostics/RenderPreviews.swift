import AppKit

/// `--render-previews <dir>` (PLAN.md §3.9): renders UI to PNG offscreen.
/// Milestone (a) renders the status glyph on board H's light and dark
/// monochrome bars; (c), (h) and (i) add the wheel, panel and windows.
enum RenderPreviews {
    static func run(into directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
