#!/usr/bin/env swift
// Generates the original Circularity app icon (PLAN.md §2, A12) into an
// .appiconset folder. Usage: swift scripts/make-icon.swift <AppIcon.appiconset>
//
// Design: a tangerine squircle tile (macOS icon grid: 824 pt body on a 1024
// canvas) carrying the board-H segmented-ring glyph in #1A1206.
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output .appiconset dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Board-H glyph segments in its 24-unit, y-down box (PLAN.md §9.3).
let segments: [(CGPoint, CGPoint)] = [
    (CGPoint(x: 12, y: 3), CGPoint(x: 20.5, y: 9)),
    (CGPoint(x: 20.8, y: 13.5), CGPoint(x: 12, y: 21)),
    (CGPoint(x: 8.5, y: 20.3), CGPoint(x: 3.4, y: 9.5)),
]
func mathAngle(_ p: CGPoint) -> CGFloat { atan2(p.y - 12, p.x - 12) } // y-down space

func renderIcon(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels) / 1024
    // Work in a 1024-unit, y-down canvas.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: s, y: -s)
    ctx.interpolationQuality = .high

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0xFF8A00))
    ctx.fillPath()
    ctx.restoreGState()

    // Tangerine gradient, lighter at the top.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(0xFFB24A), rgb(0xFF8A00), rgb(0xF26A00)] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Inner top highlight and hairline.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 60), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 60), endRadius: 560, options: [])
    ctx.restoreGState()
    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // The glyph: 24-unit box scaled to 560 units, centred.
    let g: CGFloat = 560 / 24
    ctx.saveGState()
    ctx.translateBy(x: 512 - 12 * g, y: 512 - 12 * g)
    ctx.scaleBy(x: g, y: g)
    ctx.setStrokeColor(rgb(0x1A1206))
    ctx.setFillColor(rgb(0x1A1206))
    ctx.setLineWidth(2.4)
    ctx.setLineCap(.round)
    for (a, b) in segments {
        // Increasing angle in y-down space sweeps visually clockwise.
        ctx.addArc(center: CGPoint(x: 12, y: 12), radius: 9,
                   startAngle: mathAngle(a), endAngle: mathAngle(b), clockwise: false)
        ctx.strokePath()
    }
    ctx.fillEllipse(in: CGRect(x: 12 - 2.2, y: 12 - 2.2, width: 4.4, height: 4.4))
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try data.write(to: url)
}

// macOS app icon slots: (point size, scale).
let slots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
var rendered: [Int: CGImage] = [:]
for (points, scale) in slots {
    let pixels = points * scale
    let image = rendered[pixels] ?? renderIcon(pixels: pixels)
    rendered[pixels] = image
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try writePNG(image, to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icon images to \(outDir.path)")
