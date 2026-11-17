import CircularityEngine
import CoreGraphics
import UniformTypeIdentifiers
import XCTest

final class WheelGeometryTests: XCTestCase {
    private let ring = WheelGeometry.ring()

    func testOffsetsUseClockAngles() {
        let top = WheelGeometry.offset(radius: 100, angle: 0)
        XCTAssertEqual(top.x, 0, accuracy: 0.001)
        XCTAssertEqual(top.y, -100, accuracy: 0.001, "12 o'clock is up (y-down space)")
        let right = WheelGeometry.offset(radius: 100, angle: 90)
        XCTAssertEqual(right.x, 100, accuracy: 0.001)
        XCTAssertEqual(WheelGeometry.angle(of: CGPoint(x: -100, y: 0)), 270, accuracy: 0.001)
    }

    func testFanMatchesBoardD() {
        let angles = ring.fanAngles(count: 6, flipped: false)
        XCTAssertEqual(angles, [127.5, 148.5, 169.5, 190.5, 211.5, 232.5])
        let heic = ring.fanOffsets(count: 6, flipped: false)[0]
        // Board D: HEIC chip centre at (574.2, 524.4) on a 720 canvas.
        XCTAssertEqual(360 + heic.x, 574.2, accuracy: 0.1)
        XCTAssertEqual(360 + heic.y, 524.4, accuracy: 0.1)
    }

    func testFlippedFanKeepsFormatsRightAndCropLeft() {
        let angles = ring.fanAngles(count: 6, flipped: true)
        XCTAssertEqual(angles.first, 52.5)
        XCTAssertEqual(angles.last, -52.5)
    }

    func testFanFlipsNearTheBottomOfTheScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertFalse(ring.fanNeedsFlip(center: CGPoint(x: 720, y: 450), visibleFrame: visible, count: 6))
        XCTAssertTrue(ring.fanNeedsFlip(center: CGPoint(x: 720, y: 200), visibleFrame: visible, count: 6))
    }

    func testHitTesting() {
        XCTAssertEqual(ring.hitTest(.zero, fanCount: 6, fanOpen: false, fanFlipped: false), .centre)
        XCTAssertEqual(ring.hitTest(CGPoint(x: 0, y: -150), fanCount: 6, fanOpen: false, fanFlipped: false), .segment(0))
        let jpg = WheelGeometry.offset(radius: 150, angle: 60)
        XCTAssertEqual(ring.hitTest(jpg, fanCount: 6, fanOpen: false, fanFlipped: false), .segment(1))
        // The 3° gap between PNG and JPG belongs to the nearest segment, not a dead zone.
        let gap = WheelGeometry.offset(radius: 150, angle: 29.9)
        XCTAssertEqual(ring.hitTest(gap, fanCount: 6, fanOpen: false, fanFlipped: false), .segment(0))
        XCTAssertEqual(ring.hitTest(CGPoint(x: 0, y: -300), fanCount: 6, fanOpen: false, fanFlipped: false), .none)
    }

    func testFanChipsAreHitOnlyWhenOpen() {
        let chip = ring.fanOffsets(count: 6, flipped: false)[2]
        XCTAssertEqual(ring.hitTest(chip, fanCount: 6, fanOpen: true, fanFlipped: false), .fanChip(2))
        XCTAssertEqual(ring.hitTest(chip, fanCount: 6, fanOpen: false, fanFlipped: false), .none)
    }

    func testDismissDistanceExtendsTowardTheOpenFan() {
        let towardFan = WheelGeometry.offset(radius: 255, angle: 180)
        XCTAssertTrue(ring.isBeyondDismissDistance(towardFan, fanCount: 6, fanOpen: false, fanFlipped: false))
        XCTAssertFalse(ring.isBeyondDismissDistance(towardFan, fanCount: 6, fanOpen: true, fanFlipped: false))
        let awayFromFan = WheelGeometry.offset(radius: 255, angle: 0)
        XCTAssertTrue(ring.isBeyondDismissDistance(awayFromFan, fanCount: 6, fanOpen: true, fanFlipped: false))
    }

    func testScaleApplies() {
        let big = WheelGeometry.ring(scale: 1.4)
        XCTAssertEqual(big.size, 1008, accuracy: 0.001)
        XCTAssertEqual(big.outer(hovered: true), 216 * 1.4, accuracy: 0.001)
    }
}

final class SlotProviderTests: XCTestCase {
    private let everything: (OutputFormat) -> Bool = { _ in true }
    private let noWebP: (OutputFormat) -> Bool = { $0 != .webp }

