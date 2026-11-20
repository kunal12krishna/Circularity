import Foundation

/// OpenDocument spreadsheets (ODS) and presentations (ODP), which Quick Look
/// can't show: unzipped with `ditto`, their XML read here and turned into
/// HTML for HTMLPrinter. Sheets keep every cell's shown text; slides keep the
/// position, size and fill of each box, its text (size, colour, weight,
/// alignment, bullets) and its pictures.
enum OpenDocument {
    /// The file's zip contents in a new folder; `requiring` must be inside it.
    static func unzip(_ input: URL, workDir: URL, requiring: String = "content.xml") async throws -> URL {
        let dir = workDir.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try await Tool.run("/usr/bin/ditto", ["-x", "-k", input.path, dir.path], timeout: 60) } catch is CancellationError { throw CancellationError() }
        catch { throw JobError.unsupported("\(input.lastPathComponent): it isn't a valid file (it may be damaged)") }
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(requiring).path) else {
            throw JobError.unreadable(input.lastPathComponent)
        }
        return dir
    }

    static func sheets(_ input: URL, workDir: URL) async throws -> [OfficeBackend.Sheet] {
        let dir = try await unzip(input, workDir: workDir)
        let reader = SheetReader()
        try reader.parse(dir.appendingPathComponent("content.xml"))
        return reader.tables.map { OfficeBackend.Sheet(name: $0.name, html: Table.page($0.rows, header: false), base: dir) }
    }

    static func slides(_ input: URL, workDir: URL) async throws -> (html: String, base: URL) {
        let dir = try await unzip(input, workDir: workDir)
        let styles = StyleReader()
        let stylesFile = dir.appendingPathComponent("styles.xml")
        if FileManager.default.fileExists(atPath: stylesFile.path) { try styles.parse(stylesFile) }
        try styles.parse(dir.appendingPathComponent("content.xml"))
        let reader = SlideReader(styles: styles)
        try reader.parse(dir.appendingPathComponent("content.xml"))
        let size = styles.slideSize
        let body = reader.slides.joined()
        // No doctype, like Quick Look's slides: WebKit then prints the slide at the page's own size.
        let html = """
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=\(Int(size.width) + 16), maximum-scale=4.0"><style type="text/css">div.slide, div.loading-slide { width: \(fmt(size.width)); height: \(fmt(size.height));}
        div.slide { position: relative; overflow: hidden; }
        div.box { position: absolute; box-sizing: border-box; overflow: visible; }
        div.box p { margin: 0; font-family: -apple-system, "Helvetica Neue", Arial, sans-serif; white-space: pre-wrap; }
        div.box img { width: 100%; height: 100%; object-fit: fill; display: block; }
        </style></head><body>\(body)</body></html>
        """
        return (html, dir)
    }

    // MARK: Units

    /// An ODF length ("2.5cm", "1in", "12pt", "30mm", "96px") in points.
    static func points(_ value: String?) -> CGFloat? {
        guard let value, let number = Double(value.trimmingCharacters(in: CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "%")))) else { return nil }
        let n = CGFloat(number)
        if value.hasSuffix("cm") { return n * 72 / 2.54 }
        if value.hasSuffix("mm") { return n * 72 / 25.4 }
        if value.hasSuffix("in") { return n * 72 }
        if value.hasSuffix("px") { return n * 0.75 }
        if value.hasSuffix("pc") { return n * 12 }
        return n // pt
    }

    static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    /// A colour attribute safe to put in CSS (#RRGGBB only).
    static func color(_ value: String?) -> String? {
        guard let value, value.count == 7, value.hasPrefix("#"), value.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return value
    }
}

// MARK: - Spreadsheets

