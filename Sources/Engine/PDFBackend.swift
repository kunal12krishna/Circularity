import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Quartz

/// PDF operations (PLAN.md §3.1). Pages are processed one at a time inside an
/// autorelease pool so a 200-page document never sits in memory at once.
enum PDFBackend {
    static func open(_ url: URL) throws -> CGPDFDocument {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw JobError.unreadable(url.lastPathComponent) }
        if doc.isEncrypted, !doc.unlockWithPassword("") { throw JobError.unsupported("a password-protected PDF") }
        return doc
    }

    /// The crop box as displayed (after /Rotate).
    static func displaySize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// Draws `page` filling `rect` the right way up.
    static func draw(_ page: CGPDFPage, in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        let size = displaySize(page)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0,
                                                 preserveAspectRatio: true))
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    /// Renders one page to a bitmap (white background).
    static func render(_ page: CGPDFPage, scale: CGFloat, maxPixel: CGFloat = 10_000) throws -> CGImage {
        let size = displaySize(page)
        let s = min(scale, maxPixel / max(size.width, size.height))
        let w = max(1, Int((size.width * s).rounded())), h = max(1, Int((size.height * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw JobError.encodeFailed("a page image") }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        draw(page, in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { throw JobError.encodeFailed("a page image") }
        return image
    }

    // MARK: Pages → images

    static func pages(_ url: URL, format: OutputFormat, scale: Double, baseName: String, into folder: URL,
                      quality: Double, progress: (Int, Int) -> Void) throws {
        let doc = try open(url)
        let n = doc.numberOfPages
        let digits = String(n).count
        for i in 1...n {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                let image = try render(page, scale: CGFloat(scale))
                let number = String(repeating: "0", count: digits - String(i).count) + String(i)
                let name = OutputNaming.sanitize("\(baseName) page \(number)")
                try ImageOps.write(image, as: format, quality: quality, properties: [:],
                                   to: folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension))
            }
            progress(i, n)
        }
    }

    // MARK: Text

    static func extractText(_ url: URL, to output: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw JobError.unreadable(url.lastPathComponent) }
        var parts: [String] = []
        for i in 0..<doc.pageCount { parts.append(doc.page(at: i)?.string ?? "") }
        do {
            try parts.joined(separator: "\n\n\u{0C}").write(to: output, atomically: false, encoding: .utf8)
        } catch {
            throw JobError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Combine (drop order)

    static func combine(_ inputs: [URL], to output: URL, progress: (Int, Int) -> Void) throws {
        guard let ctx = CGContext(output as CFURL, mediaBox: nil, nil) else { throw JobError.encodeFailed("PDF") }
        defer { ctx.closePDF() }
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let type = ConversionEngine.type(of: url)
                if type.conforms(to: .pdf) {
                    let doc = try open(url)
                    for p in 1...doc.numberOfPages {
                        guard let page = doc.page(at: p) else { continue }
                        var box = CGRect(origin: .zero, size: displaySize(page))
                        ctx.beginPage(mediaBox: &box)
                        draw(page, in: ctx, rect: box)
                        ctx.endPage()
                    }
                } else if type.conforms(to: .image) {
                    let input = try ImageInput.open(url)
                    let image = try input.upright()
                    let k = 72 / max(input.dpi, 1)
                    var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
                    ctx.beginPage(mediaBox: &box)
                    ctx.draw(ImageOps.pdfEmbeddable(image), in: box)
                    ctx.endPage()
                } else {
                    throw JobError.unsupported("\(url.lastPathComponent) in a combined PDF")
                }
            }
            progress(i + 1, inputs.count)
        }
    }

    // MARK: Compress (embedded images only, verified)

    enum CompressVerdict: Equatable {
        case smaller
        case notSmaller
        case changed(String)
    }

    /// Settings for the generated Quartz filter (same format as macOS's own
    /// "Reduce File Size" filter in /System/Library/Filters).
    static func filterSettings(_ level: PDFCompression) -> (quality: Double, resolution: Int, maxSize: Int) {
        switch level {
        case .light: (0.8, 200, 3200)
        case .balanced: (0.65, 150, 2400)
        case .strong: (0.45, 110, 1600)
        }
    }

    static func makeFilter(_ level: PDFCompression) throws -> QuartzFilter {
        let s = filterSettings(level)
        let plist: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": s.quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": [
                    "ImageResolution": s.resolution,
                    "ImageScaleInterpolate": true,
                    "ImageSizeMax": s.maxSize,
                    "ImageSizeMin": 0,
                ],
            ]]],
            "FilterType": 1,
            "Name": "Circularity \(level.rawValue)",
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("circularity-\(level.rawValue)-\(UUID().uuidString).qfilter")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        guard let filter = QuartzFilter(url: url) else { throw JobError.toolFailed("the PDF compression filter") }
        return filter
    }

    static func compress(_ url: URL, level: PDFCompression, to output: URL,
                         progress: (Int, Int) -> Void) throws -> CompressVerdict {
        guard let doc = PDFDocument(url: url) else { throw JobError.unreadable(url.lastPathComponent) }
        if doc.isEncrypted { throw JobError.unsupported("a password-protected PDF") }
        let filter = try makeFilter(level)
        let option = PDFDocumentWriteOption(rawValue: "QuartzFilter")
        guard doc.write(to: output, withOptions: [option: filter]) else { throw JobError.encodeFailed("the compressed PDF") }
        try Task.checkCancellation()
        let before = ConversionEngine.size(of: url), after = ConversionEngine.size(of: output)
        guard after < before else { return .notSmaller }
        if let problem = try verify(original: url, candidate: output, progress: progress) { return .changed(problem) }
        return .smaller
    }

    /// Every page must have the same size, the same text and look the same at
    /// low resolution; otherwise the original is kept (PLAN.md §3.1).
    static func verify(original: URL, candidate: URL, progress: (Int, Int) -> Void) throws -> String? {
        guard let a = PDFDocument(url: original), let b = PDFDocument(url: candidate) else { return "the result could not be read" }
        guard a.pageCount == b.pageCount else { return "the page count changed" }
        let docA = try open(original), docB = try open(candidate)
        for i in 0..<a.pageCount {
            try Task.checkCancellation()
            if let problem = try autoreleasepool(invoking: { () throws -> String? in
                guard let pa = a.page(at: i), let pb = b.page(at: i) else { return "page \(i + 1) is missing" }
                let ra = pa.bounds(for: .cropBox), rb = pb.bounds(for: .cropBox)
                if abs(ra.width - rb.width) > 0.5 || abs(ra.height - rb.height) > 0.5 { return "page \(i + 1) changed size" }
                let ta = (pa.string ?? "").filter { !$0.isWhitespace }, tb = (pb.string ?? "").filter { !$0.isWhitespace }
                if ta != tb { return "the text on page \(i + 1) changed" }
                guard let ga = docA.page(at: i + 1), let gb = docB.page(at: i + 1) else { return "page \(i + 1) is missing" }
                let diff = try meanDifference(ga, gb)
                if diff > 0.06 { return "page \(i + 1) looks different" }
                return nil
            }) { return problem }
            progress(i + 1, a.pageCount)
        }
        return nil
    }

    /// Mean absolute grey-level difference (0…1) of two pages rendered 64 px wide.
    static func meanDifference(_ a: CGPDFPage, _ b: CGPDFPage) throws -> Double {
        func grey(_ page: CGPDFPage) throws -> [UInt8] {
            let size = displaySize(page)
            let w = 64, h = max(1, Int(64 * size.height / max(size.width, 1)))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { throw JobError.encodeFailed("a comparison image") }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            draw(page, in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return [] }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h))
        }
        let ga = try grey(a), gb = try grey(b)
        guard ga.count == gb.count, !ga.isEmpty else { return 1 }
        let total = zip(ga, gb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(ga.count) / 255
    }

    // MARK: Resize and crop

    static func resize(_ url: URL, _ spec: PDFResize, to output: URL) throws {
        let doc = try open(url)
        guard let ctx = CGContext(output as CFURL, mediaBox: nil, nil) else { throw JobError.encodeFailed("PDF") }
        defer { ctx.closePDF() }
        for i in 1...doc.numberOfPages {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let size = displaySize(page)
            var box: CGRect, content: CGRect
            switch spec {
            case let .scale(s):
                box = CGRect(x: 0, y: 0, width: size.width * s, height: size.height * s)
                content = box
            case let .paper(paper):
                var p = paper.size
                if size.width > size.height { p = CGSize(width: p.height, height: p.width) } // keep orientation
                box = CGRect(origin: .zero, size: p)
                let k = min(p.width / size.width, p.height / size.height)
                let w = size.width * k, h = size.height * k
                content = CGRect(x: (p.width - w) / 2, y: (p.height - h) / 2, width: w, height: h)
            }
            ctx.beginPage(mediaBox: &box)
            draw(page, in: ctx, rect: content)
            ctx.endPage()
        }
    }

    static func crop(_ url: URL, rect: CGRect, to output: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw JobError.unreadable(url.lastPathComponent) }
        let r = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isEmpty else { throw JobError.encodeFailed("an empty crop") }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            // The rect was drawn on the upright page; map it onto the page as stored.
            let u = PDFCropMath.unrotated(r, rotation: page.rotation)
            // Normalised rect has a top-left origin; PDF space is y-up.
            let cropped = CGRect(x: box.minX + u.minX * box.width, y: box.maxY - u.maxY * box.height,
                                 width: u.width * box.width, height: u.height * box.height)
            page.setBounds(cropped, for: .cropBox)
        }
        guard doc.write(to: output) else { throw JobError.encodeFailed("the cropped PDF") }
    }
}

/// Crop rects are chosen on the upright (displayed) page; pages with /Rotate
/// store their content turned. Normalised, top-left origin (pure, tested).
public enum PDFCropMath {
    /// `rotation`: the page's clockwise display rotation in degrees.
    public static func unrotated(_ r: CGRect, rotation: Int) -> CGRect {
        func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            switch ((rotation % 360) + 360) % 360 {
            case 90: CGPoint(x: v, y: 1 - u)
            case 180: CGPoint(x: 1 - u, y: 1 - v)
            case 270: CGPoint(x: 1 - v, y: u)
            default: CGPoint(x: u, y: v)
            }
        }
        let a = map(r.minX, r.minY), b = map(r.maxX, r.maxY)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
