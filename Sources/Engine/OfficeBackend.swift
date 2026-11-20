import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Spreadsheets and presentations → PDF, with nothing extra installed and no
/// permission asked (no Office, no Automation):
///
/// - **XLSX, XLS, PPTX, PPT** are laid out by macOS's own Office engine, the
///   one Quick Look previews them with (`/usr/bin/qlmanage -p -o`, which
///   writes the preview as HTML plus its pictures), then printed by WebKit.
/// - **ODS, ODP** (which Quick Look can't show) and **CSV** are read here: the
///   OpenDocument files are unzipped with `ditto` and their XML turned into
///   the same kind of HTML.
///
/// Sheets print on landscape pages, shrunk to the page width, each sheet
/// starting a new page under its name. Slides print one per page at the
/// slide's own size. Nothing is fetched from the network (HTMLPrinter blocks it).
public enum OfficeBackend {
    public enum Source: Equatable, Sendable {
        case quickLook // XLSX, XLS, PPTX, PPT
        case csv
        case openDocument // ODS, ODP
    }

    public static func spreadsheetSource(of type: UTType) -> Source? {
        if type.conforms(to: .commaSeparatedText) { return .csv }
        if conforms(type, "org.oasis-open.opendocument.spreadsheet") { return .openDocument }
        if conforms(type, "org.openxmlformats.spreadsheetml.sheet") || conforms(type, "com.microsoft.excel.xls") { return .quickLook }
        return nil
    }

    public static func presentationSource(of type: UTType) -> Source? {
        if conforms(type, "org.oasis-open.opendocument.presentation") { return .openDocument }
        if conforms(type, "org.openxmlformats.presentationml.presentation") || conforms(type, "com.microsoft.powerpoint.ppt") { return .quickLook }
        return nil
    }

    private static func conforms(_ type: UTType, _ identifier: String) -> Bool {
        UTType(identifier).map { type.conforms(to: $0) } ?? false
    }

    // MARK: Spreadsheets

    struct Sheet { var name: String?; var html: String; var base: URL }

    static func spreadsheetPDF(_ input: URL, source: Source, workDir: URL, output: URL) async throws {
        let sheets: [Sheet] = switch source {
        case .csv: [Sheet(name: nil, html: Table.page(CSV.rows(try DocumentBackend.read(input))), base: input.deletingLastPathComponent())]
        case .openDocument: try await OpenDocument.sheets(input, workDir: workDir)
        case .quickLook: try quickLookSheets(try await QuickLookExport.render(input, workDir: workDir))
        }
        guard !sheets.isEmpty else { throw JobError.unreadable(input.lastPathComponent) }
        // Landscape A4 / Letter: spreadsheets are wide.
        let paper = PaperSize.regional.size
        var parts: [URL] = []
        for (i, sheet) in sheets.enumerated() {
            try Task.checkCancellation()
            let part = workDir.appendingPathComponent("sheet-\(i)-\(UUID().uuidString).pdf")
            let html = printable(sheets.count > 1 ? Table.heading(sheet.name ?? "Sheet \(i + 1)", in: sheet.html) : sheet.html)
            try await HTMLPrinter.printPDF(html: html, baseDirectory: sheet.base, workDir: workDir,
                                           page: CGSize(width: paper.height, height: paper.width), margin: 36, to: part)
            parts.append(part)
        }
        try merge(parts, into: output)
    }

