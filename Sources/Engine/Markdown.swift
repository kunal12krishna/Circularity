import Foundation

/// A small CommonMark-subset renderer (PLAN.md §3.1): headings, paragraphs,
/// emphasis, strikethrough, code spans and fenced/indented code, block quotes,
/// ordered/unordered/task lists (nested by indentation), tables, rules, links,
/// images and raw HTML blocks. Pure and unit-tested.
public enum Markdown {
    public static func html(_ source: String) -> String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        return renderBlocks(lines[...])
    }

    /// A full HTML document with readable print styles.
    public static func document(_ source: String, title: String) -> String {
        wrap(body: html(source), title: title)
    }

    public static func wrap(body: String, title: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font: 11pt -apple-system, "Helvetica Neue", Helvetica, sans-serif; line-height: 1.5; color: #1d1b18; margin: 0; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.2em 0 0.4em; page-break-after: avoid; }
        h1 { font-size: 1.9em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        p, ul, ol, pre, table, blockquote { margin: 0 0 0.8em; }
        code, pre { font-family: "SF Mono", Menlo, monospace; font-size: 0.9em; }
        code { background: #f2efea; padding: 0.1em 0.3em; border-radius: 3px; }
        pre { background: #f2efea; padding: 0.8em; border-radius: 6px; white-space: pre-wrap; page-break-inside: avoid; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid #d8d2c8; padding-left: 0.9em; color: #5e574d; }
        table { border-collapse: collapse; } th, td { border: 1px solid #d8d2c8; padding: 0.3em 0.6em; text-align: left; }
        th { background: #f2efea; } img { max-width: 100%; } hr { border: 0; border-top: 1px solid #d8d2c8; }
        a { color: #a84f00; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    // MARK: Blocks

    private static func renderBlocks(_ lines: ArraySlice<String>) -> String {
        var out: [String] = []
        var i = lines.startIndex
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.enumerated().map { idx, line in
                idx < paragraph.count - 1 && line.hasSuffix("  ") ? inline(line.trimmingCharacters(in: .whitespaces)) + "<br>"
                    : inline(line.trimmingCharacters(in: .whitespaces))
            }.joined(separator: "\n")
            out.append("<p>\(text)</p>")
            paragraph.removeAll()
        }

        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            // Indented code (not inside a paragraph)
            if paragraph.isEmpty, line.hasPrefix("    ") {
                var code: [String] = []
                while i < lines.endIndex, lines[i].hasPrefix("    ") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[i].dropFirst(min(4, lines[i].count)))); i += 1
                }
                while code.last?.isEmpty == true { code.removeLast() }
                out.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            // ATX heading
            if let level = headingLevel(trimmed) {
                flushParagraph()
                var text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                while text.hasSuffix("#") { text.removeLast() }
                out.append("<h\(level)>\(inline(text.trimmingCharacters(in: .whitespaces)))</h\(level)>")
                i += 1
                continue
            }

            // Thematic break
            if isRule(trimmed) { flushParagraph(); out.append("<hr>"); i += 1; continue }

            // Block quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if q.hasPrefix(" ") { q = q.dropFirst() }
                    quoted.append(String(q)); i += 1
                }
                out.append("<blockquote>\(renderBlocks(quoted[...]))</blockquote>")
                continue
            }

            // Table: header | separator
            if trimmed.contains("|"), i + 1 < lines.endIndex, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.endIndex, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                var html = "<table><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                for row in rows { html += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
                out.append(html + "</tbody></table>")
                continue
            }

            // Lists
            if let marker = listMarker(line) {
                flushParagraph()
                let (html, next) = renderList(lines, from: i, ordered: marker.ordered, indent: marker.indent)
                out.append(html)
                i = next
                continue
            }

            // Raw HTML block
            if paragraph.isEmpty, trimmed.hasPrefix("<"), trimmed.count > 1,
               let second = trimmed.dropFirst().first, second.isLetter || second == "/" || second == "!" {
                var block: [String] = []
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { block.append(lines[i]); i += 1 }
                out.append(block.joined(separator: "\n"))
                continue
            }

            // Setext heading underline
            if !paragraph.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || (trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2) {
                let level = trimmed.first == "=" ? 1 : 2
                let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                paragraph.removeAll()
                out.append("<h\(level)>\(inline(text))</h\(level)>")
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return out.joined(separator: "\n")
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    private static func isRule(_ s: String) -> Bool {
        let chars = s.filter { !$0.isWhitespace }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private struct ListMarker { let ordered: Bool; let indent: Int; let contentOffset: Int }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if let c = rest.first, "-*+".contains(c), rest.dropFirst().first == " " {
            return ListMarker(ordered: false, indent: indent, contentOffset: indent + 2)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let after = rest.dropFirst(digits.count)
            if let p = after.first, p == "." || p == ")", after.dropFirst().first == " " {
                return ListMarker(ordered: true, indent: indent, contentOffset: indent + digits.count + 2)
            }
        }
        return nil
    }

    private static func renderList(_ lines: ArraySlice<String>, from start: Int, ordered: Bool, indent: Int) -> (String, Int) {
        var items: [[String]] = []
        var i = start
        while i < lines.endIndex {
            let line = lines[i]
            if let m = listMarker(line), m.indent == indent, m.ordered == ordered {
                items.append([String(line.dropFirst(m.contentOffset))])
                i += 1
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineIndent = line.prefix { $0 == " " }.count
            if !items.isEmpty, !trimmed.isEmpty, lineIndent > indent {
                items[items.count - 1].append(String(line.dropFirst(min(lineIndent, indent + 2))))
                i += 1
                continue
            }
            if trimmed.isEmpty, i + 1 < lines.endIndex,
               let next = listMarker(lines[i + 1]), next.indent >= indent {
                i += 1
                continue
            }
            break
        }
        let tag = ordered ? "ol" : "ul"
        let body = items.map { item -> String in
            var first = item[0]
            var checkbox = ""
            if first.hasPrefix("[ ] ") { checkbox = "☐ "; first.removeFirst(4) }
            else if first.lowercased().hasPrefix("[x] ") { checkbox = "☑ "; first.removeFirst(4) }
            let rest = Array(item.dropFirst())
            if rest.isEmpty { return "<li>\(checkbox)\(inline(first))</li>" }
            var inner = renderBlocks(([first] + rest)[...])
            // A tight item's first paragraph is shown without <p>.
            if inner.hasPrefix("<p>"), let close = inner.range(of: "</p>") {
                let text = inner[inner.index(inner.startIndex, offsetBy: 3)..<close.lowerBound]
                let remainder = inner[close.upperBound...].drop { $0 == "\n" }
                inner = String(text) + String(remainder)
            }
            return "<li>\(checkbox)\(inner)</li>"
        }.joined()
        return ("<\(tag)>\(body)</\(tag)>", i)
    }

    // MARK: Inline

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inline(_ text: String) -> String {
        // Code spans first, protected from further processing.
        var codeSpans: [String] = []
        var s = ""
        var chars = Substring(text)
        while let start = chars.firstIndex(of: "`") {
            s += chars[..<start]
            let ticks = chars[start...].prefix { $0 == "`" }.count
            let afterTicks = chars.index(start, offsetBy: ticks)
            let closing = String(repeating: "`", count: ticks)
            if let end = chars[afterTicks...].range(of: closing) {
                let code = chars[afterTicks..<end.lowerBound].trimmingCharacters(in: .whitespaces)
                codeSpans.append("<code>\(escape(code))</code>")
                s += "\u{0}\(codeSpans.count - 1)\u{0}"
                chars = chars[end.upperBound...]
            } else {
                s += closing
                chars = chars[afterTicks...]
            }
        }
        s += chars

        s = escape(s)
        // Images, links, autolinks.
        s = replace(#"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\)"#, in: s) { m in
            "<img src=\"\(m[2])\" alt=\"\(m[1])\"\(m[3].isEmpty ? "" : " title=\"\(m[3])\"")>"
        }
        s = replace(#"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\)"#, in: s) { m in
            "<a href=\"\(m[2])\"\(m[3].isEmpty ? "" : " title=\"\(m[3])\"")>\(m[1])</a>"
        }
        s = replace(#"&lt;((?:https?|mailto):[^\s&]+)&gt;"#, in: s) { m in "<a href=\"\(m[1])\">\(m[1])</a>" }
        // Emphasis.
        s = replace(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: s) { m in "<strong>\(m[2])</strong>" }
        s = replace(#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?!\*)"#, in: s) { m in "<em>\(m[1])</em>" }
        s = replace(#"(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)"#, in: s) { m in "<em>\(m[1])</em>" }
        s = replace(#"~~(?=\S)(.+?)(?<=\S)~~"#, in: s) { m in "<del>\(m[1])</del>" }

        for (i, code) in codeSpans.enumerated() { s = s.replacingOccurrences(of: "\u{0}\(i)\u{0}", with: code) }
        return s
    }

    private static func replace(_ pattern: String, in s: String, _ build: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { idx -> String in
                let r = match.range(at: idx)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += build(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
