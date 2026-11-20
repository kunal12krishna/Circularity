import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Documents → PDF/HTML/TXT/DOCX (PLAN.md §3.1). Markdown is rendered to HTML
/// here; office formats go through /usr/bin/textutil; HTML is paginated by an
/// offscreen WebKit view that is never shown and cannot reach the network.
enum DocumentBackend {
    enum Flavor: Equatable {
        case markdown, html, plainText
        case office(String) // textutil format of the source: rtf, rtfd, doc, docx, odt, wordml, webarchive
        case spreadsheet(OfficeBackend.Source) // Excel, Numbers-free: XLSX / XLS / ODS / CSV → PDF
        case presentation(OfficeBackend.Source) // PowerPoint: PPTX / PPT / ODP → PDF
    }

    static func flavor(of type: UTType) -> Flavor? {
        if let md = UTType("net.daringfireball.markdown"), type.conforms(to: md) { return .markdown }
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .rtfd) { return .office("rtfd") }
        if type.conforms(to: .rtf) { return .office("rtf") }
        if let t = UTType("org.openxmlformats.wordprocessingml.document"), type.conforms(to: t) { return .office("docx") }
        if let t = UTType("com.microsoft.word.doc"), type.conforms(to: t) { return .office("doc") }
        if let t = UTType("org.oasis-open.opendocument.text"), type.conforms(to: t) { return .office("odt") }
        if let source = OfficeBackend.spreadsheetSource(of: type) { return .spreadsheet(source) }
        if let source = OfficeBackend.presentationSource(of: type) { return .presentation(source) }
        if type.conforms(to: .plainText) { return .plainText }
        return nil
    }

    static func convert(_ input: URL, flavor: Flavor, to format: OutputFormat, output: URL, workDir: URL) async throws {
        let title = input.deletingPathExtension().lastPathComponent
        switch (flavor, format) {
        case (.markdown, .html):
            try write(Markdown.document(try read(input), title: title), to: output)
        case (.markdown, .pdf):
            try await HTMLPrinter.printPDF(html: Markdown.document(try read(input), title: title), baseDirectory: input.deletingLastPathComponent(),
                                           workDir: workDir, to: output)
        case (.markdown, _):
            let html = workDir.appendingPathComponent("\(UUID().uuidString).html")
            try write(Markdown.document(try read(input), title: title), to: html)
            try await TextUtil.convert(html, to: format, output: output)
        case (.html, .pdf):
            try await HTMLPrinter.printPDF(html: try read(input), baseDirectory: input.deletingLastPathComponent(),
                                           workDir: workDir, to: output)
        case (.plainText, .pdf):
            let body = "<pre style=\"white-space: pre-wrap; background: none; padding: 0; font-size: 10pt\">\(Markdown.escape(try read(input)))</pre>"
            try await HTMLPrinter.printPDF(html: Markdown.wrap(body: body, title: title), baseDirectory: input.deletingLastPathComponent(),
                                           workDir: workDir, to: output)
        case (.office, .pdf):
            let html = workDir.appendingPathComponent("\(UUID().uuidString).html")
            try await TextUtil.convert(input, to: .html, output: html)
            try await HTMLPrinter.printPDF(html: try read(html), baseDirectory: workDir, workDir: workDir, to: output)
        case let (.spreadsheet(source), .pdf):
            try await OfficeBackend.spreadsheetPDF(input, source: source, workDir: workDir, output: output)
        case let (.presentation(source), .pdf):
            try await OfficeBackend.presentationPDF(input, source: source, workDir: workDir, output: output)
        case (.spreadsheet, _), (.presentation, _):
            throw JobError.unsupported("\(input.lastPathComponent) to \(format.displayName)")
        case (_, .html), (_, .txt), (_, .docx):
            try await TextUtil.convert(input, to: format, output: output)
        default:
            throw JobError.unsupported("\(input.lastPathComponent) to \(format.displayName)")
        }
    }

    static func read(_ url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var encoding = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &encoding) { return s }
        throw JobError.unreadable(url.lastPathComponent)
    }

    static func write(_ s: String, to url: URL) throws {
        do { try s.write(to: url, atomically: false, encoding: .utf8) } catch { throw JobError.writeFailed(error.localizedDescription) }
    }
}