    private func labels(_ slots: [WheelSlot?]) -> [String] { slots.map { $0?.label ?? "—" } }

    func testImageMenuMatchesBoardD() {
        let menu = SlotProvider.menu(for: [.heic], canWrite: everything)
        XCTAssertEqual(labels(menu.ring), ["PNG", "JPG", "WebP", "More", "Compress", "Resize"])
        XCTAssertEqual(menu.fan.map(\.label), ["AVIF", "TIFF", "GIF", "BMP", "PDF", "Crop"],
                       "HEIC is the source, so BMP fills the fan")
    }

    func testFanForANonHEICSourceIsBoardDExactly() {
        let menu = SlotProvider.menu(for: [.bmp], canWrite: everything)
        XCTAssertEqual(labels(menu.ring), ["PNG", "JPG", "WebP", "More", "Compress", "Resize"])
        XCTAssertEqual(menu.fan.map(\.label), ["HEIC", "AVIF", "TIFF", "GIF", "PDF", "Crop"])
    }

    func testSourceFormatIsSkipped() {
        let menu = SlotProvider.menu(for: [.png], canWrite: everything)
        XCTAssertEqual(labels(menu.ring), ["JPG", "WebP", "HEIC", "More", "Compress", "Resize"])
    }

    func testWebPUnavailableMovesUpTheNextFormatAndBMPJoinsTheFan() {
        let menu = SlotProvider.menu(for: [.jpeg], canWrite: noWebP)
        XCTAssertEqual(labels(menu.ring), ["PNG", "HEIC", "AVIF", "More", "Compress", "Resize"])
        XCTAssertEqual(menu.fan.map(\.label), ["TIFF", "GIF", "BMP", "PDF", "Crop"])
    }

    func testToolsAndMoreNeverMoveWithSmartOrdering() {
        let usage = ["convert.gif": 9, "convert.tiff": 4]
        let menu = SlotProvider.menu(for: [.heic], canWrite: everything, usage: usage, smartOrdering: true)
        XCTAssertEqual(labels(menu.ring), ["GIF", "TIFF", "PNG", "More", "Compress", "Resize"])
    }

    func testImageBatchPutsCombineOnTheRing() {
        let menu = SlotProvider.menu(for: [.jpeg, .png], canWrite: everything)
        XCTAssertEqual(menu.ring[2]?.action, .combinePDF, "board B: Combine sits on the ring for batches")
        XCTAssertEqual(menu.ring[2]?.verb, "Combine into one PDF")
        XCTAssertEqual(menu.ring[0]?.verb, "Convert 2 to PNG")
        XCTAssertTrue(menu.fan.contains { $0.action == .convert(.pdf) }, "one PDF per image stays in the fan")
        XCTAssertTrue(menu.fan.contains { $0.action == .convert(.webp) }, "the displaced format moves to the fan")
    }

    func testPDFMenu() {
        let menu = SlotProvider.menu(for: [.pdf], canWrite: everything)
        XCTAssertEqual(labels(menu.ring), ["PNG", "JPG", "TXT", "More", "Compress", "Resize"])
        XCTAssertEqual(menu.ring[0]?.action, .pdfPages(.png))
        XCTAssertEqual(menu.fan.map(\.label), ["Crop"])
    }

    func testDocumentMenus() {
        let md = SlotProvider.menu(for: [UTType("net.daringfireball.markdown")!], canWrite: everything)
        XCTAssertEqual(labels(md.ring), ["PDF", "HTML", "TXT", "—", "—", "—"])
        let docx = SlotProvider.menu(for: [UTType("org.openxmlformats.wordprocessingml.document")!], canWrite: everything)
        XCTAssertEqual(labels(docx.ring), ["PDF", "TXT", "HTML", "—", "—", "—"])
    }

    func testVideoShowsTheFriendlyNotice() {
        let menu = SlotProvider.menu(for: [.mpeg4Movie], canWrite: everything)
        XCTAssertTrue(menu.isEmpty)
        XCTAssertEqual(menu.notice?.detail, "Video & audio arrive in the next update")
    }

    func testMixedImagesAndPDFsOfferCombine() {
        let menu = SlotProvider.menu(for: [.png, .pdf], canWrite: everything)
        XCTAssertEqual(menu.ring[0]?.action, .combinePDF)
    }

    func testUnsupportedFilesExplainThemselves() {
        let menu = SlotProvider.menu(for: [.zip], canWrite: everything)
        XCTAssertEqual(menu.notice?.kicker, "CAN'T CONVERT")
        XCTAssertEqual(menu.notice?.big, "ZIP")
    }
}
