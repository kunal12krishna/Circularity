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
    }

    static func flavor(of type: UTType) -> Flavor? {
        if let md = UTType("net.daringfireball.markdown"), type.conforms(to: md) { return .markdown }
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .rtfd) { return .office("rtfd") }
        if type.conforms(to: .rtf) { return .office("rtf") }
        if let t = UTType("org.openxmlformats.wordprocessingml.document"), type.conforms(to: t) { return .office("docx") }
        if let t = UTType("com.microsoft.word.doc"), type.conforms(to: t) { return .office("doc") }
        if let t = UTType("org.oasis-open.opendocument.text"), type.conforms(to: t) { return .office("odt") }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", target, "-output", output.path, input.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { p in
                    if p.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let message = String(data: errors.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                        continuation.resume(throwing: JobError.toolFailed(message.isEmpty ? "textutil exited \(p.terminationStatus)" : message))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: JobError.toolFailed(error.localizedDescription)) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
    }
}

/// Paginates HTML into a PDF with an offscreen WKWebView (in a window that is
/// never ordered on screen). A content rule list blocks every network load.
@MainActor
final class HTMLPrinter: NSObject, WKNavigationDelegate {
    private static var blockList: WKContentRuleList?
    private var loaded: CheckedContinuation<Void, Error>?

    static func printPDF(html: String, baseDirectory: URL, workDir: URL, paper: PaperSize = .regional, to output: URL) async throws {
        let printer = HTMLPrinter()
        try await printer.run(html: html, baseDirectory: baseDirectory, workDir: workDir, paper: paper, output: output)
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

    private func run(html: String, baseDirectory: URL, workDir: URL, paper: PaperSize, output: URL) async throws {
        Self.trace("start")
        let margin: CGFloat = 54
        let width = paper.size.width - margin * 2
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            webView.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
        try Task.checkCancellation()
        Self.trace("loaded")

        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: output,
        ])
        info.paperSize = paper.size
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