/// Receives NSPrintOperation's completion callback, which AppKit delivers on
/// its own background thread.
private final class PrintCompletion: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var finish: (@Sendable (Bool) -> Void)?
    private var keepAlive: PrintCompletion?

    init(_ finish: @escaping @Sendable (Bool) -> Void) {
        self.finish = finish
        super.init()
        keepAlive = self // retained until the operation reports back
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        lock.lock()
        let f = finish
        finish = nil
        keepAlive = nil
        lock.unlock()
        f?(success)
    }
}

private extension String {
    var wrappedInBrackets: String { "[\(self)]" }
}

/// /usr/bin/textutil as a short-lived child process.
enum TextUtil {
    static func convert(_ input: URL, to format: OutputFormat, output: URL) async throws {
        let target: String = switch format {
        case .txt: "txt"
        case .html: "html"
        case .docx: "docx"
        default: throw JobError.unsupported("textutil output \(format.displayName)")
        }
        try await Tool.run("/usr/bin/textutil", ["-convert", target, "-output", output.path, input.path])
    }
}

/// A macOS command-line tool as a short-lived child process: cancellable,
/// and stopped after `timeout` so a stuck tool can't hold a queue slot.
enum Tool {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 120) async throws {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let control = ProcessControl(process)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { p in
                    if p.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let message = String(data: errors.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                        continuation.resume(throwing: JobError.toolFailed(message.isEmpty ? "\(name) exited \(p.terminationStatus)" : message))
                    }
                }
                switch control.launch() {
                case .launched:
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { control.cancel() }
                case .cancelled: continuation.resume(throwing: CancellationError())
                case let .failed(error): continuation.resume(throwing: JobError.toolFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            control.cancel()
        }
        try Task.checkCancellation()
    }
}

/// Launch and cancel of a Process from different threads, without ever
/// terminating one that hasn't started (NSTask raises for that).
nonisolated final class ProcessControl: @unchecked Sendable {
    enum Launch { case launched, cancelled, failed(Error) }
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    init(_ process: Process) { self.process = process }

    func launch() -> Launch {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return .cancelled }
        do {
            try process.run()
            running = true
            return .launched
        } catch {
            return .failed(error)
        }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if running, process.isRunning { process.terminate() }
    }
}

/// Paginates HTML into a PDF with an offscreen WKWebView (in a window that is
/// never ordered on screen). A content rule list blocks every network load.
@MainActor
final class HTMLPrinter: NSObject, WKNavigationDelegate {
    private static var blockList: WKContentRuleList?
    private var loaded: CheckedContinuation<Void, Error>?

    static func printPDF(html: String, baseDirectory: URL, workDir: URL, paper: PaperSize = .regional, to output: URL) async throws {
        try await printPDF(html: html, baseDirectory: baseDirectory, workDir: workDir, page: paper.size, margin: 54, to: output)
    }

    /// Any page size (landscape paper, a slide) and margin, in points.
    static func printPDF(html: String, baseDirectory: URL, workDir: URL, page: CGSize, margin: CGFloat, to output: URL) async throws {
        let printer = HTMLPrinter()
        try await printer.run(html: html, baseDirectory: baseDirectory, workDir: workDir, pageSize: page, margin: margin, output: output)
    }

