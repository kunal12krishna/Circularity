@testable import CircularityEngine
import CoreGraphics
import XCTest

final class MarkdownTests: XCTestCase {
    func testHeadingsAndParagraphs() {
        XCTAssertEqual(Markdown.html("# Title\n\nHello world"), "<h1>Title</h1>\n<p>Hello world</p>")
        XCTAssertEqual(Markdown.html("Title\n====="), "<h1>Title</h1>")
        XCTAssertEqual(Markdown.html("#nospace"), "<p>#nospace</p>")
    }

    func testInlineFormatting() {
        let html = Markdown.html("**bold**, *it*, `a<b`, ~~gone~~ and [link](https://x.y)")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>it</em>"))
        XCTAssertTrue(html.contains("<code>a&lt;b</code>"), "code spans are escaped and not formatted")
        XCTAssertTrue(html.contains("<del>gone</del>"))
        XCTAssertTrue(html.contains("<a href=\"https://x.y\">link</a>"))
    }

    func testHTMLIsEscapedInText() {
        XCTAssertEqual(Markdown.html("a < b & c"), "<p>a &lt; b &amp; c</p>")
    }

    func testListsAndNesting() {
        let html = Markdown.html("- one\n- two\n  - nested\n\n1. first\n2. second")
        XCTAssertTrue(html.contains("<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>"), html)
        XCTAssertTrue(html.contains("<ol><li>first</li><li>second</li></ol>"), html)
    }

    func testTaskList() {
        XCTAssertTrue(Markdown.html("- [x] done\n- [ ] todo").contains("☑ done"))
    }

    func testFencedCodeAndTable() {
        let html = Markdown.html("```swift\nlet a = 1 < 2\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let a = 1 &lt; 2</code></pre>"), html)
        XCTAssertTrue(html.contains("<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>"), html)
    }

    func testQuoteRuleAndImage() {
        let html = Markdown.html("> quoted\n\n---\n\n![alt](pic.png)")
        XCTAssertTrue(html.contains("<blockquote><p>quoted</p></blockquote>"), html)
        XCTAssertTrue(html.contains("<hr>"))
        XCTAssertTrue(html.contains("<img src=\"pic.png\" alt=\"alt\">"), html)
    }
}

final class ResizeAndPaperTests: XCTestCase {
    private let source = CGSize(width: 800, height: 600)

    func testFitKeepsAspect() {
        XCTAssertEqual(ResizeMath.targetSize(source: source, spec: ResizeSpec(width: 400, height: 400)), CGSize(width: 400, height: 300))
        XCTAssertEqual(ResizeMath.targetSize(source: source, spec: ResizeSpec(width: nil, height: 300)), CGSize(width: 400, height: 300))
        XCTAssertEqual(ResizeMath.targetSize(source: source, spec: ResizeSpec(width: 1920, height: nil)), CGSize(width: 1920, height: 1440))
    }

    func testStretch() {
        XCTAssertEqual(ResizeMath.targetSize(source: source, spec: ResizeSpec(width: 100, height: 100, mode: .stretch)),
                       CGSize(width: 100, height: 100))
        XCTAssertEqual(ResizeMath.targetSize(source: source, spec: ResizeSpec(width: 400, height: nil, mode: .stretch)),
                       CGSize(width: 400, height: 300))
    }

    func testNoSidesKeepsTheSize() {
        XCTAssertEqual(ResizeMath.targetSize(source: source, spec: ResizeSpec(width: nil, height: nil)), source)
    }

    func testPaperByRegion() {
        XCTAssertEqual(PaperSize.forRegion("US"), .letter)
        XCTAssertEqual(PaperSize.forRegion("ca"), .letter)
        XCTAssertEqual(PaperSize.forRegion("IN"), .a4)
        XCTAssertEqual(PaperSize.forRegion(nil), .a4)
    }

    func testPagesFolderNaming() {
        XCTAssertEqual(OperationKind.pdfToImages.nameSuffix, "pages")
        XCTAssertEqual(CircularityEngine.Operation.compressPDF(.balanced).kind, .compress)
    }
}
