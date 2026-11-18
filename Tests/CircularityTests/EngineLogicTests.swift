@testable import CircularityEngine
import CoreGraphics
import XCTest

final class MarkdownTests: XCTestCase {
    func testSetextHeadingWithDashesIsNotARule() {
        let html = Markdown.html("Title\n---\n\ntext")
        XCTAssertTrue(html.contains("<h2>Title</h2>"), html)
        XCTAssertFalse(html.contains("<hr>"), html)
        XCTAssertTrue(Markdown.html("text\n\n---").contains("<hr>"), "after a blank line it is still a rule")
    }

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

final class PDFCropMathTests: XCTestCase {
    /// The top half of the upright page, for each stored rotation.
    func testTopHalfOnRotatedPages() {
        let topHalf = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        XCTAssertEqual(PDFCropMath.unrotated(topHalf, rotation: 0), topHalf)
        // Shown turned 90° clockwise: the upright top is the stored left side.
        XCTAssertEqual(PDFCropMath.unrotated(topHalf, rotation: 90), CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(PDFCropMath.unrotated(topHalf, rotation: 180), CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        XCTAssertEqual(PDFCropMath.unrotated(topHalf, rotation: 270), CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(PDFCropMath.unrotated(topHalf, rotation: -90), PDFCropMath.unrotated(topHalf, rotation: 270))
    }
}
