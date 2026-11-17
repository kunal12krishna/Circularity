@testable import CircularityEngine
import XCTest

final class OutputNamingTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/tmp/in/photo.heic")

    private func base(_ format: OutputFormat, _ op: OperationKind, template: NamingTemplate = .default,
                      size: PixelSize? = nil) -> String {
        let date = Date(timeIntervalSince1970: 1_763_337_600) // 2025-11-17 00:00 UTC
        let context = NamingContext(sourceURL: source, format: format, operation: op, date: date,
                                    pixelSize: size, timeZone: TimeZone(identifier: "UTC")!)
        return OutputNaming.baseName(template: template, context: context)
    }

    func testPlainConvertKeepsTheName() {
        XCTAssertEqual(base(.png, .convert), "photo")
    }

    func testOperationSuffixes() {
        XCTAssertEqual(base(.jpg, .resize), "photo (resized)")
        XCTAssertEqual(base(.jpg, .compress), "photo (compressed)")
        XCTAssertEqual(base(.png, .crop), "photo (cropped)")
        XCTAssertEqual(base(.pdf, .combine), "photo (combined)")
    }

    func testTemplateTokens() {
        let template = NamingTemplate("{name} {format} {date} {size}")
        XCTAssertEqual(base(.webp, .convert, template: template, size: PixelSize(width: 1920, height: 1080)),
                       "photo WebP 2025-11-17 1920x1080")
    }

    func testMissingSizeTokenCollapsesWhitespace() {
        XCTAssertEqual(base(.png, .convert, template: NamingTemplate("{name} {size} {format}")), "photo PNG")
    }

    func testCollisionsAreNumbered() {
        let taken: Set<String> = ["photo.png", "photo (1).png"]
        XCTAssertEqual(OutputNaming.uniqueFileName(base: "photo", fileExtension: "png") { taken.contains($0) },
                       "photo (2).png")
        XCTAssertEqual(OutputNaming.uniqueFileName(base: "photo", fileExtension: "jpg") { taken.contains($0) },
                       "photo.jpg")
    }

    func testSanitizeRemovesUnsafeCharacters() {
        XCTAssertEqual(OutputNaming.sanitize("a/b:c"), "a-b-c")
        XCTAssertEqual(OutputNaming.sanitize("..hidden"), "hidden")
        XCTAssertEqual(OutputNaming.sanitize("   "), "Untitled")
        XCTAssertEqual(OutputNaming.sanitize("two   spaces\tand tab"), "two spaces and tab")
    }

    func testLongNamesAreTruncatedToFit() {
        let long = String(repeating: "é", count: 300) // 2 bytes each in UTF-8
        let name = OutputNaming.sanitize(long)
        XCTAssertLessThanOrEqual(name.utf8.count, OutputNaming.maxFileNameBytes - OutputNaming.reservedTailBytes)
        let file = OutputNaming.uniqueFileName(base: name, fileExtension: "jpeg") { _ in false }
        XCTAssertLessThanOrEqual(file.utf8.count, OutputNaming.maxFileNameBytes)
    }

    func testDisplayNames() {
        XCTAssertEqual(OutputFormat.webp.displayName, "WebP")
        XCTAssertEqual(OutputFormat.jpg.displayName, "JPG")
    }
}
