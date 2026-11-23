import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

/// Text from pictures and scans with Apple's on-device text recognition
/// (Vision): nothing is uploaded and no permission is asked.
enum TextRecognition {
    struct Line {
        var text: String
        /// Normalised (0…1), origin bottom-left, like PDF space.
        var box: CGRect
    }

    /// The Mac's own languages (System Settings → Language & Region) that
    /// Vision can read, then English. Not automatic detection: that loads an
    /// extra model the first time, which took over a minute on a cold Mac.
    static let languages: [String] = {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
        var picked: [String] = []
        for preferred in Locale.preferredLanguages + ["en-US"] {
            let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if let match = supported.first(where: { $0 == preferred }) ?? supported.first(where: { $0.hasPrefix(base) }),
               !picked.contains(match) {
                picked.append(match)
            }
        }
        return picked.isEmpty ? ["en-US"] : picked
    }()

    /// The accurate reader needs a model macOS prepares once per app (about a
    /// minute, cached in Library/Caches), and while it prepares even the fast
    /// reader has to wait. So scans use the accurate reader only once it is
    /// known to be ready; until then the fast one, which is instant and reads
    /// clear text just as well. `TextReader.prepare()` gets it ready in the background.
    static func lines(in image: CGImage) throws -> [Line] {
        try recognise(image, level: TextReader.isReady ? .accurate : .fast, giveUpAfter: nil) ?? []
    }