/// office:spreadsheet → tables of shown text. Repeated rows and cells are
/// expanded (within limits) and the empty edges trimmed.
final class SheetReader: NSObject, XMLParserDelegate {
    struct Sheet { var name: String; var rows: [[String]] }
    private(set) var tables: [Sheet] = []
    private var current: Sheet?
    private var row: [String] = []
    private var rowRepeat = 1
    private var cell: String?
    private var cellRepeat = 1
    private var paragraphs = 0
    private var annotation = 0
    private var parseError: Error?
    private static let maxRows = 20_000, maxColumns = 1_024

    func parse(_ url: URL) throws {
        guard let parser = XMLParser(contentsOf: url) else { throw JobError.unreadable(url.lastPathComponent) }
        parser.delegate = self
        guard parser.parse() else { throw parseError ?? parser.parserError ?? JobError.unreadable(url.lastPathComponent) }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "table:table": current = Sheet(name: a["table:name"] ?? "Sheet", rows: [])
        case "table:table-row":
            row = []; rowRepeat = max(1, Int(a["table:number-rows-repeated"] ?? "") ?? 1)
        case "table:table-cell", "table:covered-table-cell":
            cell = ""; paragraphs = 0; cellRepeat = max(1, Int(a["table:number-columns-repeated"] ?? "") ?? 1)
        case "office:annotation": annotation += 1
        case "text:p", "text:h":
            guard cell != nil, annotation == 0 else { break }
            if paragraphs > 0 { cell? += "\n" }
            paragraphs += 1
        case "text:s" where cell != nil && annotation == 0: cell? += String(repeating: " ", count: max(1, Int(a["text:c"] ?? "") ?? 1))
        case "text:tab" where cell != nil && annotation == 0: cell? += "\t"
        case "text:line-break" where cell != nil && annotation == 0: cell? += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if cell != nil, annotation == 0 { cell? += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "office:annotation": annotation -= 1
        case "table:table-cell", "table:covered-table-cell":
            let text = cell ?? ""
            let room = Self.maxColumns - row.count
            row += Array(repeating: text, count: max(0, min(cellRepeat, room)))
            cell = nil
        case "table:table-row":
            guard current != nil else { break }
            while row.last?.isEmpty == true { row.removeLast() }
            let room = Self.maxRows - current!.rows.count
            current!.rows += Array(repeating: row, count: max(0, min(row.isEmpty ? min(rowRepeat, 200) : rowRepeat, room)))
        case "table:table":
            guard var sheet = current else { break }
            while sheet.rows.last?.isEmpty == true { sheet.rows.removeLast() }
            if !sheet.rows.isEmpty { tables.append(sheet) }
            current = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) { parseError = error }
}

// MARK: - Presentations

/// Named styles from styles.xml and content.xml: text, paragraph and fill
/// properties, and the slide size (the landscape page layout).
final class StyleReader: NSObject, XMLParserDelegate {
    struct Style {
        var parent: String?
        var fontSize: CGFloat?, color: String?, bold: Bool?, italic: Bool?, align: String?
        var fill: String?, stroke: String?
    }
    private(set) var styles: [String: Style] = [:]
    private var layouts: [CGSize] = []
    private var current: String?

    var slideSize: CGSize {
        let landscape = layouts.filter { $0.width >= $0.height }
        return landscape.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 792, height: 445.5)
    }