    private static func networkBlocker() async throws -> WKContentRuleList {
        if let blockList { return blockList }
        // One rule per scheme: WebKit's url-filter has no alternation.
        let rules = ["^https?://", "^wss?://", "^ftp://"]
            .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
            .joined(separator: ",")
            .wrappedInBrackets
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "circularity-no-network",
                                                                   encodedContentRuleList: rules) { list, error in
                if let list { continuation.resume(returning: list) } else {
                    continuation.resume(throwing: JobError.toolFailed(error?.localizedDescription ?? "content blocker"))
                }
            }
        }
        blockList = list
        return list
    }

    private static let debug = ProcessInfo.processInfo.environment["CIRCULARITY_DEBUG"] != nil
    private static func trace(_ s: String) { if debug { FileHandle.standardError.write(Data("[HTMLPrinter] \(s)\n".utf8)) } }

    /// One PDF page per `div.slide`, each exactly `slide` in size: the page is
    /// laid out once, then each slide is shown alone and captured (screen
    /// layout, so print's shrink-to-fit never rescales it, and each page holds
    /// only its own slide's text).
    static func slidesPDF(html: String, baseDirectory: URL, workDir: URL, slide: CGSize) async throws -> [Data] {
        let printer = HTMLPrinter()
        return try await printer.withLoadedPage(html: html, baseDirectory: baseDirectory, workDir: workDir, width: slide.width) { webView, _ in
            let count = try await webView.evaluateJavaScript("document.querySelectorAll('div.slide').length") as? Int ?? 0
            let config = WKPDFConfiguration()
            config.rect = CGRect(origin: .zero, size: slide)
            var pages: [Data] = []
            for k in 0..<count {
                try Task.checkCancellation()
                // Show only slide k; then give its pictures time to load and
                // decode (large photos decode in the background and would come
                // out blank). The window is never on screen, so page timers and
                // animation frames can't be relied on: the waiting is done here.
                _ = try await webView.evaluateJavaScript("""
                    (function(k){ var s = document.querySelectorAll('div.slide');
                      for (var i = 0; i < s.length; i++) s[i].style.display = i === k ? '' : 'none';
                      window.scrollTo(0, 0); return document.body.offsetHeight; })(\(k))
                    """)
                for _ in 0..<50 {
                    let ready = try await webView.evaluateJavaScript("""
                        Array.from(document.querySelectorAll('div.slide')[\(k)].querySelectorAll('img')).every(function(p){ return p.complete; })
                        """) as? Bool ?? true
                    if ready { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try await Task.sleep(nanoseconds: 120_000_000)
                pages.append(try await webView.pdf(configuration: config))
            }
            return pages
        }
    }

    private func run(html: String, baseDirectory: URL, workDir: URL, pageSize: CGSize, margin: CGFloat, output: URL) async throws {
        try await withLoadedPage(html: html, baseDirectory: baseDirectory, workDir: workDir, width: pageSize.width - margin * 2) { webView, window in
            try await self.print(webView, in: window, pageSize: pageSize, margin: margin, output: output)
        }
    }

    private func withLoadedPage<T>(html: String, baseDirectory: URL, workDir: URL, width: CGFloat,
                                   _ body: (WKWebView, NSWindow) async throws -> T) async throws -> T {
        Self.trace("start")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(try await Self.networkBlocker())
        Self.trace("blocker ready")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 800), configuration: config)
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.contentView = nil; window.close() }

        // A <base> keeps relative image paths working next to the original.
        let base = "<base href=\"\(baseDirectory.absoluteString)\">"
        let page = html.range(of: "<head>").map { html.replacingCharacters(in: $0, with: "<head>\(base)") } ?? base + html
        let file = workDir.appendingPathComponent("\(UUID().uuidString).html")
        try DocumentBackend.write(page, to: file)
        // Resumed by the navigation callbacks, by Cancel, or after 60 s, so a
        // load that never finishes can't hold a queue slot forever.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loaded = continuation
                if Task.isCancelled { finish(CancellationError()); return }
                webView.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    MainActor.assumeIsolated { self?.finish(JobError.toolFailed("the page took too long to load")) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(CancellationError()) }
        }
        try Task.checkCancellation()
        Self.trace("loaded")
        return try await body(webView, window)
    }

    private func print(_ webView: WKWebView, in window: NSWindow, pageSize: CGSize, margin: CGFloat, output: URL) async throws {
        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: output,
        ])
        info.paperSize = pageSize
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        Self.trace("printing")
        // run() would block the main thread that WebKit needs to answer on;
        // the window-modal form runs asynchronously (no panels are shown).
        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let done = PrintCompletion { continuation.resume(returning: $0) }
            operation.runModal(for: window, delegate: done,
                               didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        Self.trace("printed: \(succeeded)")
        guard succeeded, FileManager.default.fileExists(atPath: output.path) else {
            throw JobError.toolFailed("printing to PDF failed")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(JobError.toolFailed(message)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(JobError.toolFailed(message)) }
    }

    private func finish(_ error: Error?) {
        guard let loaded else { return }
        self.loaded = nil
        if let error { loaded.resume(throwing: error) } else { loaded.resume() }
    }
}
