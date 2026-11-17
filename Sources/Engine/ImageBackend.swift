import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An opened image: ImageIO for everything it reads, NSImage for SVG
/// (rendered locally; never fetches external resources) (PLAN.md §3.1).
struct ImageInput {
    let url: URL
    private let source: CGImageSource?
    private let raster: CGImage?
    let index: Int
    let properties: [CFString: Any]

    static func open(_ url: URL) throws -> ImageInput {
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .svg) {
            guard let image = SVGRasterizer.rasterize(url) else { throw JobError.unreadable(url.lastPathComponent) }
            return ImageInput(url: url, source: nil, raster: image, index: 0, properties: [:])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw JobError.unreadable(url.lastPathComponent) }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        return ImageInput(url: url, source: source, raster: nil, index: index, properties: props)
    }

    var frameCount: Int { source.map(CGImageSourceGetCount) ?? 1 }
    var sourceType: String? { source.flatMap { CGImageSourceGetType($0) as String? } }
    var orientation: Int { properties[kCGImagePropertyOrientation] as? Int ?? 1 }

    /// Pixel size after applying EXIF orientation.
    var uprightSize: CGSize {
        if let raster { return CGSize(width: raster.width, height: raster.height) }
        let w = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// The image the right way up, optionally downsampled so its long edge is
    /// at most `maxPixel` (ImageIO decodes straight to that size: no full-size copy).
    func upright(maxPixel: Int? = nil) throws -> CGImage {
        if let raster {
            guard let maxPixel, CGFloat(maxPixel) < max(uprightSize.width, uprightSize.height) else { return raster }
            let s = CGFloat(maxPixel) / max(uprightSize.width, uprightSize.height)
            return try ImageOps.scaled(raster, to: CGSize(width: uprightSize.width * s, height: uprightSize.height * s))
        }
        guard let source else { throw JobError.unreadable(url.lastPathComponent) }
        let longEdge = Int(max(uprightSize.width, uprightSize.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? longEdge, max(longEdge, 1)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw JobError.unreadable(url.lastPathComponent)
        }
        return image
    }

    /// Metadata to carry into the output under `policy`, with orientation reset
    /// (pixels are always written upright).
    func outputProperties(policy: MetadataPolicy) -> [CFString: Any] {
        var props: [CFString: Any] = [:]
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] { props[key] = properties[key] }
        if policy != .stripAll {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyGPSDictionary] {
                props[key] = properties[key]
            }
            if policy == .stripGPS { props[kCGImagePropertyGPSDictionary] = nil }
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        props[kCGImagePropertyOrientation] = 1
        return props
    }

    var dpi: CGFloat { CGFloat(properties[kCGImagePropertyDPIWidth] as? Double ?? 72) }

    /// Animated GIF → GIF keeps every frame.
    func copyFrames(to destination: CGImageDestination) -> Bool {
        guard let source else { return false }
        for i in 0..<CGImageSourceGetCount(source) {
            CGImageDestinationAddImageFromSource(destination, source, i, nil)
        }
        return true
    }
}

enum ImageOps {
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw JobError.encodeFailed("a \(width) × \(height) image")
        }
        ctx.interpolationQuality = .high
        return ctx
    }

    /// Transparent pixels onto white, for formats without alpha (JPG, BMP).
    static func flattened(_ image: CGImage) throws -> CGImage {
        let ctx = try context(width: image.width, height: image.height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { throw JobError.encodeFailed("the flattened image") }
        return out
    }

    static func scaled(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        if w == image.width, h == image.height { return image }
        let ctx = try context(width: w, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw JobError.encodeFailed("the resized image") }
        return out
    }

    static func typeIdentifier(_ format: OutputFormat) throws -> CFString {
        guard let id = format.imageTypeIdentifier else { throw JobError.unsupported("\(format.displayName) as an image") }
        return id as CFString
    }

    static func encodeProperties(_ format: OutputFormat, quality: Double, extra: [CFString: Any]) -> CFDictionary {
        var props = extra
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        return props as CFDictionary
    }

    static func write(_ image: CGImage, as format: OutputFormat, quality: Double, properties: [CFString: Any], to url: URL) throws {
        let image = format.supportsAlpha || !hasAlpha(image) ? image : try flattened(image)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, try typeIdentifier(format), 1, nil) else {
            throw JobError.encodeFailed(format.displayName)
        }
        CGImageDestinationAddImage(dest, image, encodeProperties(format, quality: quality, extra: properties))
        guard CGImageDestinationFinalize(dest) else { throw JobError.encodeFailed(format.displayName) }
    }

    static func encode(_ image: CGImage, as format: OutputFormat, quality: Double, properties: [CFString: Any] = [:]) throws -> Data {
        let image = format.supportsAlpha || !hasAlpha(image) ? image : try flattened(image)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, try typeIdentifier(format), 1, nil) else {
            throw JobError.encodeFailed(format.displayName)
        }
        CGImageDestinationAddImage(dest, image, encodeProperties(format, quality: quality, extra: properties))
        guard CGImageDestinationFinalize(dest) else { throw JobError.encodeFailed(format.displayName) }
        return data as Data
    }

    /// Draws images as PDF pages at their physical size (pixels at their dpi).
    /// Opaque images are embedded as JPEG so the PDF stays small.
    static func writePDF(pages: [(image: CGImage, dpi: CGFloat)], to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw JobError.encodeFailed("PDF") }
        for page in pages {
            let scale = 72 / max(page.dpi, 1)
            var box = CGRect(x: 0, y: 0, width: CGFloat(page.image.width) * scale, height: CGFloat(page.image.height) * scale)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(pdfEmbeddable(page.image), in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    static func pdfEmbeddable(_ image: CGImage) -> CGImage {
        guard !hasAlpha(image), let data = try? encode(image, as: .jpg, quality: 0.85),
              let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return image }
        return jpeg
    }
}