    func parse(_ url: URL) throws {
        guard let parser = XMLParser(contentsOf: url) else { throw JobError.unreadable(url.lastPathComponent) }
        parser.delegate = self
        _ = parser.parse() // a damaged styles file only loses formatting
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "style:style", "style:default-style":
            current = a["style:name"] ?? "default-\(a["style:family"] ?? "")"
            if let current { styles[current, default: Style()].parent = a["style:parent-style-name"] }
        case "style:page-layout-properties":
            if let w = OpenDocument.points(a["fo:page-width"]), let h = OpenDocument.points(a["fo:page-height"]), w > 10, h > 10 {
                layouts.append(CGSize(width: w, height: h))
            }
        case "style:text-properties":
            guard let current else { break }
            if let size = a["fo:font-size"], !size.hasSuffix("%") { styles[current]?.fontSize = OpenDocument.points(size) }
            if let c = OpenDocument.color(a["fo:color"]) { styles[current]?.color = c }
            if let w = a["fo:font-weight"] { styles[current]?.bold = w == "bold" || (Int(w) ?? 400) >= 600 }
            if let s = a["fo:font-style"] { styles[current]?.italic = s == "italic" || s == "oblique" }
        case "style:paragraph-properties":
            if let current, let align = a["fo:text-align"] { styles[current]?.align = align }
        case "style:graphic-properties", "style:drawing-page-properties":
            guard let current else { break }
            if a["draw:fill"] == "none" { styles[current]?.fill = "none" }
            else if let c = OpenDocument.color(a["draw:fill-color"]), a["draw:fill"] == nil || a["draw:fill"] == "solid" { styles[current]?.fill = c }
            if a["draw:stroke"] == "none" { styles[current]?.stroke = "none" }
            else if let c = OpenDocument.color(a["svg:stroke-color"]), a["draw:stroke"] == "solid" { styles[current]?.stroke = c }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "style:style" || name == "style:default-style" { current = nil }
    }

    /// A property from a style or the styles it inherits from.
    func resolve<T>(_ name: String?, _ key: KeyPath<Style, T?>) -> T? {
        var name = name, hops = 0
        while let n = name, let style = styles[n], hops < 12 {
            if let v = style[keyPath: key] { return v }
            name = style.parent; hops += 1
        }
        return nil
    }
}

/// office:presentation → `div.slide` pages with absolutely placed boxes.
final class SlideReader: NSObject, XMLParserDelegate {
    private let styles: StyleReader
    private(set) var slides: [String] = []
    private var slide: String?
    private var boxes: [(className: String?, html: String)] = [] // open boxes
    private var spans: [String?] = [] // text style stack
    private var paragraphStyle: String?
    private var listDepth = 0
    private var skip = 0 // notes, annotations

    init(styles: StyleReader) { self.styles = styles }

