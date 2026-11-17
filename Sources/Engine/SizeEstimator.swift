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
