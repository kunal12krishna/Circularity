import CoreGraphics
import Foundation
import ImageIO

/// Live "about 2.9 MB" estimates for the wheel's centre (PLAN.md §3.3).
/// Only JPEG and PNG are really encoded (a ≤ 1600 px downsample, scaled by the
/// pixel ratio). HEIC, AVIF, WebP and GIF are derived from those with ratios
/// measured on photos, and BMP/TIFF are computed: loading the HEIC and AVIF
/// encoders just for a hint cost ~35 MB that stayed for the life of the app
/// (docs/PERF-REPORT.md). The Compress and Resize dialogs still encode for real.
public enum SizeEstimator {
    public static let wheelSample = 1600

    /// Typical size relative to JPEG at the app's default qualities
    /// (JPG 85, HEIC 80, AVIF 75, WebP 80), measured on photos.
    public static let ratioToJPEG: [OutputFormat: Double] = [.heic: 0.6, .avif: 0.45, .webp: 0.75]

    public static func estimate(_ url: URL, formats: [OutputFormat], support: FormatSupport = .current) -> [OutputFormat: Int64] {
        guard let input = try? ImageInput.open(url),
              let small = try? autoreleasepool(invoking: { try input.upright(maxPixel: wheelSample) }) else { return [:] }
        let full = input.uprightSize
        let pixels = Double(full.width * full.height)
        let ratio = pixels / Double(max(1, small.width * small.height))
        func encoded(_ format: OutputFormat) -> Int64? {
            autoreleasepool {
                (try? ImageOps.encode(small, as: format, quality: OutputPolicy().quality(for: format))).map { Int64(Double($0.count) * ratio) }
            }
        }
        let needsJPEG = formats.contains { $0 != .png && $0 != .bmp && $0 != .tiff }
        let jpg = needsJPEG ? encoded(.jpg) : nil
        let png = formats.contains(.png) || formats.contains(.gif) ? encoded(.png) : nil
        let channels = Double(ImageOps.hasAlpha(small) ? 4 : 3)
        var result: [OutputFormat: Int64] = [:]
        for format in formats where format == .pdf || format == .bmp || support.canWrite(format) {
            switch format {
            case .jpg: result[format] = jpg
            case .png: result[format] = png
            case .pdf: result[format] = jpg.map { $0 + 2_000 }
            case .bmp: result[format] = Int64(pixels * 3) + 54
            case .tiff: result[format] = Int64(pixels * channels) + 8_000 // uncompressed
            case .gif:
                // 256 colours: about 1.4–1.9× a JPEG for photos, never more than PNG for flat graphics.
                if let jpg, let png { result[format] = min(png, Int64(Double(jpg) * 2)) } else { result[format] = png }
            default:
                if let jpg, let k = ratioToJPEG[format] { result[format] = Int64(Double(jpg) * k) }
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