    func parse(_ url: URL) throws {
        guard let parser = XMLParser(contentsOf: url) else { throw JobError.unreadable(url.lastPathComponent) }
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? JobError.unreadable(url.lastPathComponent) }
    }

    private static let shapes: Set<String> = ["draw:frame", "draw:custom-shape", "draw:rect", "draw:ellipse", "draw:circle", "draw:text-box"]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if name == "presentation:notes" || name == "office:annotation" { skip += 1 }
        guard skip == 0 else { return }
        switch name {
        case "draw:page":
            let fill = styles.resolve(a["draw:style-name"], \.fill)
            let background = fill.flatMap { $0 == "none" ? nil : $0 } ?? "#FFFFFF"
            slide = "<div class=\"slide\" style=\"background:\(background);\">"
        case _ where Self.shapes.contains(name) && slide != nil:
            guard name != "draw:text-box" else { break } // the frame already placed it
            let x = OpenDocument.points(a["svg:x"]) ?? 0, y = OpenDocument.points(a["svg:y"]) ?? 0
            let w = OpenDocument.points(a["svg:width"]) ?? 0, h = OpenDocument.points(a["svg:height"]) ?? 0
            let style = a["draw:style-name"] ?? a["presentation:style-name"]
            var css = "left:\(OpenDocument.fmt(x))px; top:\(OpenDocument.fmt(y))px; width:\(OpenDocument.fmt(w))px; height:\(OpenDocument.fmt(h))px;"
            if name != "draw:frame" || a["presentation:class"] == nil {
                if let fill = styles.resolve(style, \.fill), fill != "none" { css += " background:\(fill);" }
                if let stroke = styles.resolve(style, \.stroke), stroke != "none", name != "draw:frame" { css += " border:1px solid \(stroke);" }
            }
            if name == "draw:ellipse" || name == "draw:circle" { css += " border-radius:50%;" }
            if name == "draw:custom-shape" || name == "draw:rect" || name == "draw:ellipse" {
                css += " display:flex; flex-direction:column; justify-content:center; padding:4px;"
            }
            boxes.append((a["presentation:class"], "<div class=\"box\" style=\"\(css)\">"))
        case "draw:image" where !boxes.isEmpty:
            if let href = a["xlink:href"], Self.isLocal(href) {
                boxes[boxes.count - 1].html += "<img src=\"\(Table.escape(href))\">"
            }
        case "text:p", "text:h":
            guard !boxes.isEmpty else { break }
            paragraphStyle = a["text:style-name"]
            spans = [paragraphStyle]
            let align = styles.resolve(paragraphStyle, \.align).map { $0 == "end" ? "right" : $0 == "start" ? "left" : $0 } ?? "left"
            var css = "text-align:\(Table.escape(align));" + textCSS(paragraphStyle, boxClass: boxes.last?.className)
            if listDepth > 0 { css += " padding-left:\(listDepth * 18)px; text-indent:-12px;" }
            boxes[boxes.count - 1].html += "<p style=\"\(css)\">" + (listDepth > 0 ? "• " : "")
        case "text:span" where !boxes.isEmpty:
            spans.append(a["text:style-name"])
            boxes[boxes.count - 1].html += "<span style=\"\(textCSS(a["text:style-name"], boxClass: nil))\">"
        case "text:s" where !boxes.isEmpty: boxes[boxes.count - 1].html += String(repeating: " ", count: max(1, Int(a["text:c"] ?? "") ?? 1))
        case "text:tab" where !boxes.isEmpty: boxes[boxes.count - 1].html += "\t"
        case "text:line-break" where !boxes.isEmpty: boxes[boxes.count - 1].html += "<br>"
        case "text:list": listDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skip == 0, !boxes.isEmpty, !spans.isEmpty else { return }
        boxes[boxes.count - 1].html += Table.escape(string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "presentation:notes" || name == "office:annotation" { skip -= 1; return }
        guard skip == 0 else { return }
        switch name {
        case "draw:page":
            if let s = slide { slides.append(s + "</div>") }
            slide = nil; boxes = []
        case "draw:text-box": break
        case _ where Self.shapes.contains(name):
            guard let box = boxes.popLast() else { break }
            let html = box.html + "</div>"
            if boxes.isEmpty { slide? += html } else { boxes[boxes.count - 1].html += html }
        case "text:p", "text:h":
            if !boxes.isEmpty, !spans.isEmpty { boxes[boxes.count - 1].html += "</p>" }
            spans = []
        case "text:span":
            if !boxes.isEmpty, spans.count > 1 { spans.removeLast(); boxes[boxes.count - 1].html += "</span>" }
        case "text:list": listDepth = max(0, listDepth - 1)
        default: break
        }
    }

    /// Font size, colour, weight and slant from a text style; titles default larger.
    private func textCSS(_ style: String?, boxClass: String?) -> String {
        var css = ""
        let fallback: CGFloat? = switch boxClass {
        case "title": 40
        case "subtitle": 28
        case "outline", "text": 22
        case .some: 18
        case nil: nil
        }
        if let size = styles.resolve(style, \.fontSize) ?? fallback { css += " font-size:\(OpenDocument.fmt(size))px;" }
        if let color = styles.resolve(style, \.color) { css += " color:\(color);" }
        if let bold = styles.resolve(style, \.bold) { css += bold ? " font-weight:700;" : " font-weight:400;" }
        if styles.resolve(style, \.italic) == true { css += " font-style:italic;" }
        return css
    }

    /// Pictures inside the file only ("Pictures/x.png"), never paths out of it or URLs.
    static func isLocal(_ href: String) -> Bool {
        !href.contains("..") && !href.contains(":") && !href.hasPrefix("/") && !href.isEmpty
    }
}