    /// nil: still running after `giveUpAfter` seconds (it carries on, and calls `onLateFinish` when done).
    private static func recognise(_ image: CGImage, level: VNRequestTextRecognitionLevel, giveUpAfter: TimeInterval?,
                                  onLateFinish: (@Sendable () -> Void)? = nil) throws -> [Line]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try Task.checkCancellation()
        // Vision runs on its own queue; this job watches for Cancel and stops it at once.
        let box = RequestBox(request)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let finished = DispatchSemaphore(value: 0)
        let handlerBox = HandlerBox(handler)
        let late = LateBox(onLateFinish)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try handlerBox.handler.perform([box.request]) } catch { box.error = error }
            finished.signal()
            if late.isLate { late.call() }
        }
        let started = Date()
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            if Task.isCancelled { box.request.cancel() }
            if let giveUpAfter, Date().timeIntervalSince(started) > giveUpAfter, !Task.isCancelled {
                late.markLate()
                return nil
            }
        }
        try Task.checkCancellation()
        if let error = box.error { throw JobError.toolFailed("text recognition: \(error.localizedDescription)") }
        let request_ = request
        return (request_.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            return Line(text: best.string, box: observation.boundingBox)
        }
    }


    /// A page with real text already has it; recognise only scans.
    static func hasText(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
    }

    /// About 300 dpi, at most 4000 px on the long side: sharp enough for small print.
    static func render(_ page: CGPDFPage) throws -> CGImage {
        let size = PDFBackend.displaySize(page)
        return try PDFBackend.render(page, scale: min(300.0 / 72, 4000 / max(size.width, size.height)))
    }

    // MARK: Text out

    /// Pictures: the words. PDFs: each page's own text, or its recognised text if it's a scan.
    static func text(from url: URL, isPDF: Bool, progress: (Int, Int) -> Void) throws -> String {
        if isPDF {
            guard let doc = PDFDocument(url: url) else { throw JobError.unreadable(url.lastPathComponent) }
            if doc.isLocked { throw JobError.message("\(url.lastPathComponent) has a password. Unlock it first (Tools → Unlock).") }
            let cg = try PDFBackend.open(url)
            var pages: [String] = []
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                try autoreleasepool {
                    if let page = doc.page(at: i), hasText(page) {
                        pages.append(page.string ?? "")
                    } else if let page = cg.page(at: i + 1) {
                        pages.append(try lines(in: render(page)).map(\.text).joined(separator: "\n"))
                    }
                }
                progress(i + 1, doc.pageCount)
            }
            return pages.joined(separator: "\n\n\u{0C}")
        }
        let image = try ImageInput.open(url).upright(maxPixel: 4000)
        let text = try lines(in: image).map(\.text).joined(separator: "\n")
        progress(1, 1)
        return text
    }

    // MARK: Searchable PDF

    /// Every page as it looks, plus an invisible layer of the recognised words
    /// in the right places, so Preview and Spotlight can find, select and copy
    /// them. Pages that already have text are kept as they are.
    static func searchablePDF(from url: URL, isPDF: Bool, to output: URL, progress: (Int, Int) -> Void) throws -> Int {
        guard let ctx = CGContext(output as CFURL, mediaBox: nil, nil) else { throw JobError.encodeFailed("PDF") }
        defer { ctx.closePDF() }
        var recognised = 0
        if isPDF {
            guard let doc = PDFDocument(url: url) else { throw JobError.unreadable(url.lastPathComponent) }
            if doc.isLocked { throw JobError.message("\(url.lastPathComponent) has a password. Unlock it first (Tools → Unlock).") }
            let cg = try PDFBackend.open(url)
            for i in 1...cg.numberOfPages {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let page = cg.page(at: i) else { return }
                    var box = CGRect(origin: .zero, size: PDFBackend.displaySize(page))
                    ctx.beginPage(mediaBox: &box)
                    PDFBackend.draw(page, in: ctx, rect: box)
                    if let kit = doc.page(at: i - 1), !hasText(kit) {
                        let found = try lines(in: render(page))
                        recognised += found.count
                        drawInvisible(found, in: box, ctx: ctx)
                    }
                    ctx.endPage()
                }
                progress(i, cg.numberOfPages)
            }
        } else {
            let input = try ImageInput.open(url)
            let image = try input.upright()
            let k = 72 / max(input.dpi, 1)
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(ImageOps.pdfEmbeddable(image), in: box)
            let found = try lines(in: image)
            recognised = found.count
            drawInvisible(found, in: box, ctx: ctx)
            ctx.endPage()
            progress(1, 1)
        }
        return recognised
    }

    /// Text drawn in invisible mode, each line stretched to its box.
    static func drawInvisible(_ lines: [Line], in page: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let rect = CGRect(x: page.minX + line.box.minX * page.width, y: page.minY + line.box.minY * page.height,
                              width: line.box.width * page.width, height: line.box.height * page.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard natural > 0 else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.18)
            ctx.scaleBy(x: rect.width / CGFloat(natural), y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}

/// Lets the cancellation handler reach the request (Vision requests aren't Sendable).
/// Gets the accurate text reader ready once, in the background.
public enum TextReader {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var preparing = false
    /// Remembered per macOS version: the prepared model belongs to the system's Vision.
    private static var readyKey: String { "textRecognition.accurateReady.\(ProcessInfo.processInfo.operatingSystemVersionString)" }

    /// Where macOS keeps this app's prepared models; if it was cleared, the reader isn't ready any more.
    private static var cacheExists: Bool {
        guard let id = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return true }
        let folder = caches.appendingPathComponent(id).appendingPathComponent("com.apple.e5rt.e5bundlecache")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty == false
    }

    public static var isReady: Bool { UserDefaults.standard.bool(forKey: readyKey) && cacheExists }

    /// Once per macOS version (or after the cache was cleared): a tiny scan with
    /// the accurate reader at background priority. Does nothing if it's ready.
    public static func prepare() {
        lock.lock()
        guard !preparing, !isReady else { lock.unlock(); return }
        preparing = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx?.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            if let image = ctx?.makeImage() {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                if (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil {
                    UserDefaults.standard.set(true, forKey: readyKey)
                }
            }
            lock.lock(); preparing = false; lock.unlock()
            NSLog("Circularity: text recognition ready (%.1f s)", Date().timeIntervalSince(started))
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    let request: VNRequest
    var error: Error?
    init(_ request: VNRequest) { self.request = request }
}

/// A finish callback that only fires if the caller stopped waiting.
private final class LateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var late = false
    private let callback: (@Sendable () -> Void)?
    init(_ callback: (@Sendable () -> Void)?) { self.callback = callback }
    func markLate() { lock.lock(); late = true; lock.unlock() }
    var isLate: Bool { lock.lock(); defer { lock.unlock() }; return late }
    func call() { callback?() }
}

private final class HandlerBox: @unchecked Sendable {
    let handler: VNImageRequestHandler
    init(_ handler: VNImageRequestHandler) { self.handler = handler }
}

/// Password, page order and rotation (PDFKit: links and annotations are kept).
public enum PDFTools {
    static func protect(_ url: URL, password: String, to output: URL) throws {
        guard !password.isEmpty else { throw JobError.message("Type a password first.") }
        guard let doc = PDFDocument(url: url) else { throw JobError.unreadable(url.lastPathComponent) }
        guard !doc.isEncrypted else { throw JobError.message("\(url.lastPathComponent) already has a password.") }
        let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
        guard doc.write(to: output, withOptions: options) else { throw JobError.encodeFailed("the locked PDF") }
        // It must really be locked, and the password must really open it.
        guard let check = PDFDocument(url: output), check.isLocked, check.unlock(withPassword: password),
              check.pageCount == doc.pageCount else {
            throw JobError.verificationFailed("the password didn't take")
        }
    }

    static func unlock(_ url: URL, password: String, to output: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw JobError.unreadable(url.lastPathComponent) }
        guard doc.isEncrypted else { throw JobError.message("\(url.lastPathComponent) has no password to remove.") }
        guard doc.unlock(withPassword: password) else { throw JobError.message("That password doesn't open \(url.lastPathComponent).") }
        // A fresh document of the unlocked pages: written without any encryption.
        let open = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            open.insert(page, at: open.pageCount)
        }
        if let attributes = doc.documentAttributes { open.documentAttributes = attributes }
        guard open.write(to: output) else { throw JobError.encodeFailed("the unlocked PDF") }
        guard let check = PDFDocument(url: output), !check.isEncrypted, check.pageCount == doc.pageCount else {
            throw JobError.verificationFailed("it still asks for a password")
        }
    }

    static func arrange(_ url: URL, pages edits: [PageEdit], to output: URL) throws {
        guard !edits.isEmpty else { throw JobError.message("Keep at least one page.") }
        guard let doc = PDFDocument(url: url) else { throw JobError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw JobError.message("\(url.lastPathComponent) has a password. Unlock it first (Tools → Unlock).") }
        let result = PDFDocument()
        for edit in edits {
            guard edit.index >= 0, edit.index < doc.pageCount, let page = doc.page(at: edit.index)?.copy() as? PDFPage else {
                throw JobError.message("Page \(edit.index + 1) isn't in \(url.lastPathComponent).")
            }
            page.rotation = ((page.rotation + edit.rotation) % 360 + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        if let attributes = doc.documentAttributes { result.documentAttributes = attributes }
        guard result.write(to: output) else { throw JobError.encodeFailed("the edited PDF") }
    }

    /// Small page pictures for the page editor.
    public static func thumbnails(_ url: URL, maxPixel: CGFloat) -> [CGImage] {
        guard let doc = try? PDFBackend.open(url) else { return [] }
        return (1...doc.numberOfPages).compactMap { i in
            autoreleasepool {
                guard let page = doc.page(at: i) else { return nil }
                let size = PDFBackend.displaySize(page)
                return try? PDFBackend.render(page, scale: maxPixel / max(size.width, size.height))
            }
        }
    }
}

extension PDFTools {
    /// For the app: whether the PDF asks for a password.
    public static func isEncrypted(_ url: URL) -> Bool { PDFDocument(url: url)?.isEncrypted ?? false }
}