/// Image operations; each writes exactly one file into `output` (a staging path).
enum ImageBackend {
    static func convert(_ input: ImageInput, to format: OutputFormat, policy: OutputPolicy, output: URL) throws {
        if format == .pdf {
            try ImageOps.writePDF(pages: [(try input.upright(), input.dpi)], to: output)
            return
        }
        if format == .gif, input.frameCount > 1, input.sourceType == "com.compuserve.gif" {
            guard let dest = CGImageDestinationCreateWithURL(output as CFURL, try ImageOps.typeIdentifier(.gif),
                                                             input.frameCount, nil),
                  input.copyFrames(to: dest), CGImageDestinationFinalize(dest) else { throw JobError.encodeFailed("GIF") }
            return
        }
        try ImageOps.write(try input.upright(), as: format, quality: policy.quality(for: format),
                           properties: input.outputProperties(policy: policy.metadata), to: output)
    }

    static func resize(_ input: ImageInput, spec: ResizeSpec, format: OutputFormat, policy: OutputPolicy, output: URL) throws {
        let source = input.uprightSize
        let target = ResizeMath.targetSize(source: source, spec: spec)
        let downscale = target.width <= source.width && target.height <= source.height
        // Decode straight at (about) the target size when shrinking.
        var image = try input.upright(maxPixel: downscale ? Int(max(target.width, target.height)) : nil)
        image = try ImageOps.scaled(image, to: target)
        try ImageOps.write(image, as: format, quality: policy.quality(for: format),
                           properties: input.outputProperties(policy: policy.metadata), to: output)
    }

    static func crop(_ input: ImageInput, rect: CGRect, format: OutputFormat, policy: OutputPolicy, output: URL) throws {
        let image = try input.upright()
        let r = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = CGRect(x: (r.minX * CGFloat(image.width)).rounded(), y: (r.minY * CGFloat(image.height)).rounded(),
                            width: max(1, (r.width * CGFloat(image.width)).rounded()),
                            height: max(1, (r.height * CGFloat(image.height)).rounded()))
        guard !r.isEmpty, let cropped = image.cropping(to: pixels) else { throw JobError.encodeFailed("the crop") }
        try ImageOps.write(cropped, as: format, quality: policy.quality(for: format),
                           properties: input.outputProperties(policy: policy.metadata), to: output)
    }

    /// Returns false when compressing would not make the file smaller (nothing written).
    static func compress(_ input: ImageInput, _ compression: ImageCompression, format: OutputFormat, policy: OutputPolicy,
                         originalBytes: Int64, output: URL, progress: (Double) -> Void) throws -> Bool {
        let image = try input.upright()
        let props = input.outputProperties(policy: policy.metadata)
        switch compression {
        case let .quality(q):
            let data = try ImageOps.encode(image, as: format, quality: q, properties: props)
            guard Int64(data.count) < originalBytes else { return false }
            try data.write(to: output)
            return true
        case let .targetBytes(target):
            // Highest quality that fits; downscale by 0.85 steps only if even the floor is too big.
            var current = image
            for step in 0..<12 {
                try Task.checkCancellation()
                var low = 0.3, high = 0.95, best: Data?
                if let top = try? ImageOps.encode(current, as: format, quality: high, properties: props), top.count <= target {
                    best = top
                } else {
                    for _ in 0..<7 {
                        try Task.checkCancellation()
                        let mid = (low + high) / 2
                        let data = try ImageOps.encode(current, as: format, quality: mid, properties: props)
                        if data.count <= target { best = data; low = mid } else { high = mid }
                    }
                    if best == nil, let floor = try? ImageOps.encode(current, as: format, quality: 0.3, properties: props),
                       floor.count <= target { best = floor }
                }
                progress(Double(step + 1) / 12)
                if let best {
                    guard Int64(best.count) < originalBytes else { return false }
                    try best.write(to: output)
                    return true
                }
                current = try ImageOps.scaled(current, to: CGSize(width: CGFloat(current.width) * 0.85,
                                                                  height: CGFloat(current.height) * 0.85))
            }
            throw JobError.targetUnreachable(target)
        }
    }

    /// Compressing a lossless file means re-encoding it in a lossy format.
    static func compressedFormat(for source: OutputFormat?, hasAlpha: Bool, support: FormatSupport) -> OutputFormat {
        if let source, source.isLossy, support.canWrite(source) { return source }
        if hasAlpha, support.canWrite(.heic) { return .heic }
        return .jpg
    }
}

/// SVG → bitmap with AppKit's own renderer (no network). Small icons are scaled
/// up to 1024 px on the long edge; everything is capped at 4096 px.
enum SVGRasterizer {
    static func rasterize(_ url: URL) -> CGImage? {
        let work = {
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil as CGImage? }
            let long = max(image.size.width, image.size.height)
            let targetLong = min(max(long, 1024), 4096)
            let s = targetLong / long
            let w = Int((image.size.width * s).rounded()), h = Int((image.size.height * s).rounded())
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
}
