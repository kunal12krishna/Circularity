import Foundation

/// Excel workbooks (XLSX) read directly: each sheet's cells as shown text.
/// Quick Look lays a sheet out with its formatting but stops at 4,096 rows,
/// so longer sheets are printed from here instead, with every row. Shared
/// and inline strings, booleans, errors and formula results are read;
/// numbers in a date format become dates, percentages get their %.
enum XLSXReader {
    struct Sheet { var name: String; var rows: [[String]] }

    /// Quick Look's last row on a sheet (header row included).
    static let quickLookRowLimit = 4_096
    static let maxRows = 200_000, maxColumns = 1_024

    static func sheets(in dir: URL) throws -> [Sheet] {
        let xl = dir.appendingPathComponent("xl", isDirectory: true)
        let workbook = Attributes(); try workbook.parse(xl.appendingPathComponent("workbook.xml"), elements: ["sheet"])
        let rels = Attributes(); try? rels.parse(xl.appendingPathComponent("_rels/workbook.xml.rels"), elements: ["Relationship"])
        let targets = Dictionary(rels.found.compactMap { a in a["Id"].flatMap { id in a["Target"].map { (id, $0) } } }, uniquingKeysWith: { a, _ in a })
        let strings = SharedStrings(); try? strings.parse(xl.appendingPathComponent("sharedStrings.xml"))
        let styles = Styles(); try? styles.parse(xl.appendingPathComponent("styles.xml"))

        var out: [Sheet] = []
        for (i, sheet) in workbook.found.enumerated() {
            let id = sheet["r:id"] ?? sheet.first { $0.key.hasSuffix(":id") }?.value
            var target = id.flatMap { targets[$0] } ?? "worksheets/sheet\(i + 1).xml"
            if target.hasPrefix("/xl/") { target = String(target.dropFirst(4)) } else if target.hasPrefix("/") { target = String(target.dropFirst()) }
            guard !target.contains(".."), !target.contains(":") else { continue }
            let reader = SheetReader(strings: strings.items, styles: styles)
            try reader.parse(xl.appendingPathComponent(target))
            out.append(Sheet(name: sheet["name"] ?? "Sheet \(i + 1)", rows: reader.rows))
        }
        return out
    }

    // MARK: Parsers

    /// Every listed element's attributes, in order.
    final class Attributes: NSObject, XMLParserDelegate {
        private(set) var found: [[String: String]] = []
        private var elements: Set<String> = []
        func parse(_ url: URL, elements: Set<String>) throws {
            self.elements = elements
            guard let parser = XMLParser(contentsOf: url) else { throw JobError.unreadable(url.lastPathComponent) }
            parser.delegate = self
            guard parser.parse() else { throw parser.parserError ?? JobError.unreadable(url.lastPathComponent) }
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if elements.contains(name) || elements.contains(name.split(separator: ":").last.map(String.init) ?? name) { found.append(a) }
        }
    }

    /// sharedStrings.xml: one entry per <si>, its text runs joined (phonetic hints left out).
    final class SharedStrings: NSObject, XMLParserDelegate {
        private(set) var items: [String] = []
        private var current: String?, inText = false, phonetic = 0
        func parse(_ url: URL) throws {
            guard let parser = XMLParser(contentsOf: url) else { throw JobError.unreadable(url.lastPathComponent) }
            parser.delegate = self
            _ = parser.parse()
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "si": current = ""
            case "t": inText = true
            case "rPh": phonetic += 1
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText, phonetic == 0 { current? += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "si": items.append(current ?? ""); current = nil
            case "t": inText = false
            case "rPh": phonetic -= 1
            default: break
            }
        }
    }

    /// styles.xml: which cell styles show numbers as dates or percentages.
    final class Styles: NSObject, XMLParserDelegate {
        enum Kind { case number, date, dateTime, time, percent }
        private var formats: [Int: String] = [:]
        private var xfFormats: [Int] = []
        private var inCellXfs = false
        func parse(_ url: URL) throws {
            guard let parser = XMLParser(contentsOf: url) else { throw JobError.unreadable(url.lastPathComponent) }
            parser.delegate = self
            _ = parser.parse()
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "numFmt": if let id = Int(a["numFmtId"] ?? ""), let code = a["formatCode"] { formats[id] = code }
            case "cellXfs": inCellXfs = true
            case "xf" where inCellXfs: xfFormats.append(Int(a["numFmtId"] ?? "") ?? 0)
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "cellXfs" { inCellXfs = false }
        }
        func kind(style: Int?) -> Kind {
            guard let style, style < xfFormats.count else { return .number }
            let id = xfFormats[style]
            switch id {
            case 9, 10: return .percent
            case 14...17: return .date
            case 18...21, 45...47: return .time
            case 22: return .dateTime
            default: break
            }
            guard let code = formats[id]?.lowercased() else { return .number }
            // Drop quoted text, escapes and colour/condition brackets before looking for date letters.
            let bare = code.replacingOccurrences(of: #""[^"]*"|\\.|\[[^\]]*\]"#, with: "", options: .regularExpression)
            if bare.contains("%") { return .percent }
            let hasDate = bare.contains("y") || bare.contains("d") || (bare.contains("m") && !bare.contains("h") && !bare.contains("s"))
            let hasTime = bare.contains("h") || bare.contains("s")
            return hasDate ? (hasTime ? .dateTime : .date) : (hasTime ? .time : .number)
        }
    }

