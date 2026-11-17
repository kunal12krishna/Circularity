#!/usr/bin/env swift
// Draws the DMG window background in the Halo look (graphite, neon accent):
// background.png (660 × 420) and background@2x.png. Usage:
//   swift scripts/make-dmg-art.swift <output dir>
// Layout matches scripts/dmg.sh: app icon at (180, 200), Applications at (480, 200).
import AppKit
import CoreGraphics
import CoreText

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-art.swift <output dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let width: CGFloat = 660, height: CGFloat = 420
let neon = rgb(0xC6FF3D)

/// Draws text with its baseline-left at (x, y) in the y-down canvas.
func text(_ ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight,
          color: CGColor, mono: Bool = false, kern: CGFloat = 0, centered: Bool = false) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color) ?? .white, .kern: kern,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: centered ? x - CGFloat(w) / 2 : x, y: y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func render(scale: CGFloat) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: height * scale)
    ctx.scaleBy(x: scale, y: -scale) // y-down, points
    ctx.setShouldSmoothFonts(false)

    // Graphite with a soft glow behind each icon.
    ctx.setFillColor(rgb(0x0D0F14))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for x in [180.0, 480.0] as [CGFloat] {
        let glow = CGGradient(colorsSpace: space, colors: [rgb(0x1E222B), rgb(0x0D0F14, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: x, y: 196), startRadius: 0,
                               endCenter: CGPoint(x: x, y: 196), endRadius: 130, options: [])
    }
    // Halo-style hairline ring segments around the app.
    ctx.setStrokeColor(neon.copy(alpha: 0.28)!)
    ctx.setLineWidth(1)
    ctx.setLineCap(.round)
    for i in 0..<6 {
        let mid = CGFloat(i) * 60 - 90
        let start = (mid - 26) * .pi / 180, end = (mid + 26) * .pi / 180
        ctx.addArc(center: CGPoint(x: 180, y: 196), radius: 92, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()
    }

    // Title.
    text(ctx, "CIRCULARITY", x: 40, y: 58, size: 22, weight: .heavy, color: neon, mono: true, kern: 2.2)
    text(ctx, "Drag files. Tap Shift. Convert.", x: 40, y: 82, size: 13, weight: .semibold, color: rgb(0x9097A6))

    // Arrow from the app to Applications.
    ctx.setStrokeColor(neon)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 268, y: 196))
    ctx.addLine(to: CGPoint(x: 390, y: 196))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 378, y: 184))
    ctx.addLine(to: CGPoint(x: 392, y: 196))
    ctx.addLine(to: CGPoint(x: 378, y: 208))
    ctx.strokePath()
    text(ctx, "DRAG TO INSTALL", x: 330, y: 176, size: 10, weight: .bold, color: rgb(0x9097A6), mono: true, kern: 1, centered: true)

    // First-launch note (the app is ad-hoc signed until it has a Developer ID).
    ctx.setFillColor(rgb(0x1A1D24))
    let note = CGRect(x: 40, y: 330, width: 580, height: 52) // one line: fits 580 pt at 12 pt
    ctx.addPath(CGPath(roundedRect: note, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.fillPath()
    text(ctx, "FIRST LAUNCH", x: 58, y: 352, size: 10, weight: .bold, color: neon, mono: true, kern: 1)
    text(ctx, "If macOS blocks it: System Settings → Privacy & Security → Open Anyway.", x: 58, y: 370,
         size: 12, weight: .medium, color: rgb(0xECEEF2))
    return ctx.makeImage()!
}

for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] as [(CGFloat, String)] {
    let image = render(scale: scale)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: width, height: height)
    let url = outDir.appendingPathComponent(name)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.path)
}
