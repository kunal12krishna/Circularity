import CoreGraphics
import Foundation
import ImageIO

/// Live "about 2.9 MB" estimates for the wheel's centre (PLAN.md §3.3):
/// encodes a ≤ 1600 px downsample once per format and scales by the pixel
/// ratio. Smaller samples lose the fine detail that drives JPEG size; this
/// keeps most of it without ever decoding a huge image at full size.
public enum SizeEstimator {
    public static func estimate(_ url: URL, formats: [OutputFormat], support: FormatSupport = .current) -> [OutputFormat: Int64] {
        guard let input = try? ImageInput.open(url), let small = try? input.upright(maxPixel: 1600) else { return [:] }
        let full = input.uprightSize
        let ratio = Double(full.width * full.height) / Double(max(1, small.width * small.height))
        var result: [OutputFormat: Int64] = [:]
        for format in formats {
            switch format {
            case .bmp:
                result[format] = Int64(full.width * full.height * 3) + 54
            case .pdf:
                if let jpg = try? ImageOps.encode(small, as: .jpg, quality: 0.85) {
                    result[format] = Int64(Double(jpg.count) * ratio) + 2_000
                }
            default:
                guard support.canWrite(format),
                      let data = try? ImageOps.encode(small, as: format, quality: OutputPolicy().quality(for: format)) else { continue }
                result[format] = Int64(Double(data.count) * ratio)
            }
        }
        return result
    }

    public static func describe(_ bytes: Int64) -> String {
        "about " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Small, upright thumbnails straight from ImageIO (no QuickLook needed for images).
public enum Thumbnails {
    public static func image(_ url: URL, maxPixel: Int) -> CGImage? {
        try? ImageInput.open(url).upright(maxPixel: maxPixel)
    }
}

extension SizeEstimator {
    /// Estimated size of `url` encoded as `format` at `quality`, optionally
    /// resized to `pixels` (upright). Used by the Compress and Resize dialogs.
    public static func estimate(_ url: URL, format: OutputFormat, quality: Double, pixels: CGSize? = nil) -> Int64? {
        guard let input = try? ImageInput.open(url), let small = try? input.upright(maxPixel: 1600) else { return nil }
        let full = input.uprightSize
        let target = pixels ?? full
        let ratio = Double(target.width * target.height) / Double(max(1, small.width * small.height))
        if format == .bmp { return Int64(target.width * target.height * 3) + 54 }
        let encodeAs: OutputFormat = format == .pdf ? .jpg : format
        guard let data = try? ImageOps.encode(small, as: encodeAs, quality: quality) else { return nil }
        return Int64(Double(data.count) * ratio)
    }
}

extension Thumbnails {
    /// Pixel size after EXIF orientation, without decoding the image.
    public static func pixelSize(_ url: URL) -> CGSize? {
        guard let input = try? ImageInput.open(url) else { return nil }
        let size = input.uprightSize
        return size.width > 0 ? size : nil
    }

    /// The first page of a PDF and its size in points.
    public static func pdfPage(_ url: URL, maxPixel: CGFloat) -> (image: CGImage, size: CGSize)? {
        guard let doc = try? PDFBackend.open(url), let page = doc.page(at: 1) else { return nil }
        let size = PDFBackend.displaySize(page)
        guard let image = try? PDFBackend.render(page, scale: maxPixel / max(size.width, size.height)) else { return nil }
        return (image, size)
    }

    public static func pdfPageCount(_ url: URL) -> Int {
        (try? PDFBackend.open(url))?.numberOfPages ?? 0
    }
}

extension ConversionEngine {
    /// The format Compress saves an image as (lossless sources become JPG, or
    /// HEIC when they have transparency).
    public static func compressedFormat(for url: URL, support: FormatSupport = .current) -> OutputFormat {
        let input = try? ImageInput.open(url)
        let alpha = (try? input?.upright(maxPixel: 64)).flatMap { $0 }.map(ImageOps.hasAlpha) ?? false
        return ImageBackend.compressedFormat(for: imageFormat(of: type(of: url)), hasAlpha: alpha, support: support)
    }

    /// The format Resize/Crop keep (the source format when it can be written).
    public static func sameFormat(for url: URL, support: FormatSupport = .current) -> OutputFormat {
        if let f = imageFormat(of: type(of: url)), support.canWrite(f) { return f }
        return .png
    }
}