    /// Quick Look's workbook preview: sheet tabs, each linking to its own page; a single sheet is the preview itself.
    static func quickLookSheets(_ folder: URL) throws -> [Sheet] {
        let preview = try DocumentBackend.read(folder.appendingPathComponent("Preview.html"))
        let tabs = matches(#"<div class="TabHeader">(.*?)</div>\s*<a href="([^"]+)""#, in: preview)
        guard !tabs.isEmpty else { return [Sheet(name: nil, html: preview, base: folder)] }
        return try tabs.map { tab in
            let page = folder.appendingPathComponent(tab[1].removingPercentEncoding ?? tab[1])
            guard page.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { throw JobError.unreadable(tab[1]) }
            return Sheet(name: Table.unescape(tab[0]), html: try DocumentBackend.read(page), base: folder)
        }
    }

    // MARK: Presentations

    static func presentationPDF(_ input: URL, source: Source, workDir: URL, output: URL) async throws {
        let html: String, base: URL
        switch source {
        case .quickLook:
            base = try await QuickLookExport.render(input, workDir: workDir)
            html = dropLeakedImages(try DocumentBackend.read(base.appendingPathComponent("Preview.html")))
        case .openDocument:
            (html, base) = try await OpenDocument.slides(input, workDir: workDir)
        case .csv:
            throw JobError.unsupported("\(input.lastPathComponent) as slides")
        }
        guard html.contains("class=\"slide\"") else { throw JobError.unreadable(input.lastPathComponent) }
        let size = slideSize(html)
        // One slide per page: the page is the slide, with no margins, gaps or shadows.
        let css = """
        <style>@page { margin: 0 } html, body { margin: 0 !important; padding: 0 !important; background: none !important; }
        div.slide { margin: 0 !important; -webkit-box-shadow: none !important; box-shadow: none !important;
        width: \(Int(size.width))px !important; height: \(Int(size.height))px !important; }
        div.loading-slide { display: none !important; }</style>
        """
        let page = html.range(of: "</head>").map { html.replacingCharacters(in: $0, with: css + "</head>") } ?? css + html
        let slides = try await HTMLPrinter.slidesPDF(html: printable(page), baseDirectory: base, workDir: workDir, slide: size)
        guard !slides.isEmpty else { throw JobError.unreadable(input.lastPathComponent) }
        var parts: [URL] = []
        for (k, data) in slides.enumerated() {
            let part = workDir.appendingPathComponent("slide-\(k)-\(UUID().uuidString).pdf")
            do { try data.write(to: part) } catch { throw JobError.writeFailed(error.localizedDescription) }
            parts.append(part)
        }
        try merge(parts, into: output)
    }

    /// macOS's Office engine sometimes writes a slide's drawn shapes into later
    /// slides too (seen on macOS 27: slide 5 also showing slide 3's boxes,
    /// over its own text). It gives each drawn shape its own picture file,
    /// even identical shapes on different slides, so the very same picture at
    /// the very same spot as on an earlier slide is one of those leaks: it's left out.
    static func dropLeakedImages(_ html: String) -> String {
        let slides = html.components(separatedBy: "<div class=\"slide\"")
        guard slides.count > 2 else { return html }
        var seen = Set<String>(), out = slides[0]
        for slide in slides.dropFirst() {
            var mine = Set<String>(), kept = slide
            for m in matches(#"(<img src="[^"]+"[^>]*>)"#, in: slide) {
                if seen.contains(m[0]) { kept = kept.replacingOccurrences(of: m[0], with: "") } else { mine.insert(m[0]) }
            }
            seen.formUnion(mine)
            out += "<div class=\"slide\"" + kept
        }
        return out
    }

    /// The slide size Quick Look (and OpenDocument.slides) writes: `div.slide, div.loading-slide { width: 960; height: 540;}`.
    static func slideSize(_ html: String) -> CGSize {
        if let m = matches(#"div\.slide, div\.loading-slide \{ width: ?([0-9.]+)(?:px)?; height: ?([0-9.]+)"#, in: html).first,
           let w = Double(m[0]), let h = Double(m[1]), w > 50, h > 50 {
            return CGSize(width: w, height: h)
        }
        return CGSize(width: 960, height: 540)
    }

    // MARK: Helpers

    /// Prints colours exactly as shown (WebKit otherwise drops fills and
    /// darkens light text when printing), and stands in Mac fonts for Office
    /// fonts this Mac doesn't have, so text keeps its look instead of Times.
    static func printable(_ html: String) -> String {
        var css = "* { -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; }\n"
        for (office, mac) in fontStandIns where NSFont(name: office, size: 12) == nil {
            css += "@font-face { font-family: \"\(office)\"; src: \(mac.map { "local(\"\($0)\")" }.joined(separator: ", ")); }\n"
        }
        let style = "<style>\(css)</style>"
        if let head = html.range(of: "<head>", options: .caseInsensitive) { return html.replacingCharacters(in: head, with: "<head>" + style) }
        return style + html
    }

    /// Office's default fonts → the nearest ones every Mac has.
    static let fontStandIns: [(String, [String])] = [
        ("Calibri", ["Helvetica Neue", "Helvetica"]), ("Calibri Light", ["HelveticaNeue-Light", "Helvetica Neue"]),
        ("Aptos", ["Helvetica Neue", "Helvetica"]), ("Aptos Display", ["Helvetica Neue", "Helvetica"]),
        ("Segoe UI", ["Helvetica Neue", "Helvetica"]), ("Tahoma", ["Verdana", "Helvetica"]),
        ("Cambria", ["Georgia", "Times New Roman"]), ("Constantia", ["Georgia", "Times New Roman"]),
        ("Candara", ["Optima", "Helvetica Neue"]), ("Corbel", ["Avenir Next", "Helvetica Neue"]),
        ("Consolas", ["Menlo", "Courier New"]), ("Century Gothic", ["Futura", "Avenir Next"]),
    ]