    /// One worksheet: rows of shown text, with gaps filled and empty edges trimmed.
    final class SheetReader: NSObject, XMLParserDelegate {
        private let strings: [String], styles: Styles
        private(set) var rows: [[String]] = []
        private var row: [String] = [], rowIndex = 0
        private var cellColumn = 0, cellType = "n", cellStyle: Int?
        private var text: String?, inValue = false, inInline = false

        init(strings: [String], styles: Styles) { self.strings = strings; self.styles = styles }

        func parse(_ url: URL) throws {
            guard let parser = XMLParser(contentsOf: url) else { throw JobError.unreadable(url.lastPathComponent) }
            parser.delegate = self
            guard parser.parse() else { throw parser.parserError ?? JobError.unreadable(url.lastPathComponent) }
            while rows.last?.allSatisfy(\.isEmpty) == true { rows.removeLast() }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "row":
                let r = Int(a["r"] ?? "") ?? (rowIndex + 1)
                // Rows the file skips are empty rows (within limits).
                while rows.count < min(r - 1, XLSXReader.maxRows) { rows.append([]) }
                rowIndex = r; row = []
            case "c":
                cellColumn = a["r"].map(XLSXReader.column) ?? row.count
                cellType = a["t"] ?? "n"; cellStyle = Int(a["s"] ?? ""); text = nil
            case "v": inValue = true; text = text ?? ""
            case "is": inInline = true; text = text ?? ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue || inInline { text? += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v": inValue = false
            case "is": inInline = false
            case "c":
                guard cellColumn < XLSXReader.maxColumns else { break }
                while row.count < cellColumn { row.append("") }
                let shown = show(text ?? "")
                if row.count == cellColumn { row.append(shown) } else { row[cellColumn] = shown }
            case "row":
                guard rows.count < XLSXReader.maxRows else { break }
                while row.last?.isEmpty == true { row.removeLast() }
                rows.append(row)
            default: break
            }
        }

        private func show(_ raw: String) -> String {
            switch cellType {
            case "s": return Int(raw).flatMap { $0 < strings.count ? strings[$0] : nil } ?? ""
            case "b": return raw == "1" ? "TRUE" : "FALSE"
            case "inlineStr", "str", "e": return raw
            default:
                guard let n = Double(raw) else { return raw }
                switch styles.kind(style: cellStyle) {
                case .number: return XLSXReader.number(n)
                case .percent: return XLSXReader.number(n * 100) + "%"
                case .date: return XLSXReader.date(n, format: "yyyy-MM-dd")
                case .dateTime: return XLSXReader.date(n, format: "yyyy-MM-dd HH:mm")
                case .time: return XLSXReader.date(n, format: "HH:mm:ss")
                }
            }
        }
    }

    // MARK: Values

    /// "BC12" → 54 (zero-based column).
    static func column(_ reference: String) -> Int {
        var n = 0
        for ch in reference.unicodeScalars {
            guard ch.properties.isAlphabetic, let v = ch.value.utf8Letter else { break }
            n = n * 26 + v
        }
        return max(0, n - 1)
    }

    /// Up to 10 significant digits, without float noise (0.1 + 0.2 shows as 0.3).
    static func number(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        var s = String(format: "%.10g", n)
        if s.contains("e") { return s }
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s
    }

    /// An Excel serial date (days since 1899-12-30) in UTC.
    static func date(_ serial: Double, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        let base = Date(timeIntervalSince1970: -2_209_161_600) // 1899-12-30 00:00 UTC
        return formatter.string(from: base.addingTimeInterval((serial * 86_400).rounded()))
    }
}

private extension UInt32 {
    /// A–Z / a–z → 1…26.
    var utf8Letter: Int? {
        switch self {
        case 65...90: Int(self) - 64
        case 97...122: Int(self) - 96
        default: nil
        }
    }
}
