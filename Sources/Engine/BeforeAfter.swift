import CoreGraphics
import Foundation
import ImageIO

/// A side-by-side close-up for the wheel's before/after loupe: the left half
/// of a centre crop as it is, the right half after encoding at `quality`.
/// Works on a ≤ 1400 px sample so it is quick and small.
public enum BeforeAfter {
    public static func image(_ url: URL, format: OutputFormat, quality: Double, side: Int = 240) -> CGImage? {
        guard let input = try? ImageInput.open(url),
              let sample = try? autoreleasepool(invoking: { try input.upright(maxPixel: 1400) }) else { return nil }
        let s = min(side, sample.width, sample.height)
        let crop = CGRect(x: (sample.width - s) / 2, y: (sample.height - s) / 2, width: s, height: s)
        guard let before = sample.cropping(to: crop) else { return nil }
        let after: CGImage? = autoreleasepool {
            guard let data = try? ImageOps.encode(before, as: format, quality: quality),
                  let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let after, let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: s, height: s)
        ctx.interpolationQuality = .none
        ctx.draw(before, in: full)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: s / 2, y: 0, width: s - s / 2, height: s))
        ctx.draw(after, in: full)
        ctx.restoreGState()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.fill(CGRect(x: s / 2 - 1, y: 0, width: 2, height: s))
        return ctx.makeImage()
    }
}