    static func merge(_ parts: [URL], into output: URL) throws {
        if parts.count == 1 {
            try FileManager.default.moveItem(at: parts[0], to: output)
            return
        }
        guard let document = PDFDocument(url: parts[0]) else { throw JobError.toolFailed("printing to PDF failed") }
        for part in parts.dropFirst() {
            guard let more = PDFDocument(url: part) else { throw JobError.toolFailed("printing to PDF failed") }
            for i in 0..<more.pageCount { if let page = more.page(at: i) { document.insert(page, at: document.pageCount) } }
        }
        guard document.write(to: output) else { throw JobError.writeFailed(output.lastPathComponent) }
    }

    /// Capture groups of every match.
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
}

/// `qlmanage -p -o`: Quick Look's preview of a file, written as a folder with
/// Preview.html and its attachments. Runs headless; nothing is shown.
enum QuickLookExport {
    static func render(_ input: URL, workDir: URL) async throws -> URL {
        let out = workDir.appendingPathComponent("quicklook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A plain name: qlmanage names its folder after the file.
        let copy = out.appendingPathComponent("source." + input.pathExtension.lowercased())
        try FileManager.default.copyItem(at: input, to: copy)
        try await Tool.run("/usr/bin/qlmanage", ["-p", "-o", out.path, copy.path], timeout: 180)
        let folder = out.appendingPathComponent(copy.lastPathComponent + ".qlpreview", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("Preview.html").path) else {
            throw JobError.unsupported("\(input.lastPathComponent): macOS couldn't open it (is it password-protected?)")
        }
        return folder
    }
}

/// Rows of cells → a printable HTML table.
enum Table {
    /// `header`: the first row is a header row (CSV), drawn bold and shaded.
    static func page(_ rows: [[String]], header: Bool = true) -> String {
        let width = rows.map(\.count).max() ?? 0
        var body = "<table>"
        for (r, row) in rows.enumerated() {
            body += "<tr>"
            for c in 0..<width {
                let cell = c < row.count ? escape(row[c]).replacingOccurrences(of: "\n", with: "<br>") : ""
                body += r == 0 && header ? "<th>\(cell)</th>" : "<td>\(cell)</td>"
            }
            body += "</tr>"
        }
        body += "</table>"
        return wrap(body)
    }

    static func wrap(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font: 9pt -apple-system, "Helvetica Neue", Arial, sans-serif; color: #111; margin: 0; }
        table { border-collapse: collapse; margin-bottom: 18px; }
        th, td { border: 1px solid #CFCFCF; padding: 3px 6px; vertical-align: top; text-align: left; white-space: nowrap; }
        th { background: #F1F1F1; font-weight: 600; }
        tr { break-inside: avoid; }
        </style></head><body>\(body)</body></html>
        """
    }

    /// The sheet's name above it (several sheets in one PDF).
    static func heading(_ name: String, in html: String) -> String {
        let h = "<h2 style=\"font: 600 12pt -apple-system, 'Helvetica Neue', Arial, sans-serif; margin: 0 0 8px; color: #111;\">\(escape(name))</h2>"
        guard let body = html.range(of: #"<body[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else { return h + html }
        return html.replacingCharacters(in: body, with: html[body] + h)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// RFC 4180 CSV: quoted fields with commas, quotes ("") and line breaks.
/// Semicolon-separated files (common where the decimal mark is a comma) are detected.
enum CSV {
    static func rows(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let separator: Character = firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";"
            : (firstLine.contains("\t") && !firstLine.contains(",") ? "\t" : ",")
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, atStart = true
        let sep = separator.unicodeScalars.first!
        var chars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        func endField() { row.append(field); field = ""; atStart = true }
        func endRow() { endField(); rows.append(row); row = [] }
        while let ch = pending ?? chars.next() {
            pending = nil
            if quoted {
                if ch == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.unicodeScalars.append(ch) }
                continue
            }
            switch ch {
            case "\"" where atStart: quoted = true; atStart = false
            case sep: endField()
            case "\r": if let next = chars.next(), next != "\n" { pending = next }; endRow()
            case "\n": endRow()
            default: field.unicodeScalars.append(ch); atStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        // A BOM is not part of the first cell.
        if let first = rows.first?.first, first.hasPrefix("\u{FEFF}") { rows[0][0] = String(first.dropFirst()) }
        return rows
    }
}
